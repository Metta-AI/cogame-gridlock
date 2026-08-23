## Sim unit tests on movement, capacity and spillback — plus the source guard
## that keeps the step path integer-only.

import std/[os, strutils, unittest]
import support/helpers

const StepPathModules = [
  "src/gridlock/graph.nim",
  "src/gridlock/traffic.nim",
  "src/gridlock/parcels.nim"]

const BannedCalls = [
  "sin", "cos", "tan", "atan", "arctan", "exp", "ln", "pow",
  "fmod", "hypot", "sqrt"]

suite "movement":
  test "a van only ever enters an empty cell":
    var game = newTestSim(240)
    let lane = laneBetween(nodeIndex(0, 0), nodeIndex(1, 0))
    game.putVan(0, lane, 3)
    game.putVan(1, lane, 4)
    moveStep(game)
    check game.vehicles[0].cell == 4
    check game.vehicles[1].cell == 5
    check game.cellOccupant(lane, 3) == -1
    check game.vehicles[0].cell != game.vehicles[1].cell

  test "downstream-first discharges a queue as a wave, one cell each":
    var game = newTestSim(240)
    let lane = laneBetween(nodeIndex(0, 0), nodeIndex(1, 0))
    let cells = game.config.laneCells
    for i in 0 ..< 5:
      game.putVan(i, lane, i)
    var cellsBefore: seq[int]
    for i in 0 ..< 5:
      cellsBefore.add(game.vehicles[i].cell)
    moveStep(game)
    for i in 0 ..< 5:
      check game.vehicles[i].cell == cellsBefore[i] + 1
    var seen = newSeq[bool](cells)
    for i in 0 ..< 5:
      check not seen[game.vehicles[i].cell]
      seen[game.vehicles[i].cell] = true

  test "a stop-line van does not move in the movement step":
    var game = newTestSim(240)
    let lane = laneBetween(nodeIndex(0, 0), nodeIndex(1, 0))
    let stop = game.config.laneCells - 1
    game.putVan(0, lane, stop)
    moveStep(game)
    check game.vehicles[0].cell == stop

  test "a full lane freezes its feeding approach and the queue backs up":
    var game = newTestSim(240)
    let cells = game.config.laneCells
    let receiving = laneBetween(nodeIndex(1, 0), nodeIndex(2, 0))
    let feeding = laneBetween(nodeIndex(0, 0), nodeIndex(1, 0))
    var g = 0
    for cell in 0 ..< cells:
      game.putVan(g, receiving, cell)
      inc g
    check game.q[receiving] == cells
    let blocked = g
    game.putVan(g, feeding, cells - 1)
    game.vehicles[g].route = @[feeding, receiving]
    game.vehicles[g].target = laneOf(receiving).head
    inc g
    let queued = g
    game.putVan(g, feeding, cells - 3)
    ## Movement only: the intersection never runs, so the receiving lane stays
    ## full and the block has to propagate through cell occupancy alone.
    for _ in 0 ..< 120:
      inc game.tick
      moveStep(game)
      accumulateStats(game)
    check game.vehicles[blocked].lane == feeding
    check game.vehicles[blocked].cell == cells - 1
    check game.vehicles[queued].lane == feeding
    check game.vehicles[queued].cell == cells - 2   ## advanced once, then stuck
    check game.vehicles[blocked].state == vsStalled
    check game.stallVehicleTicks[game.vehicles[blocked].fleet] > 0
    check game.jamIndex >= 0

  test "no two vans ever occupy one cell over a full run":
    var game = newTestSim(episodeTicks(4800), 1234)
    runScripted(game, kindsOf(skDispatcher, skBeeline, skDispatcher,
      skBeeline))
    check invariantFailure(game) == ""
    var seen = newSeq[int](game.cells.len)
    for i in 0 ..< seen.len:
      seen[i] = -1
    for g in 0 ..< game.vehicles.len:
      if game.vehicles[g].lane < 0:
        continue
      let slot = game.vehicles[g].lane * game.config.laneCells +
        game.vehicles[g].cell
      check seen[slot] == -1
      seen[slot] = g
    check game.reason == "complete"

suite "intersection service":
  ## Both vans are given DIFFERENT onward lanes, so the discharge cap is the
  ## binding constraint rather than the one free cell behind the stop line.
  proc plantApproach(game: var Sim, approach, firstOnward,
      secondOnward: int) =
    let cells = game.config.laneCells
    game.putVan(0, approach, cells - 1)
    game.vehicles[0].route = @[approach, firstOnward]
    game.vehicles[0].target = laneOf(firstOnward).head
    game.putVan(1, approach, cells - 2)
    game.vehicles[1].route = @[approach, secondOnward]
    game.vehicles[1].target = laneOf(secondOnward).head

  proc greenTick(game: Sim, approach: int): int =
    while not laneIsGreen(approach, result, game.config.signalCycleTicks,
        game.config.greenNsTicks):
      inc result

  test "a green local approach discharges at most one per service step":
    var game = newTestSim(240)
    let approach = laneBetween(nodeIndex(0, 0), nodeIndex(0, 1))
    check not laneOf(approach).arterial
    game.plantApproach(approach,
      laneBetween(nodeIndex(0, 1), nodeIndex(0, 2)),
      laneBetween(nodeIndex(0, 1), nodeIndex(1, 1)))
    game.tick = greenTick(game, approach)
    serviceStep(game)
    var crossed = 0
    for g in 0 .. 1:
      if game.vehicles[g].lane != approach: inc crossed
    check crossed == 1

  test "a green arterial approach discharges up to two":
    var game = newTestSim(240)
    let approach = laneBetween(nodeIndex(2, 0), nodeIndex(2, 1))
    check laneOf(approach).arterial
    game.plantApproach(approach,
      laneBetween(nodeIndex(2, 1), nodeIndex(2, 2)),
      laneBetween(nodeIndex(2, 1), nodeIndex(3, 1)))
    game.tick = greenTick(game, approach)
    serviceStep(game)
    var crossed = 0
    for g in 0 .. 1:
      if game.vehicles[g].lane != approach: inc crossed
    check crossed == 2

  test "a red approach discharges nothing":
    var game = newTestSim(240)
    let approach = laneBetween(nodeIndex(0, 0), nodeIndex(0, 1))
    game.plantApproach(approach,
      laneBetween(nodeIndex(0, 1), nodeIndex(0, 2)),
      laneBetween(nodeIndex(0, 1), nodeIndex(1, 1)))
    var t = 0
    while laneIsGreen(approach, t, game.config.signalCycleTicks,
        game.config.greenNsTicks):
      inc t
    game.tick = t
    serviceStep(game)
    check game.vehicles[0].lane == approach
    check game.vehicles[1].lane == approach

  test "a discharge into a full receiving lane is simply not made":
    var game = newTestSim(240)
    let cells = game.config.laneCells
    let approach = laneBetween(nodeIndex(0, 0), nodeIndex(0, 1))
    let onward = laneBetween(nodeIndex(0, 1), nodeIndex(0, 2))
    var g = 2
    for cell in 0 ..< cells:
      game.putVan(g, onward, cell)
      inc g
    game.putVan(0, approach, cells - 1)
    game.vehicles[0].route = @[approach, onward]
    game.vehicles[0].target = laneOf(onward).head
    game.tick = greenTick(game, approach)
    serviceStep(game)
    check game.vehicles[0].lane == approach
    check game.vehicles[0].cell == cells - 1

suite "no floats in the step path":
  test "no transcendental call reaches ANY sim module":
    ## The note's guard is over `src/gridlock/*.nim`, not just the three
    ## step-path modules: the ban on transcendentals is what keeps the native
    ## and emscripten builds bit-identical, and it holds for every module the
    ## step can reach.
    var scanned = 0
    for path in walkFiles("src/gridlock/*.nim"):
      inc scanned
      let source = stripComments(readSource(path))
      for banned in BannedCalls:
        checkpoint(path & ": " & banned)
        check not containsCall(source, banned)
    check scanned >= 19

  test "no transcendental call reaches a step-path module":
    for path in StepPathModules:
      let source = stripComments(readSource(path))
      for banned in BannedCalls:
        check not containsCall(source, banned)

  test "no float type reaches a step-path module":
    for path in StepPathModules:
      let source = stripComments(readSource(path))
      check not source.contains("float")

  test "the step loop itself is integer-only":
    let source = stripComments(readSource("src/gridlock/sim.nim"))
    let start = source.find("proc stepTick*")
    check start >= 0
    let stop = source.find("proc endEpisode*", start)
    check stop > start
    let body = source[start ..< stop]
    check not body.contains("float")
    for banned in BannedCalls:
      check not containsCall(body, banned)

  test "-ffast-math is banned in every build script":
    for path in ["Dockerfile", "Dockerfile.replay-viewer",
        "replay-viewer/config.nims", "tools/build_replay_viewer.sh",
        "gridlock.nimble"]:
      check not readSource(path).contains("ffast-math")
