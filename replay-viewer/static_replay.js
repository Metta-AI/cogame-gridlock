// static_replay.js — the gridlock static replay shell.
//
// Forked from coworld-ctf's replay-viewer/static_replay.js and kept in its
// shape: the OffscreenCanvas-Worker host, createCore/start/stop/advance/
// resize, the transform-and-minimap message protocol, the
// `data-replay-mismatch-tick` attribute and showFailure.
//
// THE PAIRING IS LOAD-BEARING. This shell is paintbot-lineage: the worker
// waits for `Module.onRuntimeInitialized` and pulls the module in with
// `importScripts`, so replay-viewer/config.nims must carry NEITHER
// `-s MODULARIZE=1` NOR `-s EXPORT_NAME=...`. Splicing a babel-lineage shell
// (which calls a factory) onto these link flags throws nothing, logs nothing
// and hangs on "Loading replay..." forever — that is exactly what deadlocked
// cogame-lantern on 2026-08-23. tests/test_viewer.nim asserts the pairing.
//
// Three authored additions on top of the inherited file, and no line is
// imported from another starter:
//   1. data-replay-loaded="true" is set in the `firstFrame` branch as well as
//      on `loaded`, so the attribute means "a frame was drawn".
//   2. data-replay-error="<message>" is set inside showFailure.
//   3. the `coworld-replay` postMessage bridge: tell("loading") on entry,
//      tell("error", msg) in showFailure, and tell("ready") inside a double
//      requestAnimationFrame after the first drawn frame.
(function () {
  'use strict';

  var FETCH_TIMEOUT_MS = 20000;
  var failed = false;
  var scriptUrl = document.currentScript && document.currentScript.src;
  var workerUrl = new URL('./static_replay_worker.js',
    scriptUrl || location.href);

  // VIEWER -> HOST READINESS. An embedding page can only see this document's
  // `load` event, which fires long before the wasm module has compiled and
  // the replay has come back from S3.
  function tell(type, message) {
    if (window.parent === window) return;
    var envelope = { src: 'coworld-replay', type: type };
    if (message) envelope.message = message;
    try { window.parent.postMessage(envelope, '*'); } catch (ignore) {}
  }
  tell('loading');

  function markLoaded() {
    document.documentElement.setAttribute('data-replay-loaded', 'true');
    var loading = document.getElementById('loading');
    if (loading) loading.style.display = 'none';
    window.requestAnimationFrame(function () {
      window.requestAnimationFrame(function () { tell('ready'); });
    });
  }

  function showFailure(error) {
    // First failure wins: an OOM abort reports once from the Worker (with the
    // stage note), then may also surface as an error event. Keep the specific
    // diagnostic instead of overwriting it with the generic one.
    if (failed) return;
    failed = true;
    console.error(error);
    var message = (error && error.message) || String(error);
    var status = document.getElementById('status');
    if (status) {
      status.textContent = 'Replay failed: ' + message;
      status.classList.add('show');
    }
    var loading = document.getElementById('loading');
    if (loading) {
      loading.style.display = '';
      loading.textContent = 'Replay failed: ' + message + ' ';
      var retry = document.createElement('button');
      retry.id = 'loading-retry';
      retry.type = 'button';
      retry.textContent = 'Retry';
      retry.onclick = function () { location.reload(); };
      loading.appendChild(retry);
    }
    document.documentElement.setAttribute('data-replay-error', message);
    tell('error', message);
  }

  function setMismatchTick(tick) {
    if (tick >= 0) {
      document.documentElement.setAttribute(
        'data-replay-mismatch-tick', String(tick));
    }
  }

  function createCore(config) {
    var canvas = config.canvas;
    var worker = null;
    var started = false;
    var loaded = false;
    var advanceInFlight = false;
    var lastFrame = 0;
    var accumulator = 0;
    var frameMs = 1000 / 24;
    var speed = 4;              // the design's default playback speed
    var playing = true;
    var workerDraws = 0;
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 8, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };
    var viewport = { width: 1, height: 1, dpr: window.devicePixelRatio || 1 };
    var offscreen;
    var pendingMinimap = null;
    var minimapSent = false;

    // transferControlToOffscreen is one-way and one-shot: the canvas is dead
    // to the main thread afterwards, so this must happen exactly once, and
    // only once the Worker exists to receive it.
    function sendMinimap() {
      if (!worker || !pendingMinimap || minimapSent) return;
      if (typeof pendingMinimap.transferControlToOffscreen !== 'function') return;
      try {
        var surface = pendingMinimap.transferControlToOffscreen();
        minimapSent = true;
        pendingMinimap = null;
        worker.postMessage({ type: 'minimap', canvas: surface }, [surface]);
      } catch (error) {
        console.warn('Minimap unavailable', error);
        pendingMinimap = null;
      }
    }

    if (!canvas || typeof canvas.transferControlToOffscreen !== 'function') {
      showFailure(new Error('This browser does not support OffscreenCanvas Workers'));
    } else {
      try {
        offscreen = canvas.transferControlToOffscreen();
      } catch (error) {
        showFailure(error);
      }
    }

    function readViewport() {
      var rect = canvas.getBoundingClientRect();
      viewport = {
        width: Math.max(1, rect.width || canvas.clientWidth || 1),
        height: Math.max(1, rect.height || canvas.clientHeight || 1),
        dpr: window.devicePixelRatio || 1
      };
      return viewport;
    }

    function postViewport() {
      readViewport();
      if (worker && started) {
        worker.postMessage({
          type: 'resize',
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        });
      }
    }

    function animate(now) {
      if (failed || !loaded || !worker) return;
      if (!lastFrame) lastFrame = now;
      accumulator = Math.min(accumulator + Math.min(now - lastFrame, 250), 250);
      lastFrame = now;
      // Below 1x the tick interval stretches instead of the tick count
      // shrinking (a tick is indivisible): at 0.5x stepMs is 2*frameMs, so
      // one sim tick is spent every OTHER display frame.
      var stepMs = speed < 1 ? frameMs / speed : frameMs;
      var whole = Math.max(1, speed);
      if (playing && !advanceInFlight && accumulator >= stepMs) {
        var frames = Math.min(16 * whole,
          Math.floor(accumulator / stepMs) * whole);
        accumulator -= Math.max(1, Math.floor(frames / whole)) * stepMs;
        advanceInFlight = true;
        worker.postMessage({ type: 'advance', frames: Math.max(1, frames) });
      }
      requestAnimationFrame(animate);
    }

    function onWorkerMessage(event) {
      if (failed) return;
      var message = event.data || {};
      try {
        if (message.type === 'text') {
          if (config.onText) config.onText(message.text);
        } else if (message.type === 'meta') {
          if (config.onMeta) config.onMeta(message.meta);
        } else if (message.type === 'status') {
          if (config.onStatus) config.onStatus(message.status);
        } else if (message.type === 'firstFrame') {
          // Addition 1: the attribute means A FRAME WAS DRAWN, which is what
          // SPEC check 8(a) and tools/ci/viewer_smoke.mjs look for.
          markLoaded();
          if (config.onFirstFrame) config.onFirstFrame();
        } else if (message.type === 'transform') {
          transform = message.transform;
          if (config.onTransform) config.onTransform(transform);
        } else if (message.type === 'loaded') {
          setMismatchTick(message.mismatchTick);
          loaded = true;
          markLoaded();
          requestAnimationFrame(animate);
        } else if (message.type === 'advanced') {
          setMismatchTick(message.mismatchTick);
          advanceInFlight = false;
          if (typeof message.draws === 'number') workerDraws = message.draws;
        } else if (message.type === 'error') {
          showFailure(new Error(message.message || 'Replay Worker failed'));
          stop();
        }
      } catch (error) {
        showFailure(error);
      }
    }

    function start() {
      if (started || !offscreen || failed) return;
      started = true;
      var replayUrl = new URLSearchParams(location.search).get('replay');
      if (!replayUrl) {
        showFailure(new Error('Missing required replay URL'));
        return;
      }
      readViewport();
      if (config.onStatus) config.onStatus('connecting');
      try {
        worker = new Worker(workerUrl, { name: 'gridlock-static-replay' });
        worker.onmessage = onWorkerMessage;
        worker.onerror = function (event) {
          showFailure(new Error(event.message || 'Replay Worker crashed'));
          stop();
        };
        worker.onmessageerror = function () {
          showFailure(new Error('Replay Worker sent an unreadable message'));
          stop();
        };
        worker.postMessage({
          type: 'init',
          replayUrl: replayUrl,
          fetchTimeoutMs: FETCH_TIMEOUT_MS,
          canvas: offscreen,
          width: viewport.width,
          height: viewport.height,
          dpr: viewport.dpr
        }, [offscreen]);
        sendMinimap();
        document.documentElement.setAttribute('data-replay-worker', 'true');
      } catch (error) {
        showFailure(error);
      }
    }

    function stop() {
      if (!worker) return;
      worker.postMessage({ type: 'dispose' });
      worker.terminate();
      worker = null;
    }

    window.addEventListener('pagehide', stop, { once: true });

    return {
      start: start,
      stop: stop,
      seek: function (tick) {
        if (worker) worker.postMessage({ type: 'seek', tick: tick });
      },
      setSpeed: function (value) { speed = Math.max(0.5, value || 1); },
      getSpeed: function () { return speed; },
      setPlaying: function (value) {
        playing = !!value;
        if (playing) { lastFrame = 0; requestAnimationFrame(animate); }
      },
      isPlaying: function () { return playing; },
      sendCommand: function (text) {
        if (worker) worker.postMessage({ type: 'command', text: text });
      },
      clickMap: function (mapX, mapY) {
        if (worker) worker.postMessage({ type: 'click', x: mapX, y: mapY });
      },
      zoomAt: function (factor, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'zoom', factor: factor, x: x, y: y });
      },
      setZoom: function (level, x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'setZoom', level: level, x: x, y: y });
      },
      panBy: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'pan', dx: dx, dy: dy });
      },
      panByMap: function (dx, dy) {
        if (worker) worker.postMessage({ type: 'view', action: 'panMap', dx: dx, dy: dy });
      },
      panTo: function (x, y) {
        if (worker) worker.postMessage({ type: 'view', action: 'panTo', x: x, y: y });
      },
      resetView: function () {
        if (worker) worker.postMessage({ type: 'view', action: 'reset' });
      },
      attachMinimap: function (surface) {
        pendingMinimap = surface || null;
        sendMinimap();
      },
      getTransform: function () { return transform; },
      setViewportFit: postViewport,
      getPaceStats: function () {
        return { enabled: playing, queued: 0, presented: 0,
          interval: frameMs, draws: workerDraws };
      }
    };
  }

  window.GridlockStaticReplay = { createCore: createCore };
})();
