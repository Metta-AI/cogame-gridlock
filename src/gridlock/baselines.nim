## The two scripted baselines. Both emit the identical plan JSON on the same
## 10 s cadence as an LLM seat, so their output is legal by construction and
## directly comparable — and both are PURE functions of the seat's view,
## which is what makes the bounded-orders test meaningful.
##
##   dispatcher — congestion-aware shortest path with jam-triggered metering.
##                The certification player, the default, and the stronger.
##   beeline    — pure greedy shortest path at full throttle. Deliberately
##                weaker, and thematically the villain of the idea: it never
##                reprices a queue and never meters itself, so a table with
##                beeline seats on it jams.

import std/strutils
import types
import plan
import view

type
  ScriptKind* = enum
    skNone = "none"
    skDispatcher = "dispatcher"
    skBeeline = "beeline"

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values, bullwhip's `parseScriptKind` shape.
  case strutils.strip(text).toLowerAscii()
  of "1", "true", "yes", "dispatcher", "default": skDispatcher
  of "beeline", "greedy": skBeeline
  else: skNone

proc clampTo(value, lo, hi: int): int =
  if value < lo: lo elif value > hi: hi else: value

proc dispatcherPlan*(input: BaselineInput): RoutingPlan =
  let jam = clampTo(input.jamIndex, 0, 100)
  result = defaultPlan()
  result.source = psScripted
  result.congestionWeight = clampTo(30 + jam, 30, 95)
  result.patience = if jam < 40: 60 else: 35
  result.dispatch =
    if jam < 35: 100
    elif jam < 55: 80
    elif jam < 75: 60
    else: 45
  result.spread = if jam < 45: 40 else: 80
  result.corridor = -1
  let hot = hottestDistrict(input.digits)
  var avoid = -1
  if input.digits[hot] >= 7 and hot != input.depotDistrict:
    var clash = false
    for d in input.nextDestDistricts:
      if d == hot:
        clash = true
        break
    if not clash:
      avoid = hot
  result.avoid = avoid
  result.priority = if input.backlog > 55: prFar else: prNear
  result.note = cleanLine("dispatcher: jam=" & $jam & " dispatch=" &
    $result.dispatch & " avoid=" &
    (if avoid < 0: "-" else: districtName(avoid)), MaxNoteRunes)
  result.say = ""

proc beelinePlan*(): RoutingPlan =
  result = defaultPlan()
  result.source = psScripted
  result.congestionWeight = 0
  result.patience = 100
  result.dispatch = 100
  result.spread = 0
  result.corridor = -1
  result.avoid = -1
  result.priority = prFifo
  result.note = "beeline: shortest path, full throttle"
  result.say = ""

proc scriptedPlan*(input: BaselineInput, kind: ScriptKind): RoutingPlan =
  case kind
  of skBeeline: beelinePlan()
  else: dispatcherPlan(input)
