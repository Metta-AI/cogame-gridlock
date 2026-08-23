## The gridlock step loop.
##
## Resolution order per tick is EXACT and has no exceptions — it is what
## makes the native build, the emscripten build and the replay agree:
##
##   0  keyframe (every 24 ticks)
##   1  turn clock          (installPlans, called by the runner)
##   2  signals             (a pure function of the tick; nothing to do)
##   3  orders
##   4  loading
##   5  dispatch (fleet metering) — the commons lever
##   6  vehicle movement, downstream-first
##   7  intersection capacity, signal service, pickup and delivery
##   8  queue spillback     (no step: it falls out of one-vehicle-per-cell)
##   10 replans (bounded by routeBudgetPerTick)
##   11 congestion statistics
##   14 end check
##
## No `sin`, `cos`, `tan`, `exp`, `ln`, `pow`, `sqrt`, `hypot`, `fmod` or
## float arithmetic of any kind appears in the step path; `-ffast-math` is
## banned. A source-grep test enforces both.

import std/json
import types
import config
import city
import graph
import plan
import parcels
import traffic
import rules
import events
import state
import view
import baselines

export types, config, city, graph, plan, parcels, traffic, rules, events,
  state, view, baselines

proc turnsOf*(sim: Sim): int =
  (sim.config.episodeTicks + sim.config.turnTicks - 1) div sim.config.turnTicks

proc initSim*(gameConfig: GameConfig, spec: CitySpec): Sim =
  result.config = gameConfig
  result.city = spec
  result.tick = 0
  result.turn = 0
  result.reason = ""
  result.endRule = ""
  result.rng = initPcg32(gameConfig.seed)

  ## 1. The seat -> depot permutation. Alias and colour are properties of the
  ##    DEPOT, never of the seat, and this draw is re-made every episode —
  ##    that is the idea's per-episode anonymisation.
  var perm = @[0, 1, 2, 3]
  for i in countdown(Seats - 1, 1):
    let j = result.rng.rand(i + 1)
    let keep = perm[i]
    perm[i] = perm[j]
    perm[j] = keep
  for seat in 0 ..< Seats:
    result.seatDepot[seat] = perm[seat]
    result.depotSeat[perm[seat]] = seat
    result.names[seat] =
      if seat < gameConfig.players.len: gameConfig.players[seat].name
      else: "P" & $(seat + 1)
    result.policyKinds[seat] = "scripted"

  ## 2. The canonical destination sequence, drawn once over the non-depot
  ##    nodes. Fleet j receives mirror_j of it.
  let orderSlots = gameConfig.episodeTicks div
    max(1, gameConfig.orderPeriodTicks) + 8
  result.destSchedule = buildDestinationSchedule(result.rng, orderSlots)
  result.destCursor = 0

  let cells = gameConfig.laneCells
  result.cells = newSeq[int](LaneCount * cells)
  for i in 0 ..< result.cells.len:
    result.cells[i] = -1
  result.q = newSeq[int](LaneCount)
  result.noise = newSeq[int](Seats * LaneCount)
  result.laneOccAccum = newSeq[int](LaneCount)
  result.laneJammed = newSeq[bool](LaneCount)
  result.laneJamStart = newSeq[int](LaneCount)
  for d in 0 ..< DistrictCount:
    result.lastGridlockTick[d] = -1_000_000
  result.vehicles = newSeq[Vehicle](Seats * gameConfig.fleetSize)
  for seat in 0 ..< Seats:
    result.plans[seat] = defaultPlan()
    for i in 0 ..< gameConfig.fleetSize:
      let g = seat * gameConfig.fleetSize + i
      result.vehicles[g] = Vehicle(
        fleet: seat,
        lane: DockedLane,
        cell: 0,
        state: vsDocked,
        hasParcel: false,
        parcelId: -1,
        dest: -1,
        target: depotNode(perm[seat]),
        route: @[],
        loadTicksLeft: 0,
        waiting: false,
        lastMoveTick: 0,
        releaseTick: 0,
        queued: false)
  result.nextParcelId = 1
  result.keepSnapshots = true

  var fleets = newJArray()
  for seat in 0 ..< Seats:
    let depot = result.seatDepot[seat]
    fleets.add(%*{
      "alias": FleetAliases[depot],
      "colour": FleetColours[depot],
      "depot": [DepotNodes[depot][0], DepotNodes[depot][1]],
      "seat": seat})
  result.events.add(newEvent(seMatchStart, 0, -1, %*{
    "seed": gameConfig.seed,
    "city": spec.name,
    "fleets": fleets,
    "vans_per_fleet": gameConfig.fleetSize,
    "episode_ticks": gameConfig.episodeTicks,
    "signal": "cycle " & $gameConfig.signalCycleTicks & " ticks, NS " &
      $gameConfig.greenNsTicks & " then EW"}))

# ---------------------------------------------------------------------------
# Snapshots. In memory only, NEVER written to the replay: they exist so a
# backward seek in the viewer replays at most one turn instead of the whole
# match.
# ---------------------------------------------------------------------------

proc takeSnapshot*(sim: Sim): SimSnapshot =
  result.tick = sim.tick
  result.turn = sim.turn
  result.rng = sim.rng
  result.vehicles = sim.vehicles
  result.cells = sim.cells
  result.q = sim.q
  result.backlog = sim.backlog
  result.delivered = sim.delivered
  result.deliveredAtTurnStart = sim.deliveredAtTurnStart
  result.ordersCreated = sim.ordersCreated
  result.nextParcelId = sim.nextParcelId
  result.destCursor = sim.destCursor
  result.plans = sim.plans
  result.noise = sim.noise
  result.replanQueue = @[]
  for i in sim.replanHead ..< sim.replanQueue.len:
    result.replanQueue.add(sim.replanQueue[i])
  result.eventCount = sim.events.len
  result.planCount = sim.planLog.len
  result.keyframeCount = sim.keyframes.len

proc restoreSnapshot*(sim: var Sim, snap: SimSnapshot) =
  ## Also rewinds the derived streams by the counts the snapshot recorded, so
  ## a scrub cannot duplicate keyframes, vehicle bytes, plan records or feed
  ## events.
  if sim.keyframes.len > snap.keyframeCount:
    sim.keyframes.setLen(snap.keyframeCount)
  sim.vehicleBytes.setLen(snap.keyframeCount * sim.vehicles.len * 4)
  if sim.events.len > snap.eventCount:
    sim.events.setLen(snap.eventCount)
  if sim.planLog.len > snap.planCount:
    sim.planLog.setLen(snap.planCount)
  sim.tick = snap.tick
  sim.turn = snap.turn
  sim.rng = snap.rng
  sim.vehicles = snap.vehicles
  sim.cells = snap.cells
  sim.q = snap.q
  sim.backlog = snap.backlog
  sim.delivered = snap.delivered
  sim.deliveredAtTurnStart = snap.deliveredAtTurnStart
  sim.ordersCreated = snap.ordersCreated
  sim.nextParcelId = snap.nextParcelId
  sim.destCursor = snap.destCursor
  sim.plans = snap.plans
  sim.noise = snap.noise
  sim.replanQueue = snap.replanQueue
  sim.replanHead = 0

proc recordKeyframe*(sim: var Sim) =
  var frame = Keyframe(t: sim.tick, d: gridlockStateDigest(sim),
    jam: sim.jamIndex)
  for seat in 0 ..< Seats:
    frame.delivered[seat] = sim.delivered[seat]
    frame.onRoad[seat] = onRoadCount(sim, seat)
    frame.backlog[seat] = sim.backlog[seat].len
  sim.keyframes.add(frame)
  for g in 0 ..< sim.vehicles.len:
    let lane =
      if sim.vehicles[g].lane < 0: DockedSentinel else: sim.vehicles[g].lane
    sim.vehicleBytes.add(char(lane and 0xFF))
    sim.vehicleBytes.add(char((lane shr 8) and 0xFF))
    sim.vehicleBytes.add(char(sim.vehicles[g].cell and 0xFF))
    sim.vehicleBytes.add(char(ord(sim.vehicles[g].state)))

# ---------------------------------------------------------------------------
# Step 1: the turn clock. Called by the runner at every tick that is a
# multiple of turnTicks, BEFORE the tick is stepped.
# ---------------------------------------------------------------------------

proc installPlans*(sim: var Sim, plans: array[Seats, RoutingPlan]) =
  sim.turn = sim.tick div sim.config.turnTicks
  sim.plans = plans
  ## Tie noise, drawn per fleet per lane once per turn, in fleet then lane
  ## order, so four fleets with identical plans do not stack onto one
  ## identical route and the draw sequence stays a function of the seed and
  ## the plan stream alone.
  for seat in 0 ..< Seats:
    for lane in 0 ..< LaneCount:
      sim.noise[seat * LaneCount + lane] = sim.rng.rand(4)
  for seat in 0 ..< Seats:
    sim.deliveredLastTurn[seat] =
      sim.delivered[seat] - sim.deliveredAtTurnStart[seat]
    sim.deliveredAtTurnStart[seat] = sim.delivered[seat]
    if plans[seat].source == psLlm:
      inc sim.turnsLlm[seat]
  resetTurnWindow(sim)
  for g in 0 ..< sim.vehicles.len:
    if sim.vehicles[g].lane >= 0:
      enqueueReplan(sim, g)

  var delivered = newJArray()
  var onRoad = newJArray()
  var backlog = newJArray()
  for seat in 0 ..< Seats:
    delivered.add(%sim.delivered[seat])
    onRoad.add(%onRoadCount(sim, seat))
    backlog.add(%sim.backlog[seat].len)
  sim.events.add(newEvent(seTurnStart, sim.tick, sim.turn, %*{
    "delivered": delivered,
    "on_road": onRoad,
    "backlog": backlog,
    "jam_index": sim.jamIndex}))
  for seat in 0 ..< Seats:
    sim.planLog.add(PlanRecord(turn: sim.turn, seat: seat, plan: plans[seat]))
  for seat in 0 ..< Seats:
    var body = planJson(plans[seat])
    body["seat"] = %seat
    body["fleet"] = %FleetAliases[sim.seatDepot[seat]]
    body["source"] = %($plans[seat].source)
    body["latency_ms"] = %plans[seat].latencyMs
    sim.events.add(newEvent(sePlan, sim.tick, sim.turn, body))
  for seat in 0 ..< Seats:
    var held = 0
    for g in seat * sim.config.fleetSize ..<
        (seat + 1) * sim.config.fleetSize:
      if sim.vehicles[g].lane < 0 and sim.vehicles[g].waiting:
        inc held
    sim.events.add(newEvent(seMeter, sim.tick, sim.turn, %*{
      "fleet": FleetAliases[sim.seatDepot[seat]],
      "dispatch": plans[seat].dispatch,
      "held": held}))
  ## The snapshot is taken AFTER the plans are installed, so it captures
  ## exactly the state the keyframe at this tick will digest — a backward seek
  ## must not re-draw the turn's tie noise or re-emit its events.
  if sim.keepSnapshots:
    sim.snapshots.add(takeSnapshot(sim))

# ---------------------------------------------------------------------------
# Steps 3 to 10.
# ---------------------------------------------------------------------------

proc issueOrders*(sim: var Sim) =
  if sim.destCursor >= sim.destSchedule.len:
    return
  let canonical = sim.destSchedule[sim.destCursor]
  inc sim.destCursor
  for seat in 0 ..< Seats:
    if sim.backlog[seat].len >= sim.config.backlogMax:
      continue
    let depot = sim.seatDepot[seat]
    sim.backlog[seat].add(Parcel(
      id: sim.nextParcelId,
      fleet: seat,
      dest: destinationFor(canonical, depot),
      createdTick: sim.tick))
    inc sim.nextParcelId
    inc sim.ordersCreated[seat]

proc loadingStep*(sim: var Sim) =
  for g in 0 ..< sim.vehicles.len:
    if sim.vehicles[g].lane >= 0:
      continue
    if sim.vehicles[g].loadTicksLeft > 0:
      dec sim.vehicles[g].loadTicksLeft
      if sim.vehicles[g].loadTicksLeft == 0:
        sim.vehicles[g].hasParcel = true
        sim.vehicles[g].waiting = true
        assignRoute(sim, g, sim.vehicles[g].dest)
      continue
    if sim.vehicles[g].hasParcel:
      continue
    let seat = sim.vehicles[g].fleet
    if sim.backlog[seat].len == 0:
      continue
    let index = pickBacklogIndex(sim.backlog[seat],
      depotNode(sim.seatDepot[seat]), sim.plans[seat].priority)
    let parcel = takeBacklog(sim.backlog[seat], index)
    sim.vehicles[g].parcelId = parcel.id
    sim.vehicles[g].dest = parcel.dest
    sim.vehicles[g].loadTicksLeft = max(1, sim.config.loadTicks)

proc dispatchStep*(sim: var Sim) =
  ## The ONLY place a fleet can hold itself back, and the commons lever.
  for seat in 0 ..< Seats:
    let cap = activeCap(sim.plans[seat], sim.config.fleetSize)
    let perStep = releasePerStep(sim.plans[seat])
    var onRoad = onRoadCount(sim, seat)
    var released = 0
    for g in seat * sim.config.fleetSize ..<
        (seat + 1) * sim.config.fleetSize:
      if onRoad >= cap or released >= perStep:
        break
      if sim.vehicles[g].lane >= 0 or not sim.vehicles[g].waiting:
        continue
      if sim.vehicles[g].route.len == 0:
        continue
      let first = sim.vehicles[g].route[0]
      if cellAt(sim, first, 0) >= 0:
        continue
      placeVehicle(sim, g, first, 0)
      sim.vehicles[g].state = vsLoaded
      sim.vehicles[g].waiting = false
      sim.vehicles[g].releaseTick = sim.tick
      inc onRoad
      inc released

proc crossVehicle*(sim: var Sim, g, node: int): bool =
  let seat = sim.vehicles[g].fleet
  let home = depotNode(sim.seatDepot[seat])

  if sim.vehicles[g].hasParcel and node == sim.vehicles[g].dest:
    ## Delivery. The van needs somewhere to go next; a blocked onward cell
    ## leaves it at the stop line — a delivery bay that blocks the road,
    ## deliberately.
    let route = routeFrom(sim, seat, node, home)
    if route.len == 0:
      return false
    if cellAt(sim, route[0], 0) >= 0:
      return false
    inc sim.delivered[seat]
    let trip = sim.tick - sim.vehicles[g].releaseTick
    sim.tripTicks[seat] += trip
    inc sim.tripCount[seat]
    sim.events.add(newEvent(seDeliver, sim.tick, sim.turn, %*{
      "f": seat,
      "n": sim.delivered[seat],
      "d": [nodeX(node), nodeY(node)],
      "trip": trip}))
    sim.vehicles[g].hasParcel = false
    sim.vehicles[g].parcelId = -1
    sim.vehicles[g].dest = -1
    sim.vehicles[g].target = home
    liftVehicle(sim, g)
    placeVehicle(sim, g, route[0], 0)
    sim.vehicles[g].route = route
    sim.vehicles[g].state = vsEmpty
    enqueueReplan(sim, g)
    return true

  if (not sim.vehicles[g].hasParcel) and node == home:
    ## Absorbed into the dock, which never blocks (fleetSize slots).
    liftVehicle(sim, g)
    sim.vehicles[g].state = vsDocked
    sim.vehicles[g].waiting = false
    sim.vehicles[g].route = @[]
    sim.vehicles[g].target = home
    return true

  ## A van crossing any OTHER fleet's depot node does nothing special.
  let nxt = nextLaneOf(sim, g)
  if nxt < 0:
    sim.vehicles[g].target = if sim.vehicles[g].hasParcel: sim.vehicles[g].dest
      else: home
    enqueueReplan(sim, g)
    return false
  if cellAt(sim, nxt, 0) >= 0:
    return false
  liftVehicle(sim, g)
  placeVehicle(sim, g, nxt, 0)
  if sim.vehicles[g].route.len >= 2 and sim.vehicles[g].route[1] == nxt:
    sim.vehicles[g].route.delete(0)
  else:
    sim.vehicles[g].route = @[nxt]
    enqueueReplan(sim, g)
  if sim.vehicles[g].route.len >= 2 and
      sim.q[sim.vehicles[g].route[1]] >= replanQueue(sim.plans[seat]):
    enqueueReplan(sim, g)
  true

proc serviceStep*(sim: var Sim) =
  let cells = sim.config.laneCells
  let sl = cells - 1
  for n in 0 ..< NodeCount:
    for slot in 0 ..< 4:
      let lane = RoadGrid.approach[n][slot]
      if lane < 0:
        continue
      if not laneIsGreen(lane, sim.tick, sim.config.signalCycleTicks,
          sim.config.greenNsTicks):
        continue
      let capacity = dischargePerStep(lane)
      for k in 0 ..< capacity:
        var g = sim.cells[lane * cells + sl]
        if g < 0:
          if k == 0 or sl == 0:
            break
          let behind = sim.cells[lane * cells + sl - 1]
          if behind < 0:
            break
          sim.cells[lane * cells + sl] = behind
          sim.cells[lane * cells + sl - 1] = -1
          sim.vehicles[behind].cell = sl
          sim.vehicles[behind].lastMoveTick = sim.tick
          g = behind
        if not crossVehicle(sim, g, n):
          break

proc replanStep*(sim: var Sim) =
  var budget = sim.config.routeBudgetPerTick
  while budget > 0:
    let g = popReplan(sim)
    if g < 0:
      break
    dec budget
    if sim.vehicles[g].lane < 0:
      continue
    let seat = sim.vehicles[g].fleet
    let target =
      if sim.vehicles[g].hasParcel and sim.vehicles[g].dest >= 0:
        sim.vehicles[g].dest
      else: depotNode(sim.seatDepot[seat])
    assignRoute(sim, g, target)

proc stepTick*(sim: var Sim) =
  if sim.tick mod TargetFps == 0:
    recordKeyframe(sim)
  if sim.tick mod max(1, sim.config.orderPeriodTicks) == 0:
    issueOrders(sim)
  loadingStep(sim)
  if sim.tick mod max(1, sim.config.dispatchPeriodTicks) == 0:
    dispatchStep(sim)
  if sim.tick mod max(1, sim.config.moveTicks) == 0:
    moveStep(sim)
  if sim.tick mod max(1, sim.config.serviceTicks) == 0:
    serviceStep(sim)
  replanStep(sim)
  accumulateStats(sim)
  jamWatch(sim)
  if sim.tick mod TargetFps == 0:
    gridlockWatch(sim)
  if sim.tick mod 48 == 0:
    refreshHeat(sim)
  inc sim.tick

proc endEpisode*(sim: var Sim, reason, endRule: string, detail = "") =
  if sim.finished:
    return
  sim.finished = true
  sim.reason = reason
  sim.endRule = endRule
  sim.faultDetail = detail
  recordKeyframe(sim)
  var delivered = newJArray()
  var scores = newJArray()
  var raw: seq[int]
  let faulted = reason == "fault"
  for seat in 0 ..< Seats:
    let count = if faulted: 0 else: sim.delivered[seat]
    raw.add(count)
    delivered.add(%count)
    scores.add(%float(count))
  var total = 0
  for value in raw:
    total += value
  let winner = if faulted: -1 else: winnerOf(raw)
  let winnerNode = if winner < 0: newJNull() else: %winner
  sim.events.add(newEvent(seEnd, sim.tick, sim.turn, %*{
    "reason": reason,
    "end_rule": endRule,
    "delivered": delivered,
    "scores": scores,
    "winner": winnerNode,
    "total_delivered": total,
    "jam_index_mean":
      (if sim.jamIndexSamples > 0: sim.jamIndexSum div sim.jamIndexSamples
       else: 0)}))

proc runTurn*(sim: var Sim, plans: array[Seats, RoutingPlan]): string =
  ## Installs `plans` and steps one whole turn. Returns "" normally, or the
  ## invariant failure that tripped step 14's guard.
  installPlans(sim, plans)
  for _ in 0 ..< sim.config.turnTicks:
    if sim.tick >= sim.config.episodeTicks:
      break
    stepTick(sim)
    if sim.tick mod TargetFps == 0:
      let failure = invariantFailure(sim)
      if failure.len > 0:
        return failure
  ""

proc scriptedPlansFor*(sim: Sim, kinds: array[Seats, ScriptKind]):
    array[Seats, RoutingPlan] =
  for seat in 0 ..< Seats:
    result[seat] = scriptedPlan(baselineInput(sim, seat), kinds[seat])

proc runScriptedEpisode*(sim: var Sim, kinds: array[Seats, ScriptKind]) =
  ## The offline path: no network, no LLM, used by the certification fixture,
  ## the docker smoke and most of the tests.
  while sim.tick < sim.config.episodeTicks and not sim.finished:
    let failure = runTurn(sim, scriptedPlansFor(sim, kinds))
    if failure.len > 0:
      endEpisode(sim, "fault", "sim_fault", failure)
      return
  if not sim.finished:
    endEpisode(sim, "complete", "full_time")
