## The road network: nodes, directed lanes, districts, arterial
## classification, the signal plan, and the Dijkstra router.
##
## Lane numbering is fixed and load-bearing (it is the tie-break rule and it
## is what the replay's `vehicles_b64` encodes):
##   0   .. 143  horizontal segments, row-major, east lane then west lane
##   144 .. 287  vertical segments, column-major, south lane then north lane

import std/[heapqueue]
import types

type
  LaneDir* = enum
    ldEast, ldWest, ldSouth, ldNorth

  Lane* = object
    tail*: int              ## node the lane leaves
    head*: int              ## node the lane feeds (the stop line is here)
    dir*: LaneDir
    arterial*: bool
    axisNs*: bool           ## true when travel is north-south

  Grid* = object
    lanes*: array[LaneCount, Lane]
    outgoing*: array[NodeCount, seq[int]]
    incoming*: array[NodeCount, seq[int]]
    approach*: array[NodeCount, array[4, int]]
      ## service order N, E, S, W; -1 where the node has no such approach

proc buildGrid*(): Grid =
  var g: Grid
  # Horizontal segments: 8 per row x 9 rows = 72 segments, 144 lanes.
  for iy in 0 ..< GridRows:
    for ix in 0 ..< GridCols - 1:
      let seg = iy * (GridCols - 1) + ix
      let a = nodeIndex(ix, iy)
      let b = nodeIndex(ix + 1, iy)
      let art = isArterialRow(iy)
      g.lanes[2 * seg] = Lane(tail: a, head: b, dir: ldEast,
        arterial: art, axisNs: false)
      g.lanes[2 * seg + 1] = Lane(tail: b, head: a, dir: ldWest,
        arterial: art, axisNs: false)
  # Vertical segments: 8 per column x 9 columns = 72 segments, 144 lanes.
  const vBase = 2 * (GridRows * (GridCols - 1))
  for ix in 0 ..< GridCols:
    for iy in 0 ..< GridRows - 1:
      let seg = ix * (GridRows - 1) + iy
      let a = nodeIndex(ix, iy)
      let b = nodeIndex(ix, iy + 1)
      let art = isArterialCol(ix)
      g.lanes[vBase + 2 * seg] = Lane(tail: a, head: b, dir: ldSouth,
        arterial: art, axisNs: true)
      g.lanes[vBase + 2 * seg + 1] = Lane(tail: b, head: a, dir: ldNorth,
        arterial: art, axisNs: true)
  for n in 0 ..< NodeCount:
    for k in 0 ..< 4:
      g.approach[n][k] = -1
  for id in 0 ..< LaneCount:
    let lane = g.lanes[id]
    g.outgoing[lane.tail].add(id)
    g.incoming[lane.head].add(id)
    # Service order N, E, S, W. A lane travelling SOUTH enters its head from
    # the north, so it is the N approach; travelling WEST it is the E
    # approach; NORTH the S approach; EAST the W approach.
    let slot =
      case lane.dir
      of ldSouth: 0
      of ldWest: 1
      of ldNorth: 2
      of ldEast: 3
    g.approach[lane.head][slot] = id
  g

let RoadGrid* = buildGrid()

proc laneOf*(id: int): Lane {.inline.} = RoadGrid.lanes[id]

proc laneBetween*(a, b: int): int =
  ## The directed lane from node `a` to node `b`, or -1.
  for id in RoadGrid.outgoing[a]:
    if RoadGrid.lanes[id].head == b:
      return id
  -1

proc laneCellPixel*(id, cell, laneCells, cellPx, offsetPx: int):
    tuple[x, y: int] =
  ## Centre pixel of `cell` in `id`, offset to the right of travel so the two
  ## directions read as separate lanes.
  let lane = RoadGrid.lanes[id]
  let ax = nodePixelX(lane.tail)
  let ay = nodePixelY(lane.tail)
  let span = (cell * 2 + 1) * cellPx div 2
  case lane.dir
  of ldEast: (ax + span, ay + offsetPx)
  of ldWest: (ax - span, ay - offsetPx)
  of ldSouth: (ax - offsetPx, ay + span)
  of ldNorth: (ax + offsetPx, ay - span)

# ---------------------------------------------------------------------------
# Signals. Fixed-time, two-phase, identical at every intersection, controlled
# by nobody. Pure function of the tick and the node offset.
# ---------------------------------------------------------------------------

proc signalOffsetTicks*(n: int): int {.inline.} =
  ((nodeX(n) + nodeY(n)) mod 4) * 24

proc phaseIsNs*(n, t, cycleTicks, greenNsTicks: int): bool {.inline.} =
  ((t + signalOffsetTicks(n)) mod cycleTicks) < greenNsTicks

proc laneIsGreen*(id, t, cycleTicks, greenNsTicks: int): bool {.inline.} =
  RoadGrid.lanes[id].axisNs ==
    phaseIsNs(RoadGrid.lanes[id].head, t, cycleTicks, greenNsTicks)

proc dischargePerStep*(id: int): int {.inline.} =
  if RoadGrid.lanes[id].arterial: 2 else: 1

# ---------------------------------------------------------------------------
# Cost model and Dijkstra. Integer arithmetic only, all costs strictly
# positive, ties broken by ascending lane id.
# ---------------------------------------------------------------------------

proc laneCost*(id: int, plan: RoutingPlan, occupancy: int,
    noise: int): int =
  let lane = RoadGrid.lanes[id]
  let base = if lane.arterial: 48 else: 64
  let jam = (plan.congestionWeight * occupancy * 24) div 100
  let avoid =
    if plan.avoid >= 0 and districtOfNode(lane.head) == plan.avoid: 240
    else: 0
  let factor =
    if plan.corridor >= 0 and districtOfNode(lane.tail) == plan.corridor and
        districtOfNode(lane.head) == plan.corridor: 60
    else: 100
  result = ((base + jam + avoid) * factor) div 100 + noise
  if result < 1:
    result = 1

proc shortestPath*(fromNode, toNode: int, plan: RoutingPlan,
    occupancy: openArray[int], noise: openArray[int],
    noiseBase: int): seq[int] =
  ## Cheapest lane path under `plan`, ties by ascending lane id. The grid is
  ## strongly connected, so this always returns a path (empty only when
  ## `fromNode == toNode`).
  if fromNode == toNode:
    return @[]
  var dist = newSeq[int](NodeCount)
  var via = newSeq[int](NodeCount)
  var settled = newSeq[bool](NodeCount)
  for i in 0 ..< NodeCount:
    dist[i] = high(int) div 4
    via[i] = -1
  dist[fromNode] = 0
  var heap = initHeapQueue[(int, int, int)]()
  heap.push((0, -1, fromNode))
  while heap.len > 0:
    let (d, _, node) = heap.pop()
    if settled[node]:
      continue
    settled[node] = true
    if node == toNode:
      break
    for id in RoadGrid.outgoing[node]:
      let nxt = RoadGrid.lanes[id].head
      if settled[nxt]:
        continue
      let cost = laneCost(id, plan, occupancy[id], noise[noiseBase + id])
      let cand = d + cost
      if cand < dist[nxt] or (cand == dist[nxt] and
          (via[nxt] < 0 or id < via[nxt])):
        dist[nxt] = cand
        via[nxt] = id
        heap.push((cand, id, nxt))
  if via[toNode] < 0:
    return @[]
  var back: seq[int]
  var cursor = toNode
  while cursor != fromNode:
    let id = via[cursor]
    if id < 0:
      return @[]
    back.add(id)
    cursor = RoadGrid.lanes[id].tail
  result = newSeqOfCap[int](back.len)
  for i in countdown(back.high, 0):
    result.add(back[i])

proc cheapestOutgoing*(node: int, plan: RoutingPlan,
    occupancy: openArray[int], noise: openArray[int],
    noiseBase: int): int =
  ## Fallback when a stale route no longer starts here: the cheapest legal
  ## outgoing lane, ties by lane id. Never returns -1 on a real node.
  result = -1
  var best = high(int)
  for id in RoadGrid.outgoing[node]:
    let cost = laneCost(id, plan, occupancy[id], noise[noiseBase + id])
    if cost < best:
      best = cost
      result = id

proc pathCost*(path: openArray[int], plan: RoutingPlan,
    occupancy: openArray[int], noise: openArray[int],
    noiseBase: int): int =
  for id in path:
    result += laneCost(id, plan, occupancy[id], noise[noiseBase + id])
