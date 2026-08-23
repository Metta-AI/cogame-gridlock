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

  DispatcherTuning* = object
    ## Every constant in the `dispatcher` rule, named so `tools/tune_baselines`
    ## can sweep the real baseline rather than a copy of it.
    ## `DefaultDispatcherTuning` below is what ships; the grid that chose it is
    ## `tools/tuning/dispatcher_grid.md`.
    weightBase*: int          ## congestion_weight = clamp(weightBase + jam, …)
    weightMin*, weightMax*: int
    patienceJam*: int         ## jam index at which patience drops
    patienceCalm*, patienceJammed*: int
    dispatchJam1*, dispatchJam2*, dispatchJam3*: int
    dispatchCalm*, dispatchBusy*, dispatchHeavy*, dispatchSevere*: int
    spreadJam*: int           ## jam index at which departures stagger
    spreadCalm*, spreadJammed*: int
    avoidDigit*: int          ## district digit that earns an `avoid`
    farBacklog*: int          ## backlog above which `far` parcels are taken

const DefaultDispatcherTuning* = DispatcherTuning(
  weightBase: 30, weightMin: 30, weightMax: 95,
  patienceJam: 40, patienceCalm: 60, patienceJammed: 35,
  dispatchJam1: 35, dispatchJam2: 55, dispatchJam3: 75,
  dispatchCalm: 100, dispatchBusy: 80, dispatchHeavy: 60, dispatchSevere: 45,
  spreadJam: 45, spreadCalm: 40, spreadJammed: 80,
  avoidDigit: 7, farBacklog: 55)

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values, bullwhip's `parseScriptKind` shape.
  case strutils.strip(text).toLowerAscii()
  of "1", "true", "yes", "dispatcher", "default": skDispatcher
  of "beeline", "greedy": skBeeline
  else: skNone

proc clampTo(value, lo, hi: int): int =
  if value < lo: lo elif value > hi: hi else: value

proc dispatcherPlan*(input: BaselineInput,
    tuning = DefaultDispatcherTuning): RoutingPlan =
  let jam = clampTo(input.jamIndex, 0, 100)
  result = defaultPlan()
  result.source = psScripted
  result.congestionWeight =
    clampTo(tuning.weightBase + jam, tuning.weightMin, tuning.weightMax)
  result.patience =
    if jam < tuning.patienceJam: tuning.patienceCalm
    else: tuning.patienceJammed
  result.dispatch =
    if jam < tuning.dispatchJam1: tuning.dispatchCalm
    elif jam < tuning.dispatchJam2: tuning.dispatchBusy
    elif jam < tuning.dispatchJam3: tuning.dispatchHeavy
    else: tuning.dispatchSevere
  result.spread =
    if jam < tuning.spreadJam: tuning.spreadCalm else: tuning.spreadJammed
  result.corridor = -1
  let hot = hottestDistrict(input.digits)
  var avoid = -1
  if input.digits[hot] >= tuning.avoidDigit and hot != input.depotDistrict:
    var clash = false
    for d in input.nextDestDistricts:
      if d == hot:
        clash = true
        break
    if not clash:
      avoid = hot
  result.avoid = avoid
  result.priority =
    if input.backlog > tuning.farBacklog: prFar else: prNear
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
