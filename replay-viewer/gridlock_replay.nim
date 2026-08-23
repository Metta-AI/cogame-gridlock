## Gridlock static replay viewer, wasm side.
##
## JS hands the raw replay bytes to `gridlock_load_replay`; this module parses
## them with the SAME Nim sim the game server runs and RE-DERIVES every frame
## from the plan stream — so lane occupancy, which is the whole picture, is
## recomputed in the browser rather than transported. A backward seek restarts
## from the nearest in-memory turn snapshot and replays at most one turn.
##
## Every keyframe's digest is compared against the recorded one; the first
## mismatch is reported through `gridlock_mismatch_tick` (the shell lights
## `#mmwarn`) and playback continues — paintbot's `mismatchQuit = false`
## default.

import std/json
import gridlock/render
import gridlock/replay
import gridlock/sim
import gridlock/types

var
  runtimeLoaded = false
  player: ReplayPlayer
  packet: string
  lastError: string
  eventCursor: int
  pendingSeek = -1

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1, and this fixed buffer — stamped BEFORE each
## risky phase — stays readable from JS after the abort, so the page can still
## report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc gridlockLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "gridlock_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    let parsed = parseReplayBytes(data.bytesFromPointer(int(length)))
    stampStage("initialize replay runtime")
    player = initReplayRuntime(parsed)
    runtimeLoaded = true
    eventCursor = 0
    pendingSeek = -1
    stampStage("build the meta packet")
    packet = $metaJson(player.sim, parsed.results)
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg
    return 0

proc gridlockInput(data: ptr uint8, length: cint)
    {.exportc: "gridlock_input", cdecl.} =
  if not runtimeLoaded:
    return
  try:
    let message = parseJson(data.bytesFromPointer(int(length)))
    if message.kind == JObject and message.hasKey("seek"):
      pendingSeek = message{"seek"}.getInt()
  except CatchableError:
    discard

proc gridlockFrame(): cint {.exportc: "gridlock_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage("advance replay")
  try:
    if pendingSeek >= 0:
      let target = pendingSeek
      pendingSeek = -1
      player.seekTo(target)
      if eventCursor > player.sim.events.len:
        eventCursor = player.sim.events.len
    else:
      discard player.advanceOneTick()
    packet = $frameJson(player.sim, eventCursor)
    eventCursor = player.sim.events.len
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg
    return -1

proc gridlockPacketPointer(): ptr uint8
    {.exportc: "gridlock_packet_ptr", cdecl.} =
  if packet.len == 0: nil else: cast[ptr uint8](packet[0].addr)

proc gridlockPacketLength(): cint {.exportc: "gridlock_packet_len", cdecl.} =
  cint(packet.len)

proc gridlockMismatchTick(): cint
    {.exportc: "gridlock_mismatch_tick", cdecl.} =
  if runtimeLoaded: cint(player.hashMismatchTick) else: -1

proc gridlockErrorPointer(): ptr uint8
    {.exportc: "gridlock_error_ptr", cdecl.} =
  if lastError.len == 0: nil else: cast[ptr uint8](lastError[0].addr)

proc gridlockErrorLength(): cint {.exportc: "gridlock_error_len", cdecl.} =
  cint(lastError.len)

proc gridlockStagePointer(): ptr uint8
    {.exportc: "gridlock_stage_ptr", cdecl.} =
  ## Unlike gridlock_error_*, this stays valid after an allocation-failure
  ## abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0: nil else: cast[ptr uint8](stageNote[0].addr)

proc gridlockStageLength(): cint {.exportc: "gridlock_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the replay player and the packet buffer while the wasm module
  # stays alive and JS keeps calling gridlock_frame. Unwinding main through
  # emscripten's live-runtime exit skips the destructor epilogue entirely, so
  # globals stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
