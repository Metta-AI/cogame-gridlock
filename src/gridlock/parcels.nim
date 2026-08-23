## Demand: the canonical destination schedule, per-fleet mirroring, backlogs,
## loading and delivery bookkeeping.
##
## Demand is identical up to symmetry for all four fleets: one canonical
## sequence is drawn from the seeded stream over the non-depot nodes, and the
## fleet at depot `Dj` receives `mirror_j` of it. That is what makes the score
## comparison exact, and it is why all four demand patterns pull through the
## CENTRE district equally.

import types

proc isDepotNode*(n: int): bool =
  for depot in 0 ..< Seats:
    if depotNode(depot) == n:
      return true
  false

proc buildDestinationSchedule*(rng: var Pcg32, count: int): seq[int] =
  ## `count` canonical destinations over every non-depot node.
  var pool: seq[int]
  for n in 0 ..< NodeCount:
    if not isDepotNode(n):
      pool.add(n)
  result = newSeqOfCap[int](count)
  for _ in 0 ..< count:
    result.add(pool[rng.rand(pool.len)])

proc destinationFor*(canonical: int, depot: int): int {.inline.} =
  mirrorNode(canonical, depot)

proc pickBacklogIndex*(backlog: openArray[Parcel], depotNodeIndex: int,
    priority: Priority): int =
  ## `near` = smallest Manhattan distance from the depot (ties -> oldest),
  ## `far` = largest (ties -> oldest), `fifo` = oldest.
  if backlog.len == 0:
    return -1
  case priority
  of prFifo:
    return 0
  of prNear:
    result = 0
    var best = manhattan(depotNodeIndex, backlog[0].dest)
    for i in 1 ..< backlog.len:
      let d = manhattan(depotNodeIndex, backlog[i].dest)
      if d < best:
        best = d
        result = i
  of prFar:
    result = 0
    var best = manhattan(depotNodeIndex, backlog[0].dest)
    for i in 1 ..< backlog.len:
      let d = manhattan(depotNodeIndex, backlog[i].dest)
      if d > best:
        best = d
        result = i

proc takeBacklog*(backlog: var seq[Parcel], index: int): Parcel =
  result = backlog[index]
  backlog.delete(index)
