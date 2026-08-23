## The event vocabulary and the `SimEventKind` -> JSON-key discipline.
##
## Kept in shape from paintbot's `src/ctf/events.nim`: one enum whose string
## values ARE the wire `type`, and one `jsonRow` that merges the per-kind body
## onto the common `t` / `turn` header. The phase-60 verifier reads `plan`,
## `deliver`, `gridlock`, `meter` and `fallback` out of this stream.

import std/json
import types

proc jsonRow*(event: GameEvent): JsonNode =
  result = newJObject()
  result["type"] = %($event.kind)
  result["t"] = %event.t
  if event.turn >= 0:
    result["turn"] = %event.turn
  if event.body != nil and event.body.kind == JObject:
    for key, value in event.body.pairs:
      result[key] = value

proc eventsJson*(events: openArray[GameEvent]): JsonNode =
  result = newJArray()
  for event in events:
    result.add(jsonRow(event))

proc newEvent*(kind: SimEventKind, t: int, turn: int,
    body: JsonNode): GameEvent =
  GameEvent(kind: kind, t: t, turn: turn,
    body: (if body == nil: newJObject() else: body))

proc describe*(event: GameEvent): string =
  ## One plain-language line for the spectator feed and for the seat's
  ## `events_last_turn` list. Contains ONLY fleet aliases, never a real name.
  case event.kind
  of seGridlock:
    "gridlock in " & event.body{"district_name"}.getStr("?")
  of seJam:
    "jam on " & event.body{"from"}.getStr("?") & "->" &
      event.body{"to"}.getStr("?")
  of seJamClear:
    "jam cleared on lane " & $event.body{"lane"}.getInt()
  of seMeter:
    event.body{"fleet"}.getStr("?") & " holds " &
      $event.body{"held"}.getInt() & " vans at the depot"
  of seFallback:
    "fleet " & $event.body{"seat"}.getInt() & " fell back (" &
      event.body{"cause"}.getStr("?") & ")"
  of seBudgetGuard:
    "budget guard engaged"
  else:
    $event.kind
