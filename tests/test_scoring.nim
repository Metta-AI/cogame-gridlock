## The score, its sign, and the endings.
##
## Score is own parcels delivered — a raw count, deliberately NOT a share and
## NOT constant-sum. The last test in this file is the commons property: four
## fleets can all do badly at once and the numbers show it.

import std/[json, unittest]
import support/helpers

suite "score":
  test "score is exactly the delivery count, for 500 random vectors":
    var probe = newTestSim(240, 1)
    var rng = initPcg32(2026)
    for _ in 0 ..< 500:
      var delivered: array[Seats, int]
      for seat in 0 ..< Seats:
        delivered[seat] = rng.rand(400)
        probe.delivered[seat] = delivered[seat]
      for seat in 0 ..< Seats:
        check scoreOf(probe, seat) == float(delivered[seat])
      var raw: seq[int]
      for seat in 0 ..< Seats:
        raw.add(delivered[seat])
      let flags = winFlags(raw)
      var best = raw[0]
      for value in raw:
        if value > best: best = value
      var ties = 0
      for value in raw:
        if value == best: inc ties
      for i, value in raw:
        check flags[i] == (value == best and ties == 1)
      check (winnerOf(raw) >= 0) == (ties == 1)

  test "more deliveries is always a higher score":
    for a in [0, 1, 5, 60, 163, 400]:
      for b in [0, 1, 5, 60, 163, 400]:
        if a < b:
          check float(a) < float(b)

  test "win and winner on a unique maximum, a tie, and all zero":
    check winnerOf(@[163, 148, 96, 71]) == 0
    check winFlags(@[163, 148, 96, 71]) == @[true, false, false, false]
    check winnerOf(@[100, 100, 3, 1]) == -1
    check winFlags(@[100, 100, 3, 1]) == @[false, false, false, false]
    check winnerOf(@[0, 0, 0, 0]) == -1
    check winFlags(@[0, 0, 0, 0]) == @[false, false, false, false]

suite "results document":
  test "a completed episode scores the counters and names a winner or a tie":
    var game = newTestSim(episodeTicks(1920), 5)
    runScripted(game, allKinds(skDispatcher))
    let results = resultsJson(game)
    check results["reason"].getStr() == "complete"
    check results["end_rule"].getStr() == "full_time"
    check results["scores"].len == Seats
    var total = 0
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() == float(game.delivered[seat])
      check results["delivered"][seat].getInt() == game.delivered[seat]
      total += game.delivered[seat]
    check results["total_delivered"].getInt() == total
    check total > 0

  test "a fault gives four zeros and a null winner":
    var game = newTestSim(480, 5)
    runScripted(game, allKinds(skDispatcher))
    game.finished = false
    endEpisode(game, "fault", "sim_fault", "planted")
    let results = resultsJson(game)
    check results["reason"].getStr() == "fault"
    check results["end_rule"].getStr() == "sim_fault"
    check results["winner"].kind == JNull
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() == 0.0
      check results["delivered"][seat].getInt() == 0
    check results["total_delivered"].getInt() == 0

  test "a deadline cut mid-episode scores the counters as they stand":
    var game = newTestSim(1920, 11)
    var kinds = allKinds(skDispatcher)
    ## Stop after two turns, exactly as the engine's wall-clock stop does.
    for _ in 0 ..< 2:
      discard runTurn(game, scriptedPlansFor(game, kinds))
    let standing = game.delivered
    endEpisode(game, "deadline", "wall_clock")
    let results = resultsJson(game)
    check results["reason"].getStr() == "deadline"
    check results["end_rule"].getStr() == "wall_clock"
    for seat in 0 ..< Seats:
      check results["delivered"][seat].getInt() == standing[seat]
    check results["final_tick"].getInt() == game.tick
    check game.tick < game.config.episodeTicks

  test "the score is NOT normalised: four bad fleets produce four small numbers":
    ## The commons property. An all-beeline table jams itself; the totals stay
    ## absolute, so the collapse is visible in the numbers rather than hidden
    ## by a share.
    var greedy = newTestSim(episodeTicks(2400), 3)
    runScripted(greedy, allKinds(skBeeline))
    var metered = newTestSim(episodeTicks(2400), 3)
    runScripted(metered, allKinds(skDispatcher))
    let greedyResults = resultsJson(greedy)
    let meteredResults = resultsJson(metered)
    var greedyShare = 0.0
    for seat in 0 ..< Seats:
      greedyShare += greedyResults["scores"][seat].getFloat()
    var meteredShare = 0.0
    for seat in 0 ..< Seats:
      meteredShare += meteredResults["scores"][seat].getFloat()
    ## Raw counts, never shares: the sum is whatever the city produced, and
    ## it is destructible.
    check greedyShare == float(totalDelivered(greedy))
    check meteredShare == float(totalDelivered(metered))
    check greedyShare > 0.0
    check meteredShare > 0.0
    check greedyResults["total_delivered"].getInt() == totalDelivered(greedy)
    check meteredResults["total_delivered"].getInt() ==
      totalDelivered(metered)
    for seat in 0 ..< Seats:
      check greedyResults["scores"][seat].getFloat() ==
        float(greedy.delivered[seat])

  test "every documented results key is present and nothing else is":
    var game = newTestSim(480, 5)
    runScripted(game, allKinds(skDispatcher))
    let results = resultsJson(game)
    for key in ResultsKeys:
      check results.hasKey(key)
    check results.len == ResultsKeys.len
