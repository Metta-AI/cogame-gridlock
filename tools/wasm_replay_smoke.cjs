#!/usr/bin/env node
// Smoke-tests the STATIC WASM replay bundle — the artifact the platform
// actually serves — by loading a real replay and stepping frames inside the
// wasm32 runtime, exactly as index.html's Worker does.
//
// Forked from coworld-ctf's tools/wasm_replay_smoke.cjs. Why it exists: the
// native test suite runs 64-bit, where Nim `int` is 64 bits and large
// allocations succeed. The shipped viewer is --cpu:wasm32 — `int` is 32 bits
// (overflow checks trap on arithmetic that is silently fine natively) and the
// address space ends at 2 GB. Both classes of bug are invisible to the native
// tests. The BROWSER half — the shell, the Worker and the OffscreenCanvas
// pairing — is tools/ci/viewer_smoke.mjs.
//
// Usage: node tools/wasm_replay_smoke.cjs <dist-dir> <replay-file> [frames]

'use strict';
const fs = require('fs');
const path = require('path');

const distDir = path.resolve(process.argv[2] || 'replay-viewer/dist');
const replayPath = process.argv[3];
const frameBudget = parseInt(process.argv[4] || '300', 10);
if (!replayPath) {
  console.error('usage: wasm_replay_smoke.cjs <dist-dir> <replay-file> [frames]');
  process.exit(2);
}

// A hung load (an allocation loop, a runtime that never initialises) must
// fail loudly rather than stall the job.
const watchdog = setTimeout(() => {
  console.error('FAIL: smoke did not finish within 120s');
  process.exit(1);
}, 120000);

// The bundle is injected below with `Module` as a FUNCTION PARAMETER. A plain
// require() cannot configure it: the emitted `var Module` declaration hoists
// over any global we set, so locateFile / onRuntimeInitialized would be
// silently ignored and the .data preload would resolve against the cwd.
const Module = {
  locateFile: (p) => path.join(distDir, p),
  // Deferred: emscripten fires onRuntimeInitialized BEFORE callMain(), and
  // Nim initialises its module globals (the road table among them) inside
  // main. Calling an export first reads an empty graph. Same reason
  // static_replay_worker.js defers.
  onRuntimeInitialized: () => setTimeout(run, 0),
  onAbort: (what) => {
    // -s ABORTING_MALLOC=1 aborts on allocation failure but leaves linear
    // memory intact: the stage buffer still says what exhausted it.
    const stage = readStageNote();
    console.error('FAIL: wasm runtime aborted: ' + what +
      (stage ? '\nruntime was: ' + stage : ''));
    process.exit(1);
  },
};

function readStageNote() {
  try {
    const length = Module._gridlock_stage_len ? Module._gridlock_stage_len() : 0;
    if (!length) return '';
    const pointer = Module._gridlock_stage_ptr();
    return Buffer.from(
      Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  } catch (ignored) {
    return '';
  }
}

function readRuntimeError() {
  const length = Module._gridlock_error_len();
  if (length) {
    const pointer = Module._gridlock_error_ptr();
    return Buffer.from(
      Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8');
  }
  const stage = readStageNote();
  return stage
    ? '(no error text; runtime was: ' + stage + ')'
    : '(runtime reported no error text)';
}

function packet() {
  const length = Module._gridlock_packet_len();
  if (length <= 0) return null;
  const pointer = Module._gridlock_packet_ptr();
  return JSON.parse(Buffer.from(
    Module.HEAPU8.subarray(pointer, pointer + length)).toString('utf8'));
}

function run() {
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._gridlock_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (loaded !== 1) {
    console.error('FAIL: gridlock_load_replay rejected ' +
      path.basename(replayPath) + '\n' + readRuntimeError());
    process.exit(1);
  }
  const meta = packet();
  if (!meta || meta.type !== 'meta') {
    console.error('FAIL: the load packet was not the meta payload');
    process.exit(1);
  }
  if (!meta.lanes || meta.lanes.length !== 288) {
    console.error('FAIL: meta carried ' +
      (meta.lanes ? meta.lanes.length : 0) + ' lanes, expected 288');
    process.exit(1);
  }
  let packetBytes = 0;
  let last = null;
  const budget = Math.max(frameBudget, meta.tick_count + 4);
  for (let i = 0; i < budget; i++) {
    if (Module._gridlock_frame() !== 1) {
      console.error('FAIL: gridlock_frame died at frame ' + i + '\n' +
        readRuntimeError());
      process.exit(1);
    }
    packetBytes += Module._gridlock_packet_len();
    last = packet();
    if (last && last.t >= meta.tick_count) break;
  }
  const mismatch = Module._gridlock_mismatch_tick();
  if (mismatch !== -1) {
    console.error('FAIL: replay digest mismatch at tick ' + mismatch +
      ' — the wasm sim diverged from the recording');
    process.exit(1);
  }
  if (!last || last.t < meta.tick_count) {
    console.error('FAIL: playback stopped at tick ' + (last ? last.t : -1) +
      ' of ' + meta.tick_count);
    process.exit(1);
  }
  clearTimeout(watchdog);
  console.log('ok: loaded ' + path.basename(replayPath) + ', replayed to tick ' +
    last.t + '/' + meta.tick_count + ' (' + packetBytes + ' packet bytes, heap ' +
    Math.round(Module.HEAPU8.length / 1024 / 1024) + ' MB)');
  process.exit(0);
}

const bundlePath = path.join(distDir, 'gridlock_replay.js');
new Function('Module', 'require', '__filename', '__dirname',
  fs.readFileSync(bundlePath, 'utf8'))(Module, require, bundlePath, distDir);
