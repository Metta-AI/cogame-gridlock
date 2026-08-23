## Demand and delivery: the canonical schedule, per-fleet mirroring, backlog
## caps, priority selection, loading, and what a crossing does at each node.

import std/[tables, unittest]
import support/helpers

suite "demand":
  test "one order per fleet per orderPeriodTicks, none beyond the cap":
    var game = newTestSim(960)
    for _ in 0 ..< 240:
      stepTick(game)
    for seat in 0 ..< Seats:
      check game.ordersCreated[seat] == 240 div game.config.orderPeriodTicks
      check game.backlog[seat].len <= game.config.backlogMax

  test "the backlog cap holds even when nothing ever leaves":
    var game = newTestSim(4800)
    ## Freeze dispatch so the backlog can only grow.
    var plans: array[Seats, RoutingPlan]
    for seat in 0 ..< Seats:
      plans[seat] = defaultPlan()
      plans[seat].dispatch = 0
    installPlans(game, plans)
    for _ in 0 ..< 4000:
      if game.tick >= game.config.episodeTicks: break
      stepTick(game)
    for seat in 0 ..< Seats:
      check game.backlog[seat].len <= game.config.backlogMax

  test "fleet j's destination is exactly mirror_j of the canonical one":
    ## Orders only: no loading step, so backlog[seat][k] IS the k-th order.
    var game = newTestSim(960)
    for _ in 0 ..< 20:
      issueOrders(game)
    for seat in 0 ..< Seats:
      check game.backlog[seat].len == 20
    for k in 0 ..< 20:
      let canonical = game.destSchedule[k]
      for seat in 0 ..< Seats:
        check game.backlog[seat][k].dest ==
          mirrorNode(canonical, game.seatDepot[seat])
    ## Congruence: the distance from each fleet's own depot to its own k-th
    ## destination is identical across the four fleets.
    for k in 0 ..< 20:
      var distances: seq[int]
      for seat in 0 ..< Seats:
        distances.add(manhattan(depotNode(game.seatDepot[seat]),
          game.backlog[seat][k].dest))
      for d in distances:
        check d == distances[0]

  test "destinations are never a depot node":
    var rng = initPcg32(99)
    let schedule = buildDestinationSchedule(rng, 500)
    check schedule.len == 500
    for node in schedule:
      check not isDepotNode(node)
      for depot in 0 ..< Seats:
        check not isDepotNode(mirrorNode(node, depot))

suite "priority":
  setup:
    let home = depotNode(0)
    var backlog: seq[Parcel]
    backlog.add(Parcel(id: 1, fleet: 0, dest: nodeIndex(8, 8),
      createdTick: 0))
    backlog.add(Parcel(id: 2, fleet: 0, dest: nodeIndex(2, 1),
      createdTick: 1))
    backlog.add(Parcel(id: 3, fleet: 0, dest: nodeIndex(8, 0),
      createdTick: 2))

  test "fifo takes the oldest":
    check pickBacklogIndex(backlog, home, prFifo) == 0

  test "near takes the smallest Manhattan distance from the depot":
    check pickBacklogIndex(backlog, home, prNear) == 1

  test "far takes the largest":
    check pickBacklogIndex(backlog, home, prFar) == 0

  test "ties go to the oldest":
    var tied: seq[Parcel]
    tied.add(Parcel(id: 10, fleet: 0, dest: nodeIndex(3, 1), createdTick: 0))
    tied.add(Parcel(id: 11, fleet: 0, dest: nodeIndex(1, 3), createdTick: 1))
    check manhattan(home, tied[0].dest) == manhattan(home, tied[1].dest)
    check pickBacklogIndex(tied, home, prNear) == 0
    check pickBacklogIndex(tied, home, prFar) == 0

  test "an empty backlog selects nothing":
    var empty: seq[Parcel]
    check pickBacklogIndex(empty, home, prFifo) == -1

suite "loading and delivery":
  test "loading takes exactly loadTicks and then the van has a route":
    var game = newTestSim(960)
    issueOrders(game)
    check game.backlog[0].len == 1
    ## The first call BEGINS loading; the van is ready loadTicks ticks later.
    loadingStep(game)
    check game.vehicles[0].loadTicksLeft == game.config.loadTicks
    for _ in 0 ..< game.config.loadTicks - 1:
      loadingStep(game)
      check not game.vehicles[0].hasParcel
    loadingStep(game)
    check game.vehicles[0].hasParcel
    check game.vehicles[0].waiting
    check game.vehicles[0].route.len > 0
    check laneOf(game.vehicles[0].route[0]).tail ==
      depotNode(game.seatDepot[0])

  test "a delivery increments exactly one counter, for the owning fleet":
    var game = newTestSim(960)
    let seat = 0
    let dest = nodeIndex(4, 4)
    let approach = laneBetween(nodeIndex(3, 4), dest)
    let cells = game.config.laneCells
    game.putVan(0, approach, cells - 1, loaded = true)
    game.vehicles[0].dest = dest
    game.vehicles[0].target = dest
    game.vehicles[0].parcelId = 77
    game.vehicles[0].releaseTick = 0
    game.tick = 24
    check crossVehicle(game, 0, dest)
    check game.delivered[seat] == 1
    for other in 1 ..< Seats:
      check game.delivered[other] == 0
    check not game.vehicles[0].hasParcel
    check game.vehicles[0].target == depotNode(game.seatDepot[seat])
    check game.tripCount[seat] == 1

  test "a van crossing a node that is not its destination does not deliver":
    var game = newTestSim(960)
    let dest = nodeIndex(8, 8)
    let node = nodeIndex(4, 4)
    let approach = laneBetween(nodeIndex(3, 4), node)
    let cells = game.config.laneCells
    game.putVan(0, approach, cells - 1, loaded = true)
    game.vehicles[0].dest = dest
    game.vehicles[0].target = dest
    game.vehicles[0].route = @[approach,
      laneBetween(node, nodeIndex(5, 4))]
    check crossVehicle(game, 0, node)
    check game.delivered[0] == 0
    check game.vehicles[0].hasParcel

  test "crossing a rival depot node does nothing special":
    var game = newTestSim(960)
    let seat = 0
    var rivalDepot = -1
    for depot in 0 ..< Seats:
      if depot != game.seatDepot[seat]:
        rivalDepot = depotNode(depot)
        break
    let approach = laneBetween(
      nodeIndex(nodeX(rivalDepot) - 1, nodeY(rivalDepot)), rivalDepot)
    let cells = game.config.laneCells
    game.putVan(0, approach, cells - 1)
    game.vehicles[0].target = nodeIndex(4, 4)
    game.vehicles[0].route = @[approach]
    discard crossVehicle(game, 0, rivalDepot)
    ## It did not dock: the van is still on the road.
    check game.vehicles[0].state != vsDocked

  test "a delivery whose onward cell is occupied leaves the van at the stop line":
    var game = newTestSim(960)
    let dest = nodeIndex(4, 4)
    let approach = laneBetween(nodeIndex(3, 4), dest)
    let cells = game.config.laneCells
    ## Fill cell 0 of every lane out of the destination node, so the returning
    ## van has nowhere to go.
    var g = 10
    for id in 0 ..< LaneCount:
      if laneOf(id).tail == dest:
        game.putVan(g, id, 0)
        inc g
    game.putVan(0, approach, cells - 1, loaded = true)
    game.vehicles[0].dest = dest
    game.vehicles[0].target = dest
    check not crossVehicle(game, 0, dest)
    check game.delivered[0] == 0
    check game.vehicles[0].lane == approach
    check game.vehicles[0].cell == cells - 1
    ## And it is not double counted on the next attempt either.
    check not crossVehicle(game, 0, dest)
    check game.delivered[0] == 0

  test "an empty van crossing into its own depot docks and never blocks":
    var game = newTestSim(960)
    let home = depotNode(game.seatDepot[0])
    let approach = laneBetween(nodeIndex(nodeX(home) - 1, nodeY(home)), home)
    let cells = game.config.laneCells
    for i in 0 ..< 5:
      game.putVan(i, approach, cells - 1 - i)
      game.vehicles[i].target = home
    for i in 0 ..< 5:
      check crossVehicle(game, i, home)
      check game.vehicles[i].state == vsDocked
      check game.vehicles[i].lane == DockedLane

  test "parcel ids are unique across a whole episode":
    var game = newTestSim(episodeTicks(2400), 7)
    runScripted(game, allKinds(skDispatcher))
    var seen = initTable[int, bool]()
    for seat in 0 ..< Seats:
      for parcel in game.backlog[seat]:
        check not seen.hasKey(parcel.id)
        seen[parcel.id] = true
