## The turn clock's bookkeeping, the congestion statistics, the invariant
## guards, and the score.
##
## Score is own parcels delivered — a raw count, deliberately NOT a share and
## NOT constant-sum. Four greedy fleets can hold each other to 300 parcels
## between them while four metered fleets clear 700, and the results document
## carries `total_delivered` and `jam_index_mean` so that collapse is visible
## in the numbers and on the endcard.

import std/[json, math]
import types
import graph
import events

proc resetTurnWindow*(sim: var Sim) =
  for lane in 0 ..< LaneCount:
    sim.laneOccAccum[lane] = 0
  sim.occSamples = 0
  sim.moveOpp = 0
  sim.blockedOpp = 0
  for seat in 0 ..< Seats:
    sim.seatMoveOpp[seat] = 0
    sim.seatBlockedOpp[seat] = 0

proc accumulateStats*(sim: var Sim) =
  ## Runs every tick (step 11). Lane occupancy, move opportunities, stall
  ## state and stall ticks.
  for lane in 0 ..< LaneCount:
    sim.laneOccAccum[lane] += sim.q[lane]
  inc sim.occSamples
  let countOpportunities = sim.tick mod sim.config.moveTicks == 0
  for g in 0 ..< sim.vehicles.len:
    if sim.vehicles[g].lane < 0:
      continue
    let seat = sim.vehicles[g].fleet
    if countOpportunities:
      inc sim.moveOpp
      inc sim.seatMoveOpp[seat]
      inc sim.totalSeatMoveOpp[seat]
      if sim.vehicles[g].lastMoveTick != sim.tick:
        inc sim.blockedOpp
        inc sim.seatBlockedOpp[seat]
        inc sim.totalSeatBlockedOpp[seat]
    if sim.tick - sim.vehicles[g].lastMoveTick >= 24:
      sim.vehicles[g].state = vsStalled
      inc sim.stallVehicleTicks[seat]
    elif sim.vehicles[g].state == vsStalled:
      sim.vehicles[g].state =
        if sim.vehicles[g].hasParcel: vsLoaded else: vsEmpty

proc districtDigits*(sim: Sim): array[DistrictCount, int] =
  var sums: array[DistrictCount, int]
  var counts: array[DistrictCount, int]
  for lane in 0 ..< LaneCount:
    let d = districtOfNode(laneOf(lane).head)
    sums[d] += sim.laneOccAccum[lane]
    inc counts[d]
  for d in 0 ..< DistrictCount:
    let denominator = counts[d] * max(1, sim.occSamples) * sim.config.laneCells
    if denominator <= 0:
      result[d] = 0
    else:
      let pct = (sums[d] * 100) div denominator
      result[d] = min(9, pct div 10)

proc heatStrings*(digits: array[DistrictCount, int]): seq[string] =
  for by in 0 ..< DistrictRows:
    var row = ""
    for bx in 0 ..< DistrictCols:
      row.add($digits[districtIndex(bx, by)])
    result.add(row)

proc refreshHeat*(sim: var Sim) =
  ## Every 48 ticks: the 3x3 district digits, the city jam index and the
  ## per-seat stall percentage, plus one `heat` event.
  sim.districtHeat = districtDigits(sim)
  sim.jamIndex =
    if sim.moveOpp > 0: min(100, (100 * sim.blockedOpp) div sim.moveOpp)
    else: 0
  for seat in 0 ..< Seats:
    sim.ownStallPct[seat] =
      if sim.seatMoveOpp[seat] > 0:
        min(100, (100 * sim.seatBlockedOpp[seat]) div sim.seatMoveOpp[seat])
      else: 0
  sim.jamIndexSum += sim.jamIndex
  inc sim.jamIndexSamples
  if sim.jamIndex > sim.jamIndexPeak:
    sim.jamIndexPeak = sim.jamIndex
  var onRoad = newJArray()
  for seat in 0 ..< Seats:
    var count = 0
    for g in seat * sim.config.fleetSize ..<
        (seat + 1) * sim.config.fleetSize:
      if sim.vehicles[g].lane >= 0:
        inc count
    onRoad.add(%count)
  var heat = newJArray()
  for row in heatStrings(sim.districtHeat):
    heat.add(%row)
  sim.events.add(newEvent(seHeat, sim.tick, sim.turn, %*{
    "districts": heat,
    "jam_index": sim.jamIndex,
    "on_road": onRoad}))

proc nodeLabel*(n: int): string = $nodeX(n) & "," & $nodeY(n)

proc jamWatch*(sim: var Sim) =
  ## `jam` when a lane crosses `jamThreshold` having been below it;
  ## `jam_clear` when it falls back below 6.
  for lane in 0 ..< LaneCount:
    let occupancy = sim.q[lane]
    if not sim.laneJammed[lane]:
      if occupancy >= sim.config.jamThreshold:
        sim.laneJammed[lane] = true
        sim.laneJamStart[lane] = sim.tick
        sim.events.add(newEvent(seJam, sim.tick, sim.turn, %*{
          "lane": lane,
          "from": nodeLabel(laneOf(lane).tail),
          "to": nodeLabel(laneOf(lane).head),
          "class": (if laneOf(lane).arterial: "arterial" else: "local"),
          "q": occupancy}))
    elif occupancy < 6:
      sim.laneJammed[lane] = false
      sim.events.add(newEvent(seJamClear, sim.tick, sim.turn, %*{
        "lane": lane,
        "q": occupancy,
        "duration_ticks": sim.tick - sim.laneJamStart[lane]}))

proc gridlockWatch*(sim: var Sim) =
  ## Four or more fully blocked lanes whose head nodes lie in one district,
  ## at most one event per district per 240 ticks.
  var blocked: array[DistrictCount, int]
  for lane in 0 ..< LaneCount:
    if sim.q[lane] >= sim.config.laneCells:
      inc blocked[districtOfNode(laneOf(lane).head)]
  for d in 0 ..< DistrictCount:
    if blocked[d] < 4:
      continue
    if sim.lastGridlockTick[d] >= 0 and
        sim.tick - sim.lastGridlockTick[d] < 240:
      continue
    sim.lastGridlockTick[d] = sim.tick
    inc sim.gridlockEvents
    var involved = newJArray()
    for seat in 0 ..< Seats:
      var vans = 0
      for g in 0 ..< sim.vehicles.len:
        if sim.vehicles[g].fleet != seat: continue
        let lane = sim.vehicles[g].lane
        if lane < 0: continue
        if sim.q[lane] < sim.config.laneCells: continue
        if districtOfNode(laneOf(lane).head) != d: continue
        inc vans
      if vans > 0:
        involved.add(%*{"fleet": FleetAliases[sim.seatDepot[seat]],
          "vans": vans})
    sim.events.add(newEvent(seGridlock, sim.tick, sim.turn, %*{
      "district": [districtX(d), districtY(d)],
      "district_name": districtName(d),
      "blocked_lanes": blocked[d],
      "fleets_involved": involved}))

proc routeStartFailure*(sim: Sim, g: int): string =
  ## Step 14's route guard, checked on every COMPLETED replan: an on-road
  ## van's route starts with the lane it occupies, and the lane after it
  ## leaves that lane's head node. A route that fails this is a router bug —
  ## a merely STALE route (the vehicle moved on before its replan was popped)
  ## is repaired by `nextLaneOf`, which is why the guard is applied where the
  ## replan lands and not to every vehicle on the board.
  let vehicle = sim.vehicles[g]
  if vehicle.lane < 0 or vehicle.route.len == 0:
    return ""
  if vehicle.route[0] != vehicle.lane:
    return "vehicle " & $g & " replanned onto a route starting at lane " &
      $vehicle.route[0] & ", not its own lane " & $vehicle.lane
  if vehicle.route.len >= 2 and
      laneOf(vehicle.route[1]).tail != laneOf(vehicle.lane).head:
    return "vehicle " & $g & " replanned onto a route whose next lane " &
      $vehicle.route[1] & " does not start at node " &
      nodeLabel(laneOf(vehicle.lane).head)
  ""

proc invariantFailure*(sim: Sim): string =
  ## Step 14's guards. Returns "" when everything holds.
  if sim.routeFault.len > 0:
    return sim.routeFault
  var seen = newSeq[int](sim.cells.len)
  for i in 0 ..< seen.len:
    seen[i] = -1
  for g in 0 ..< sim.vehicles.len:
    let lane = sim.vehicles[g].lane
    if lane == DockedLane:
      continue
    if lane < 0 or lane >= LaneCount:
      return "vehicle " & $g & " is off-graph (lane " & $lane & ")"
    if sim.vehicles[g].cell < 0 or
        sim.vehicles[g].cell >= sim.config.laneCells:
      return "vehicle " & $g & " is off-graph (cell " &
        $sim.vehicles[g].cell & ")"
    let slot = lane * sim.config.laneCells + sim.vehicles[g].cell
    if seen[slot] >= 0:
      return "two vehicles in one cell: " & $seen[slot] & " and " & $g
    seen[slot] = g
    if sim.cells[slot] != g:
      return "cell index desynchronised at slot " & $slot
  for seat in 0 ..< Seats:
    if sim.backlog[seat].len > sim.config.backlogMax:
      return "backlog above cap for seat " & $seat
    if sim.delivered[seat] < sim.deliveredAtTurnStart[seat]:
      return "delivered counter decreased for seat " & $seat
  ""

# ---------------------------------------------------------------------------
# Score.
# ---------------------------------------------------------------------------

proc scoreOf*(sim: Sim, seat: int): float =
  ## Raw count of own parcels delivered. Higher is better.
  float(sim.delivered[seat])

proc winFlags*(delivered: openArray[int]): seq[bool] =
  result = newSeq[bool](delivered.len)
  if delivered.len == 0:
    return
  var best = delivered[0]
  for value in delivered:
    if value > best: best = value
  var count = 0
  for value in delivered:
    if value == best: inc count
  for i, value in delivered:
    result[i] = value == best and count == 1

proc winnerOf*(delivered: openArray[int]): int =
  ## Slot index of the unique maximum, or -1 on a tie.
  let flags = winFlags(delivered)
  for i, flag in flags:
    if flag: return i
  -1

proc meanTripSeconds*(sim: Sim, seat: int): float =
  if sim.tripCount[seat] == 0:
    return 0.0
  round(float(sim.tripTicks[seat]) / float(sim.tripCount[seat]) /
    float(TargetFps) * 10.0) / 10.0

proc resultsJson*(sim: Sim): JsonNode =
  ## The closed schema. Adding or removing a key here means editing
  ## coworld_manifest_template.json's results_schema and
  ## tests/test_manifest.nim in the same commit.
  let faulted = sim.reason == "fault"
  var names = newJArray()
  var aliases = newJArray()
  var colours = newJArray()
  var depots = newJArray()
  var policyKinds = newJArray()
  var scores = newJArray()
  var delivered = newJArray()
  var ordersCreated = newJArray()
  var backlogFinal = newJArray()
  var meanTrip = newJArray()
  var stalledSeconds = newJArray()
  var ownStall = newJArray()
  var vans = newJArray()
  var turnsLlm = newJArray()
  var fallbackTurns = newJArray()
  var fallbackCauses = newJArray()
  var deliveredRaw: seq[int]
  for seat in 0 ..< Seats:
    let depot = sim.seatDepot[seat]
    names.add(%sim.names[seat])
    aliases.add(%FleetAliases[depot])
    colours.add(%FleetColours[depot])
    depots.add(%[DepotNodes[depot][0], DepotNodes[depot][1]])
    policyKinds.add(%sim.policyKinds[seat])
    let count = if faulted: 0 else: sim.delivered[seat]
    deliveredRaw.add(count)
    scores.add(%float(count))
    delivered.add(%count)
    ordersCreated.add(%sim.ordersCreated[seat])
    backlogFinal.add(%sim.backlog[seat].len)
    meanTrip.add(%meanTripSeconds(sim, seat))
    stalledSeconds.add(%(sim.stallVehicleTicks[seat] div TargetFps))
    ownStall.add(%(
      if sim.totalSeatMoveOpp[seat] > 0:
        min(100, (100 * sim.totalSeatBlockedOpp[seat]) div
          sim.totalSeatMoveOpp[seat])
      else: 0))
    vans.add(%sim.config.fleetSize)
    turnsLlm.add(%sim.turnsLlm[seat])
    fallbackTurns.add(%sim.fallbackTurns[seat])
    var causes = newJObject()
    for cause in FallbackCause:
      causes[$cause] = %sim.fallbackCauses[seat][cause]
    fallbackCauses.add(causes)
  var total = 0
  for value in deliveredRaw:
    total += value
  var win = newJArray()
  let flags = winFlags(deliveredRaw)
  for flag in flags:
    win.add(%flag)
  let winnerIndex = if faulted: -1 else: winnerOf(deliveredRaw)
  result = %*{
    "names": names,
    "aliases": aliases,
    "colours": colours,
    "depots": depots,
    "policy_kinds": policyKinds,
    "scores": scores,
    "win": win,
    "delivered": delivered,
    "total_delivered": total,
    "orders_created": ordersCreated,
    "backlog_final": backlogFinal,
    "mean_trip_seconds": meanTrip,
    "stalled_vehicle_seconds": stalledSeconds,
    "own_stall_pct": ownStall,
    "vans": vans,
    "jam_index_mean":
      (if sim.jamIndexSamples > 0: sim.jamIndexSum div sim.jamIndexSamples
       else: 0),
    "jam_index_peak": sim.jamIndexPeak,
    "gridlock_events": sim.gridlockEvents,
    "turns_llm": turnsLlm,
    "fallback_turns": fallbackTurns,
    "fallback_causes": fallbackCauses,
    "reason": sim.reason,
    "end_rule": sim.endRule,
    "final_tick": sim.tick,
    "final_turn": sim.turn,
    "seed": sim.config.seed}
  result["winner"] = if winnerIndex < 0: newJNull() else: %winnerIndex

const ResultsKeys* = [
  "names", "aliases", "colours", "depots", "policy_kinds", "scores", "win",
  "delivered", "total_delivered", "orders_created", "backlog_final",
  "mean_trip_seconds", "stalled_vehicle_seconds", "own_stall_pct", "vans",
  "jam_index_mean", "jam_index_peak", "gridlock_events", "turns_llm",
  "fallback_turns", "fallback_causes", "reason", "end_rule", "winner",
  "final_tick", "final_turn", "seed"]
