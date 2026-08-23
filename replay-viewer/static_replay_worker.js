'use strict';

// static_replay_worker.js — gridlock's replay Worker, forked from
// coworld-ctf's file of the same name.
//
// PAIRING (do not change one half without the other): this is the
// paintbot-lineage, NON-MODULARIZED bootstrap. The emscripten module is
// pulled in with importScripts and announces itself through
// `Module.onRuntimeInitialized`, so replay-viewer/config.nims must NOT carry
// `-s MODULARIZE=1` or `-s EXPORT_NAME=...`. A babel-lineage factory call
// against these flags hangs on "Loading replay..." forever with every asset
// returning 200 (cogame-lantern, 2026-08-23).

// broadcast_core.js is shared with the Window client and publishes through
// `window`. A classic Worker can provide that alias without a second
// implementation or a bundle step.
self.window = self;

var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var minimapSurface = null;
var failed = false;
var disposed = false;

function stageNote() {
  // The fixed progress buffer survives an ABORTING_MALLOC failure even though
  // the Emscripten call stack does not.
  try {
    var length = Module._gridlock_stage_len ? Module._gridlock_stage_len() : 0;
    if (!length) return '';
    var pointer = Module._gridlock_stage_ptr();
    return new TextDecoder().decode(
      Module.HEAPU8.slice(pointer, pointer + length));
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var length = Module._gridlock_error_len();
  if (!length) {
    var stage = stageNote();
    return stage
      ? 'Replay runtime failed while: ' + stage
      : 'Replay runtime rejected the replay';
  }
  var pointer = Module._gridlock_error_ptr();
  return new TextDecoder().decode(
    Module.HEAPU8.slice(pointer, pointer + length));
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: error && error.message ? error.message : String(error),
    stage: stageNote()
  });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

function packetText() {
  var length = Module._gridlock_packet_len();
  if (!length) throw new Error('Replay runtime produced an empty frame');
  var pointer = Module._gridlock_packet_ptr();
  return new TextDecoder().decode(
    Module.HEAPU8.subarray(pointer, pointer + length));
}

function ingestPacket() {
  core.ingest(packetText());
}

function sendRuntimeInput(text) {
  if (!runtimeLoaded) return;
  var bytes = new TextEncoder().encode(text);
  copyIntoRuntime(bytes, function (pointer, length) {
    Module._gridlock_input(pointer, length);
  });
}

function createBroadcastCore(message) {
  core = self.BroadcastCore.create({
    canvas: message.canvas,
    viewportWidth: message.width,
    viewportHeight: message.height,
    devicePixelRatio: message.dpr,
    onText: function (text) {
      postMessage({ type: 'text', text: text });
    },
    onStatus: function (status) {
      postMessage({ type: 'status', status: status });
    },
    onFirstFrame: function () {
      postMessage({ type: 'firstFrame' });
    },
    onTransform: function (transform) {
      postMessage({ type: 'transform', transform: transform });
    }
  });
  if (minimapSurface) core.attachMinimap(minimapSurface);
  core.start();
}

function fetchReplay(url, timeoutMs) {
  // AbortController bounds the wait: a fetch that never answers is otherwise
  // indistinguishable from a slow one and the shell would say LOADING until
  // the tab died.
  var controller = typeof AbortController === 'function'
    ? new AbortController() : null;
  var timer = setTimeout(function () {
    if (controller) controller.abort();
  }, timeoutMs || 20000);
  return fetch(url, controller
    ? { credentials: 'omit', mode: 'cors', signal: controller.signal }
    : { credentials: 'omit', mode: 'cors' })
    .then(function (response) {
      if (!response.ok) {
        throw new Error('Replay request returned HTTP ' + response.status);
      }
      return response.arrayBuffer();
    })
    .catch(function (error) {
      if (error && error.name === 'AbortError') {
        throw new Error('replay fetch timed out after ' +
          Math.round((timeoutMs || 20000) / 1000) + 's');
      }
      throw error;
    })
    .finally(function () { clearTimeout(timer); });
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) {
    return;
  }
  var message = initMessage;
  initMessage = null;
  try {
    createBroadcastCore(message);
    var buffer = await fetchReplay(message.replayUrl, message.fetchTimeoutMs);
    var bytes = new Uint8Array(buffer);
    if (!bytes.length) throw new Error('Replay response was empty');
    var loaded = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._gridlock_load_replay(pointer, length);
    });
    if (!loaded) throw new Error(runtimeError());
    runtimeLoaded = true;
    ingestPacket();                       // the meta packet
    if (Module._gridlock_frame() < 0) throw new Error(runtimeError());
    ingestPacket();                       // frame zero, so a picture exists
    postMessage({
      type: 'loaded',
      mismatchTick: Module._gridlock_mismatch_tick()
    });
  } catch (error) {
    reportFailure(error);
  }
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(64, Number(frames) || 1));
    for (var i = 0; i < count - 1; i++) {
      if (Module._gridlock_frame() < 0) throw new Error(runtimeError());
    }
    if (Module._gridlock_frame() < 0) throw new Error(runtimeError());
    ingestPacket();
    postMessage({
      type: 'advanced',
      mismatchTick: Module._gridlock_mismatch_tick(),
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') \u2014 wasm32 is limited to 2 GB' +
    (stage ? '. Failed while: ' + stage : '')));
};
Module.onRuntimeInitialized = function () {
  // DEFERRED ON PURPOSE. Emscripten calls onRuntimeInitialized from run()
  // BEFORE callMain(), and Nim initialises every module-level global inside
  // main() — including the 288-lane road table. Calling an export before
  // main has run therefore reads an EMPTY graph: every route comes back
  // empty, no van is ever dispatched, and the viewer silently replays a
  // frozen city that fails the keyframe digest at the first check. Handing
  // control back to the event loop for one macrotask lets callMain() finish
  // first. (The fetch below would usually hide this by yielding anyway —
  // "usually" is the bug.)
  setTimeout(function () {
    runtimeReady = true;
    start();
  }, 0);
};
self.Module = Module;

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'seek') {
      sendRuntimeInput(JSON.stringify({ seek: Number(message.tick) || 0 }));
      advance(1);
    } else if (message.type === 'command' && core) {
      core.sendCommand(message.text || '');
    } else if (message.type === 'click' && core) {
      core.clickMap(Number(message.x) || 0, Number(message.y) || 0);
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'view' && core) {
      if (message.action === 'zoom') core.zoomAt(message.factor, message.x, message.y);
      else if (message.action === 'setZoom') core.setZoom(message.level, message.x, message.y);
      else if (message.action === 'pan') core.panBy(message.dx, message.dy);
      else if (message.action === 'panMap') core.panByMap(message.dx, message.dy);
      else if (message.action === 'panTo') core.panTo(message.x, message.y);
      else if (message.action === 'reset') core.resetView();
    } else if (message.type === 'minimap') {
      minimapSurface = message.canvas || null;
      if (core && minimapSurface) core.attachMinimap(minimapSurface);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js',
  './gridlock_replay.js');
