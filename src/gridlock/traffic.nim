## Cell occupancy, movement, and the pending-replan FIFO.
##
## The whole spillback rule is ONE invariant: a cell holds at most one
## vehicle, and a vehicle only ever moves into an empty cell. There is no
## separate "spillback" step — a full receiving lane freezes its feeding
## approach, which fills, which freezes the approaches feeding that.

import types
import graph

proc cellSlot*(sim: Sim, lane, cell: int): int {.inline.} =
  lane * sim.config.laneCells + cell

proc cellAt*(sim: Sim, lane, cell: int): int {.inline.} =
  sim.cells[lane * sim.config.laneCells + cell]

proc stopLine*(sim: Sim): int {.inline.} = sim.config.laneCells - 1

proc laneIsFull*(sim: Sim, lane: int): bool {.inline.} =
  sim.q[lane] >= sim.config.laneCells

proc placeVehicle*(sim: var Sim, g, lane, cell: int) =
  ## Caller has already checked the cell is empty.
  sim.cells[cellSlot(sim, lane, cell)] = g
  inc sim.q[lane]
  sim.vehicles[g].lane = lane
  sim.vehicles[g].cell = cell
  sim.vehicles[g].lastMoveTick = sim.tick

proc liftVehicle*(sim: var Sim, g: int) =
  ## Takes a vehicle off the road without placing it anywhere.
  let lane = sim.vehicles[g].lane
  if lane >= 0:
    sim.cells[cellSlot(sim, lane, sim.vehicles[g].cell)] = -1
    dec sim.q[lane]
  sim.vehicles[g].lane = DockedLane
  sim.vehicles[g].cell = 0

proc enqueueReplan*(sim: var Sim, g: int) =
  if sim.vehicles[g].queued:
    return
  sim.vehicles[g].queued = true
  sim.replanQueue.add(g)

proc popReplan*(sim: var Sim): int =
  ## -1 when the FIFO is empty. Compacts so a 4800-tick episode does not grow
  ## the backing seq without bound.
  if sim.replanHead >= sim.replanQueue.len:
    if sim.replanQueue.len > 0:
      sim.replanQueue.setLen(0)
      sim.replanHead = 0
    return -1
  result = sim.replanQueue[sim.replanHead]
  inc sim.replanHead
  sim.vehicles[result].queued = false
  if sim.replanHead > 4096:
    var rest = newSeqOfCap[int](sim.replanQueue.len - sim.replanHead)
    for i in sim.replanHead ..< sim.replanQueue.len:
      rest.add(sim.replanQueue[i])
    sim.replanQueue = rest
    sim.replanHead = 0

proc moveStep*(sim: var Sim) =
  ## Step 6. Downstream-first (stop line back to cell 0) so a queue
  ## discharges as a wave rather than teleporting; the order is fixed and the
  ## tests pin it.
  let cells = sim.config.laneCells
  for lane in 0 ..< LaneCount:
    if sim.q[lane] == 0:
      continue
    let base = lane * cells
    for c in countdown(cells - 2, 0):
      let g = sim.cells[base + c]
      if g < 0:
        continue
      if sim.cells[base + c + 1] >= 0:
        continue
      sim.cells[base + c + 1] = g
      sim.cells[base + c] = -1
      sim.vehicles[g].cell = c + 1
      sim.vehicles[g].lastMoveTick = sim.tick

proc onRoadCount*(sim: Sim, seat: int): int =
  for g in seat * sim.config.fleetSize ..<
      (seat + 1) * sim.config.fleetSize:
    if sim.vehicles[g].lane >= 0:
      inc result

proc noiseBase*(sim: Sim, seat: int): int {.inline.} = seat * LaneCount

proc routeFrom*(sim: Sim, seat, fromNode, toNode: int): seq[int] =
  shortestPath(fromNode, toNode, sim.plans[seat], sim.q, sim.noise,
    noiseBase(sim, seat))

proc assignRoute*(sim: var Sim, g, toNode: int) =
  ## Recomputes a van's route. An on-road van keeps the lane it occupies as
  ## route[0]; a docked van's route starts at the depot node.
  let seat = sim.vehicles[g].fleet
  sim.vehicles[g].target = toNode
  if sim.vehicles[g].lane >= 0:
    let here = laneOf(sim.vehicles[g].lane).head
    var path = routeFrom(sim, seat, here, toNode)
    var route = @[sim.vehicles[g].lane]
    for id in path:
      route.add(id)
    sim.vehicles[g].route = route
  else:
    sim.vehicles[g].route =
      routeFrom(sim, seat, depotNode(sim.seatDepot[seat]), toNode)

proc nextLaneOf*(sim: Sim, g: int): int =
  ## The lane a van at the stop line wants to enter, or -1 when it has
  ## arrived. A stale route (one whose next lane does not start here) is
  ## replaced by the cheapest legal outgoing lane, ties by lane id.
  let lane = sim.vehicles[g].lane
  if lane < 0:
    return -1
  let seat = sim.vehicles[g].fleet
  let here = laneOf(lane).head
  if sim.vehicles[g].route.len >= 2:
    let candidate = sim.vehicles[g].route[1]
    if laneOf(candidate).tail == here:
      return candidate
  if here == sim.vehicles[g].target:
    return -1
  cheapestOutgoing(here, sim.plans[seat], sim.q, sim.noise,
    noiseBase(sim, seat))
