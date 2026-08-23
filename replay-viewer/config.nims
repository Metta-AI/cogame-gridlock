import std/[os, strformat, strutils]

let rootDir = currentSourcePath().parentDir().parentDir()
let distDir = rootDir / "replay-viewer" / "dist"

if not dirExists(distDir):
  mkDir(distDir)

switch("path", rootDir / "src")
switch("nimcache", distDir / "nimcache")
switch("threads", "off")
--os:linux
--cpu:wasm32
--cc:clang
--clang.exe:emcc
--clang.linkerexe:emcc
--clang.cpp.exe:emcc
--clang.cpp.linkerexe:emcc
--mm:arc
--exceptions:goto
--define:noSignalHandler
--define:release
# Route every allocation through emscripten's malloc (the standard Nim
# emscripten setup). With Nim's bundled allocator a bad free silently poisons
# the freelists; dlmalloc traps loudly instead.
--define:useMalloc

# THE PAIRING. There is deliberately NO `-s MODULARIZE=1` and NO
# `-s EXPORT_NAME=...` here: replay-viewer/static_replay_worker.js is the
# paintbot-lineage bootstrap that waits for `Module.onRuntimeInitialized` and
# pulls this module in with importScripts. A babel-lineage factory call
# against MODULARIZE flags throws nothing, logs nothing and hangs on
# "Loading replay..." forever (cogame-lantern, 2026-08-23).
# tests/test_viewer.nim asserts both halves of this pairing.
#
# ENVIRONMENT includes worker because the shipped bundle owns the WASM runtime
# in a Dedicated Worker, and node so CI can smoke-run the exact emitted module.
# ABORTING_MALLOC matters: with -d:useMalloc Nim never checks malloc for nil
# and wasm32 has no memory protection, so a failed allocation would write
# through the nil pointer into address 0 and silently corrupt the module's own
# globals. Aborting keeps linear memory intact, and the page reads
# gridlock_stage_ptr/len afterwards to report what the runtime was doing.
switch(
  "passL",
  (&"""
  -o {distDir / "gridlock_replay.js"}
  --preload-file {rootDir / "data"}@data
  -O2
  -s ALLOW_MEMORY_GROWTH
  -s ABORTING_MALLOC=1
  -s FILESYSTEM=1
  -s ENVIRONMENT=web,worker,node
  -s EXPORTED_RUNTIME_METHODS=HEAPU8
  -s EXPORTED_FUNCTIONS=_main,_malloc,_free,_gridlock_load_replay,_gridlock_frame,_gridlock_input,_gridlock_packet_ptr,_gridlock_packet_len,_gridlock_mismatch_tick,_gridlock_error_ptr,_gridlock_error_len,_gridlock_stage_ptr,_gridlock_stage_len
  """).replace("\n", " ")
)
