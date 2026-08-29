## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with. Historically each HTML client re-typed these as
## literals and nothing enforced agreement — a retuned PlaybackSpeeds would
## silently desync every client. This module renders them ONCE, from the same
## Nim consts the engine runs on; the server splices the block into every
## served page and tools/gen_wire_constants.nim emits it for the static wasm
## bundle. Clients read `window.GRIDLOCK_WIRE`.

import types

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add(",")
    result.add($value)
  result.add("]")

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (command '5', one sim tick every other
  # display frame); it rides ahead of the engine's integer PlaybackSpeeds.
  "window.GRIDLOCK_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",laneCount:" & $LaneCount &
  ",laneCells:" & $LaneCellsDefault &
  ",seats:" & $Seats &
  ",protocol:\"" & ReplayProtocol & "\"" &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
