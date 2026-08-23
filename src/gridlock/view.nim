## The per-seat view: exactly what a seat can see, and nothing else.
##
## Visible: the full static city, PUBLIC live congestion in aggregate (the
## district heat grid, the eight worst lanes, the city jam index), the seat's
## own complete fleet state, its own next six orders, and the public per-fleet
## delivery and on-road counters.
##
## Hidden: the per-fleet composition of any lane's queue, every rival's plan /
## note / say / prompt / policy kind, every rival's destinations, backlog and
## trip times, individual rival vehicle positions, the canonical destination
## schedule, the seat->depot permutation for any other seat, the seed, and the
## future.
##
## The only names anywhere in here are the depot aliases. Real policy names
## live in `replay.names.players`, `results.names` and the viewer chrome.

import std/[algorithm, json]
import types
import graph
import plan
import events

type
  HotLane* = object
    lane*: int
    q*: int
    blockedTicks*: int

  BaselineInput* = object
    ## The slice of the view the scripted baselines are pure functions of.
    jamIndex*: int
    digits*: array[DistrictCount, int]
    backlog*: int
    depotDistrict*: int
    nextDestDistricts*: seq[int]
    stalledPct*: int

proc hottestDistrict*(digits: array[DistrictCount, int]): int =
  result = 0
  for d in 1 ..< DistrictCount:
    if digits[d] > digits[result]:
      result = d

proc hotLanes*(sim: Sim, limit: int): seq[HotLane] =
  var all = newSeqOfCap[HotLane](LaneCount)
  for lane in 0 ..< LaneCount:
    if sim.q[lane] <= 0:
      continue
    var blockedTicks = 0
    let g = sim.cells[lane * sim.config.laneCells + sim.config.laneCells - 1]
    if g >= 0:
      blockedTicks = sim.tick - sim.vehicles[g].lastMoveTick
    all.add(HotLane(lane: lane, q: sim.q[lane], blockedTicks: blockedTicks))
  all.sort(proc (a, b: HotLane): int =
    if a.q != b.q: cmp(b.q, a.q) else: cmp(a.lane, b.lane))
  if all.len > limit:
    all.setLen(limit)
  all

proc seatCounts*(sim: Sim, seat: int): tuple[docked, loading, waiting,
    loaded, empty, stalled: int] =
  for g in seat * sim.config.fleetSize ..<
      (seat + 1) * sim.config.fleetSize:
    let vehicle = sim.vehicles[g]
    if vehicle.lane < 0:
      inc result.docked
      if vehicle.loadTicksLeft > 0:
        inc result.loading
      elif vehicle.waiting:
        inc result.waiting
    else:
      if vehicle.state == vsStalled:
        inc result.stalled
      if vehicle.hasParcel:
        inc result.loaded
      else:
        inc result.empty

proc baselineInput*(sim: Sim, seat: int): BaselineInput =
  result.jamIndex = sim.jamIndex
  result.digits = sim.districtHeat
  result.backlog = sim.backlog[seat].len
  result.depotDistrict = districtOfNode(depotNode(sim.seatDepot[seat]))
  result.stalledPct = sim.ownStallPct[seat]
  for i in 0 ..< min(6, sim.backlog[seat].len):
    result.nextDestDistricts.add(districtOfNode(sim.backlog[seat][i].dest))

proc eventsLastTurn*(sim: Sim, limit: int): seq[string] =
  let lower = max(0, (sim.turn - 1) * sim.config.turnTicks)
  for i in countdown(sim.events.high, 0):
    if sim.events[i].t < lower:
      break
    case sim.events[i].kind
    of seGridlock, seJam:
      result.add(describe(sim.events[i]))
      if result.len >= limit:
        break
    else: discard

proc buildView*(sim: Sim, seat: int): JsonNode =
  let depot = sim.seatDepot[seat]
  let depotNodeIndex = depotNode(depot)
  let counts = seatCounts(sim, seat)
  let turns = (sim.config.episodeTicks + sim.config.turnTicks - 1) div
    sim.config.turnTicks
  var orders = newJArray()
  for i in 0 ..< min(6, sim.backlog[seat].len):
    let parcel = sim.backlog[seat][i]
    orders.add(%*{
      "id": parcel.id,
      "dest": [nodeX(parcel.dest), nodeY(parcel.dest)],
      "district": [districtX(districtOfNode(parcel.dest)),
                   districtY(districtOfNode(parcel.dest))],
      "age_s": float(sim.tick - parcel.createdTick) / float(TargetFps)})
  var hot = newJArray()
  for entry in hotLanes(sim, 8):
    let lane = laneOf(entry.lane)
    hot.add(%*{
      "from": [nodeX(lane.tail), nodeY(lane.tail)],
      "to": [nodeX(lane.head), nodeY(lane.head)],
      "class": (if lane.arterial: "arterial" else: "local"),
      "q": entry.q,
      "cap": sim.config.laneCells,
      "blocked_s": float(entry.blockedTicks) / float(TargetFps)})
  var heat = newJArray()
  for by in 0 ..< DistrictRows:
    var line = ""
    for bx in 0 ..< DistrictCols:
      line.add($sim.districtHeat[districtIndex(bx, by)])
    heat.add(%line)
  var fleets = newJArray()
  for other in 0 ..< Seats:
    var onRoad = 0
    for g in other * sim.config.fleetSize ..<
        (other + 1) * sim.config.fleetSize:
      if sim.vehicles[g].lane >= 0:
        inc onRoad
    fleets.add(%*{
      "fleet": FleetAliases[sim.seatDepot[other]],
      "delivered": sim.delivered[other],
      "on_road": onRoad})
  var lastPlan: JsonNode =
    if sim.turn <= 0: newJNull() else: planJson(sim.plans[seat])
  var recent = newJArray()
  for line in eventsLastTurn(sim, 6):
    recent.add(%line)
  let meanTrip =
    if sim.tripCount[seat] > 0:
      float(sim.tripTicks[seat]) / float(sim.tripCount[seat]) /
        float(TargetFps)
    else: 0.0
  %*{
    "turn": sim.turn,
    "of": turns,
    "tick": sim.tick,
    "ticks_left": max(0, sim.config.episodeTicks - sim.tick),
    "seconds_left":
      float(max(0, sim.config.episodeTicks - sim.tick)) / float(TargetFps),
    "you": {
      "fleet": FleetAliases[depot],
      "colour": FleetColours[depot],
      "depot": [nodeX(depotNodeIndex), nodeY(depotNodeIndex)],
      "depot_district": [districtX(districtOfNode(depotNodeIndex)),
                         districtY(districtOfNode(depotNodeIndex))],
      "vans": sim.config.fleetSize,
      "docked": counts.docked,
      "loading": counts.loading,
      "waiting_dispatch": counts.waiting,
      "on_road_loaded": counts.loaded,
      "on_road_empty": counts.empty,
      "stalled": counts.stalled,
      "delivered": sim.delivered[seat],
      "delivered_last_turn": sim.deliveredLastTurn[seat],
      "backlog": sim.backlog[seat].len,
      "mean_trip_seconds": meanTrip,
      "stalled_pct": sim.ownStallPct[seat],
      "last_plan": lastPlan,
      "next_orders": orders},
    "city": {
      "grid": [GridCols, GridRows],
      "districts": [DistrictCols, DistrictRows],
      "lane_cells": sim.config.laneCells,
      "arterial_cols": ArterialLines,
      "arterial_rows": ArterialLines,
      "signal": "4.0 s cycle, 2.0 s NS then 2.0 s EW, " &
        "offset ((ix+iy) mod 4) x 1.0 s",
      "discharge_per_green_step": {"arterial": 2, "local": 1},
      "jam_index": sim.jamIndex,
      "districts_heat": heat,
      "hot_lanes": hot},
    "fleets": fleets,
    "events_last_turn": recent}
