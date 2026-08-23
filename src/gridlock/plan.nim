## The routing plan: the schema a seat emits every turn, tolerant parsing,
## repair, and the router coefficients derived from it.
##
## The RESOLVED, repaired, clamped plan is what is installed and what is
## recorded — playback never re-runs the repair.

import std/[json, strutils, unicode]
import types

const
  DefaultCongestionWeight* = 40
  DefaultPatience* = 50
  DefaultDispatch* = 100
  DefaultSpread* = 40

proc defaultPlan*(): RoutingPlan =
  RoutingPlan(
    congestionWeight: DefaultCongestionWeight,
    patience: DefaultPatience,
    dispatch: DefaultDispatch,
    spread: DefaultSpread,
    corridor: -1,
    avoid: -1,
    priority: prFifo,
    note: "",
    say: "",
    source: psScripted,
    latencyMs: 0)

proc clampPct(value: int): int =
  if value < 0: 0 elif value > 100: 100 else: value

# ---------------------------------------------------------------------------
# Tolerant extraction. Bullwhip's `extractJsonObject` shape: strip fences,
# take the outermost balanced object even when the model prefixed prose.
# ---------------------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  let start = text.find('{')
  if start < 0:
    var head = strutils.strip(text)
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(GridlockError,
      "no JSON object in reply: " & head.replace("\n", " "))
  var depth = 0
  var inString = false
  var escaped = false
  var stop = -1
  for i in start ..< text.len:
    let c = text[i]
    if inString:
      if escaped: escaped = false
      elif c == '\\': escaped = true
      elif c == '"': inString = false
      continue
    case c
    of '"': inString = true
    of '{': inc depth
    of '}':
      dec depth
      if depth == 0:
        stop = i
        break
    else: discard
  if stop < 0:
    stop = text.rfind('}')
  if stop <= start:
    raise newException(GridlockError, "unbalanced JSON object in reply")
  parseJson(text[start .. stop])

proc numberField(node: JsonNode, key: string): tuple[ok: bool, value: int] =
  ## Accepts an int, a float, a numeric string, and "70%".
  let field = node{key}
  if field == nil or field.kind == JNull:
    return (false, 0)
  case field.kind
  of JInt:
    (true, int(field.getInt()))
  of JFloat:
    (true, int(field.getFloat()))
  of JBool:
    (true, if field.getBool(): 100 else: 0)
  of JString:
    var text = strutils.strip(field.getStr())
    if text.endsWith("%"):
      text = text[0 ..< text.high]
    text = strutils.strip(text)
    if text.len == 0:
      return (false, 0)
    try:
      (true, int(parseFloat(text)))
    except ValueError:
      (false, 0)
  else:
    (false, 0)

proc districtFromName(text: string): int =
  let wanted = strutils.strip(text).toUpperAscii()
  for i, name in DistrictNameTable:
    if name == wanted:
      return i
  -1

proc districtField(node: JsonNode, key: string): tuple[ok: bool, value: int] =
  ## `[bx,by]`, `{"bx":..,"by":..}`, a district name, or null.
  let field = node{key}
  if field == nil or field.kind == JNull:
    return (false, -1)
  case field.kind
  of JArray:
    if field.len != 2:
      return (true, -1)
    var bx, by: int
    for i, child in field.elems:
      var v = 0
      case child.kind
      of JInt: v = int(child.getInt())
      of JFloat: v = int(child.getFloat())
      of JString:
        try: v = int(parseFloat(strutils.strip(child.getStr())))
        except ValueError: return (true, -1)
      else: return (true, -1)
      if v < 0: v = 0
      if v > DistrictCols - 1: v = DistrictCols - 1
      if i == 0: bx = v else: by = v
    (true, districtIndex(bx, by))
  of JObject:
    let bxNode = field{"bx"}
    let byNode = field{"by"}
    if bxNode == nil or byNode == nil:
      return (true, -1)
    var bx = bxNode.getInt()
    var by = byNode.getInt()
    if bx < 0: bx = 0
    if bx > DistrictCols - 1: bx = DistrictCols - 1
    if by < 0: by = 0
    if by > DistrictRows - 1: by = DistrictRows - 1
    (true, districtIndex(bx, by))
  of JString:
    (true, districtFromName(field.getStr()))
  else:
    (true, -1)

proc parsePriority*(text: string): Priority =
  case strutils.strip(text).toLowerAscii()
  of "near", "nearest", "close": prNear
  of "far", "furthest", "farthest": prFar
  else: prFifo

proc hasAnyPlanKey*(node: JsonNode): bool =
  if node == nil or node.kind != JObject:
    return false
  for key in ["congestion_weight", "patience", "dispatch", "spread",
      "corridor", "avoid", "priority", "note", "say"]:
    if node.hasKey(key):
      return true
  false

proc repairPlan*(node: JsonNode, previous: RoutingPlan): RoutingPlan =
  ## Every field repaired against `previous` (the plan the seat played last
  ## turn, or `defaultPlan()` on turn 0). Never raises.
  result = previous
  result.source = psLlm
  result.latencyMs = 0
  result.note = ""
  result.say = ""
  block:
    let got = numberField(node, "congestion_weight")
    result.congestionWeight =
      if got.ok: clampPct(got.value) else: previous.congestionWeight
  block:
    let got = numberField(node, "patience")
    result.patience = if got.ok: clampPct(got.value) else: previous.patience
  block:
    let got = numberField(node, "dispatch")
    result.dispatch = if got.ok: clampPct(got.value) else: previous.dispatch
  block:
    let got = numberField(node, "spread")
    result.spread = if got.ok: clampPct(got.value) else: previous.spread
  block:
    let got = districtField(node, "corridor")
    result.corridor = if got.ok: got.value else: previous.corridor
  block:
    let got = districtField(node, "avoid")
    result.avoid = if got.ok: got.value else: previous.avoid
  if result.avoid >= 0 and result.avoid == result.corridor:
    ## A plan may not prefer and shun the same district.
    result.avoid = -1
  let priorityNode = node{"priority"}
  result.priority =
    if priorityNode != nil and priorityNode.kind == JString:
      parsePriority(priorityNode.getStr())
    else:
      prFifo
  let noteNode = node{"note"}
  if noteNode != nil and noteNode.kind == JString:
    result.note = cleanLine(noteNode.getStr(), MaxNoteRunes)
  let sayNode = node{"say"}
  if sayNode != nil and sayNode.kind == JString:
    result.say = cleanLine(sayNode.getStr(), MaxSayRunes)

proc parsePlan*(text: string, previous: RoutingPlan): RoutingPlan =
  ## Tolerant parse + repair. Raises only when no object carrying at least one
  ## recognised plan key can be recovered — which is what triggers the retry
  ## and then the scripted fallback.
  let node = extractJsonObject(text)
  if not hasAnyPlanKey(node):
    raise newException(GridlockError, "reply carried no plan keys")
  repairPlan(node, previous)

proc planJson*(plan: RoutingPlan): JsonNode =
  result = %*{
    "congestion_weight": plan.congestionWeight,
    "patience": plan.patience,
    "dispatch": plan.dispatch,
    "spread": plan.spread,
    "priority": $plan.priority,
    "note": plan.note,
    "say": plan.say}
  result["corridor"] =
    if plan.corridor < 0: newJNull()
    else: %[districtX(plan.corridor), districtY(plan.corridor)]
  result["avoid"] =
    if plan.avoid < 0: newJNull()
    else: %[districtX(plan.avoid), districtY(plan.avoid)]

proc planFromJson*(node: JsonNode): RoutingPlan =
  ## Reads back a RECORDED plan (already resolved) from a replay.
  result = repairPlan(node, defaultPlan())
  result.source =
    case node{"source"}.getStr("scripted")
    of "llm": psLlm
    of "fallback": psFallback
    else: psScripted
  result.latencyMs = node{"latency_ms"}.getInt(0)

# ---------------------------------------------------------------------------
# Derived router coefficients.
# ---------------------------------------------------------------------------

proc replanQueue*(plan: RoutingPlan): int {.inline.} =
  ## Patience 0 -> re-plan when the next lane holds 3 vans; 100 -> 13.
  3 + (plan.patience * 10) div 100

proc activeCap*(plan: RoutingPlan, fleetSize: int): int {.inline.} =
  (plan.dispatch * fleetSize + fleetSize) div 100

proc releasePerStep*(plan: RoutingPlan): int {.inline.} =
  ## Spread 0 -> bursts of six; 100 -> one at a time.
  1 + ((100 - plan.spread) * 5) div 100

proc planIsLegal*(plan: RoutingPlan): bool =
  plan.congestionWeight in 0 .. 100 and plan.patience in 0 .. 100 and
    plan.dispatch in 0 .. 100 and plan.spread in 0 .. 100 and
    plan.corridor in -1 .. (DistrictCount - 1) and
    plan.avoid in -1 .. (DistrictCount - 1) and
    (plan.avoid < 0 or plan.avoid != plan.corridor) and
    plan.note.runeLen <= MaxNoteRunes and plan.say.runeLen <= MaxSayRunes
