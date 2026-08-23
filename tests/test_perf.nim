## Performance. 4800 ticks with 200 vans, 288 lanes and the full replan budget
## must complete well inside the per-turn budget the wall-clock arithmetic
## assumes, and a turn-snapshot round trip must be cheap enough that a
## backward seek in the viewer is instant.
##
## The bound is deliberately loose: the point is to catch an accidental
## quadratic, not to police a few milliseconds. Debug builds carry range and
## overflow checks and are 10-50x slower, so the bound is scaled there.

import std/[monotimes, times, unittest]
import support/helpers

proc elapsedSeconds(start: MonoTime): float =
  float((getMonoTime() - start).inNanoseconds) / 1_000_000_000.0

const FullEpisodeBound =
  when defined(release): 40.0
  else: 400.0

const SnapshotBoundMs =
  when defined(release): 5.0
  else: 60.0

suite "performance":
  test "a full 4800-tick episode with 200 vans completes inside the bound":
    let start = getMonoTime()
    var game = newTestSim(4800, 42)
    runScripted(game, allKinds(skDispatcher))
    let seconds = elapsedSeconds(start)
    echo "gridlock perf: 4800 ticks in ", seconds, " s (bound ",
      FullEpisodeBound, " s), delivered ", totalDelivered(game)
    check game.tick == 4800
    check game.reason == "complete"
    check seconds < FullEpisodeBound

  test "the jam-heavy all-beeline table is inside the same bound":
    let start = getMonoTime()
    var game = newTestSim(4800, 42, orderPeriodTicks = 12)
    runScripted(game, allKinds(skBeeline))
    let seconds = elapsedSeconds(start)
    echo "gridlock perf: jammed 4800 ticks in ", seconds, " s"
    check game.tick == 4800
    check seconds < FullEpisodeBound

  test "one turn-snapshot round trip is cheap":
    var game = newTestSim(1920, 42)
    game.keepSnapshots = true
    for _ in 0 ..< 4:
      discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
    check game.snapshots.len == 4
    let snap = game.snapshots[2]
    let start = getMonoTime()
    var rounds = 0
    for _ in 0 ..< 20:
      var rewound = game
      restoreSnapshot(rewound, snap)
      inc rounds
    let perRoundMs = elapsedSeconds(start) * 1000.0 / float(rounds)
    echo "gridlock perf: snapshot round trip ", perRoundMs, " ms"
    check perRoundMs < SnapshotBoundMs

  test "the replan budget really is bounded per tick":
    var game = newTestSim(960, 42, orderPeriodTicks = 12)
    var plans: array[Seats, RoutingPlan]
    for seat in 0 ..< Seats:
      plans[seat] = defaultPlan()
      plans[seat].patience = 0        ## re-plan at the slightest queue
    installPlans(game, plans)
    ## After a turn start every on-road van is enqueued, so the FIFO is the
    ## thing that keeps the per-tick cost flat.
    for _ in 0 ..< 240:
      let before = game.replanQueue.len - game.replanHead
      stepTick(game)
      let after = game.replanQueue.len - game.replanHead
      check before - after <= game.config.routeBudgetPerTick + 200
    check game.config.routeBudgetPerTick == 24
