## Sim unit tests on the network: nodes, lanes, arterials, districts, depots
## and the Dijkstra router.

import std/[sets, unittest]
import support/helpers

suite "graph":
  test "the 9x9 grid yields exactly 144 segments and 288 lanes":
    check LaneCount == 288
    check SegmentCount == 144
    var pairs = initHashSet[(int, int)]()
    for id in 0 ..< LaneCount:
      let lane = laneOf(id)
      check lane.tail != lane.head
      check manhattan(lane.tail, lane.head) == 1
      check not pairs.contains((lane.tail, lane.head))
      pairs.incl((lane.tail, lane.head))
    check pairs.len == LaneCount
    ## Every lane has an opposite.
    for id in 0 ..< LaneCount:
      let lane = laneOf(id)
      check pairs.contains((lane.head, lane.tail))

  test "lane ids are stable and follow the documented order":
    ## Horizontal segments first, row-major, east then west.
    check laneOf(0).tail == nodeIndex(0, 0)
    check laneOf(0).head == nodeIndex(1, 0)
    check laneOf(0).dir == ldEast
    check laneOf(1).tail == nodeIndex(1, 0)
    check laneOf(1).head == nodeIndex(0, 0)
    check laneOf(1).dir == ldWest
    ## Then vertical segments, column-major, south then north.
    check laneOf(144).tail == nodeIndex(0, 0)
    check laneOf(144).head == nodeIndex(0, 1)
    check laneOf(144).dir == ldSouth
    check laneOf(145).dir == ldNorth
    for id in 0 ..< 144:
      check not laneOf(id).axisNs
    for id in 144 ..< LaneCount:
      check laneOf(id).axisNs

  test "arterial classification is invariant under both mirrors and the rotation":
    for id in 0 ..< LaneCount:
      let lane = laneOf(id)
      let ax = nodeX(lane.tail)
      let ay = nodeY(lane.tail)
      let bx = nodeX(lane.head)
      let by = nodeY(lane.head)
      ## mirror x
      let mx = laneBetween(nodeIndex(8 - ax, ay), nodeIndex(8 - bx, by))
      check mx >= 0
      check laneOf(mx).arterial == lane.arterial
      ## mirror y
      let my = laneBetween(nodeIndex(ax, 8 - ay), nodeIndex(bx, 8 - by))
      check my >= 0
      check laneOf(my).arterial == lane.arterial
      ## 90 degree rotation (ix, iy) -> (8 - iy, ix)
      let rot = laneBetween(nodeIndex(8 - ay, ax), nodeIndex(8 - by, bx))
      check rot >= 0
      check laneOf(rot).arterial == lane.arterial

  test "lane geometry lands on the documented pixels":
    let cells = LaneCellsDefault
    check NodeSpacingPx == cells * CellPxDefault
    check MarginPx * 2 + NodeSpacingPx * (GridCols - 1) == MapWidth
    let first = laneCellPixel(0, 0, cells, CellPxDefault, LaneOffsetPx)
    check first.x == MarginPx + CellPxDefault div 2
    check first.y == MarginPx + LaneOffsetPx
    let last = laneCellPixel(0, cells - 1, cells, CellPxDefault, LaneOffsetPx)
    check last.x == MarginPx + NodeSpacingPx - CellPxDefault div 2

  test "district membership matches [3bx, 3bx+2] x [3by, 3by+2]":
    for n in 0 ..< NodeCount:
      let d = districtOfNode(n)
      let bx = districtX(d)
      let by = districtY(d)
      check nodeX(n) >= 3 * bx and nodeX(n) <= 3 * bx + 2
      check nodeY(n) >= 3 * by and nodeY(n) <= 3 * by + 2
    check districtName(districtIndex(1, 1)) == "CENTRE"
    check districtName(districtIndex(0, 0)) == "NW"
    check districtName(districtIndex(2, 2)) == "SE"

  test "the four depots are the mirror orbit of (1,1)":
    var nodes: HashSet[int]
    for depot in 0 ..< Seats:
      nodes.incl(depotNode(depot))
    check nodes.len == Seats
    for depot in 0 ..< Seats:
      check mirrorNode(depotNode(0), depot) == depotNode(depot)
    ## And the set is closed under both mirrors.
    for depot in 0 ..< Seats:
      check nodes.contains(mirrorNode(depotNode(depot), 1))
      check nodes.contains(mirrorNode(depotNode(depot), 2))
      check nodes.contains(mirrorNode(depotNode(depot), 3))

  test "signal phase matches ((t + offset) mod 96) < 48 at every node":
    for n in 0 ..< NodeCount:
      check signalOffsetTicks(n) == ((nodeX(n) + nodeY(n)) mod 4) * 24
    for t in 0 ..< 400:
      for n in 0 ..< NodeCount:
        let expected = ((t + signalOffsetTicks(n)) mod 96) < 48
        check phaseIsNs(n, t, 96, 48) == expected

  test "discharge is two on an arterial approach and one on a local one":
    for id in 0 ..< LaneCount:
      check dischargePerStep(id) == (if laneOf(id).arterial: 2 else: 1)

suite "router":
  setup:
    var occupancy = newSeq[int](LaneCount)
    var noise = newSeq[int](Seats * LaneCount)
    var plan = defaultPlan()
    plan.congestionWeight = 0

  test "every lane cost is strictly positive and bounded for every legal plan":
    for cw in [0, 25, 50, 100]:
      for corridor in [-1, 4]:
        for avoid in [-1, 0]:
          var probe = defaultPlan()
          probe.congestionWeight = cw
          probe.corridor = corridor
          probe.avoid = (if avoid == corridor: -1 else: avoid)
          for q in [0, 7, 14]:
            for id in 0 ..< LaneCount:
              let cost = laneCost(id, probe, q, 3)
              check cost > 0
              check cost <= 1200

  test "Dijkstra returns the cheapest path and never repeats a lane":
    let path = shortestPath(nodeIndex(0, 0), nodeIndex(8, 8), plan,
      occupancy, noise, 0)
    check path.len == 16          ## the Manhattan distance on a free grid
    var seen: HashSet[int]
    var cursor = nodeIndex(0, 0)
    for id in path:
      check laneOf(id).tail == cursor
      check not seen.contains(id)
      seen.incl(id)
      cursor = laneOf(id).head
    check cursor == nodeIndex(8, 8)

  test "the grid is strongly connected: some path always exists":
    for target in [nodeIndex(8, 0), nodeIndex(0, 8), nodeIndex(4, 4),
        nodeIndex(7, 1)]:
      let path = shortestPath(nodeIndex(1, 1), target, plan, occupancy,
        noise, 0)
      check path.len > 0
      check laneOf(path[^1]).head == target
    check shortestPath(5, 5, plan, occupancy, noise, 0).len == 0

  test "ties break by ascending lane id":
    ## Two symmetric one-step-then-one-step routes to a diagonal neighbour.
    let path = shortestPath(nodeIndex(3, 3), nodeIndex(4, 4), plan,
      occupancy, noise, 0)
    check path.len == 2
    let alternative = @[
      laneBetween(nodeIndex(3, 3), nodeIndex(4, 3)),
      laneBetween(nodeIndex(4, 3), nodeIndex(4, 4))]
    let other = @[
      laneBetween(nodeIndex(3, 3), nodeIndex(3, 4)),
      laneBetween(nodeIndex(3, 4), nodeIndex(4, 4))]
    check path == alternative or path == other

  test "a jammed lane is repriced out of the plan":
    let free = shortestPath(nodeIndex(0, 4), nodeIndex(2, 4), plan,
      occupancy, noise, 0)
    check free.len == 2
    var jammed = occupancy
    for id in free:
      jammed[id] = LaneCellsDefault
    var pricing = defaultPlan()
    pricing.congestionWeight = 100
    let detour = shortestPath(nodeIndex(0, 4), nodeIndex(2, 4), pricing,
      jammed, noise, 0)
    check detour != free
    check pathCost(detour, pricing, jammed, noise, 0) <
      pathCost(free, pricing, jammed, noise, 0)

  test "avoid raises and corridor lowers the chosen path's cost":
    var avoiding = defaultPlan()
    avoiding.congestionWeight = 0
    avoiding.avoid = districtIndex(1, 1)
    let through = shortestPath(nodeIndex(0, 4), nodeIndex(8, 4), plan,
      occupancy, noise, 0)
    let around = shortestPath(nodeIndex(0, 4), nodeIndex(8, 4), avoiding,
      occupancy, noise, 0)
    var centreLanes = 0
    for id in around:
      if districtOfNode(laneOf(id).head) == districtIndex(1, 1):
        inc centreLanes
    var straightCentre = 0
    for id in through:
      if districtOfNode(laneOf(id).head) == districtIndex(1, 1):
        inc straightCentre
    check centreLanes < straightCentre

    var preferring = defaultPlan()
    preferring.congestionWeight = 0
    preferring.corridor = districtIndex(0, 0)
    let plain = shortestPath(nodeIndex(0, 0), nodeIndex(2, 2), plan,
      occupancy, noise, 0)
    let favoured = shortestPath(nodeIndex(0, 0), nodeIndex(2, 2), preferring,
      occupancy, noise, 0)
    check pathCost(favoured, preferring, occupancy, noise, 0) <
      pathCost(plain, plan, occupancy, noise, 0)

  test "cheapestOutgoing always finds a legal lane":
    for n in 0 ..< NodeCount:
      let id = cheapestOutgoing(n, plan, occupancy, noise, 0)
      check id >= 0
      check laneOf(id).tail == n
