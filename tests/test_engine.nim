## The turn loop against a fake LLM client: the parallel batch, the per-turn
## budget, the budget guard, the wall-clock stop, sim faults, and no-shows.
##
## The fake client is the `batchOverride` seam on LlmClient — the same
## decideAll path the server drives, with libcurl swapped out — so the test
## can observe the IN-FLIGHT WINDOW of every seat in a batch.

import std/[json, monotimes, os, unittest]
import support/helpers
import gridlock/roster
import gridlock/server

type
  Window = object
    seat: int
    startMs: int64
    stopMs: int64

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

proc seatRequests(game: Sim, scripted: array[Seats, ScriptKind]):
    array[Seats, SeatRequest] =
  for seat in 0 ..< Seats:
    result[seat] = SeatRequest(
      prompt: (if scripted[seat] == skNone: "play well" else: ""),
      viewJson: $buildView(game, seat),
      baseline: baselineInput(game, seat),
      scripted: scripted[seat],
      previous: game.plans[seat])

suite "one parallel batch per turn":
  test "all four seats' calls go out together and their windows intersect":
    var windows: seq[Window]
    var batches = 0
    var sizes: seq[int]
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        inc batches
        sizes.add(requests.len)
        let started = nowMs()
        ## Every request in a batch is issued together: the fake holds them
        ## all open for the same slice of wall clock, which is what
        ## makeRequests does.
        sleep(30)
        let stopped = nowMs()
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          windows.add(Window(seat: request.seat, startMs: started,
            stopMs: stopped))
          result[i] = LlmReply(seat: request.seat,
            text: fakeReplyPlan(40 + request.seat, 90)))
    var game = newTestSim(960)
    let decision = client.decideAll(seatRequests(game, allKinds(skNone)))
    check batches == 1
    check sizes == @[Seats]
    check windows.len == Seats
    for a in windows:
      for b in windows:
        check a.startMs < b.stopMs
        check b.startMs < a.stopMs
    check decision.llmSeats == Seats
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psLlm
      check decision.plans[seat].congestionWeight == 40 + seat

  test "every turn batches exactly four requests over a whole episode":
    var sizes: seq[int]
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        sizes.add(requests.len)
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          result[i] = LlmReply(seat: request.seat,
            text: fakeReplyPlan(50, 80)))
    var game = newTestSim(960)
    while game.tick < game.config.episodeTicks:
      let decision = client.decideAll(seatRequests(game, allKinds(skNone)))
      discard runTurn(game, decision.plans)
    check sizes.len == 4
    for size in sizes:
      check size == Seats
    check game.turnsLlm[0] == 4

  test "scripted seats never enter the batch":
    var seen: seq[int]
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          seen.add(request.seat)
          result[i] = LlmReply(seat: request.seat,
            text: fakeReplyPlan(20, 60)))
    var game = newTestSim(960)
    let decision = client.decideAll(seatRequests(game,
      kindsOf(skNone, skDispatcher, skNone, skBeeline)))
    check seen == @[0, 2]
    check decision.plans[1].source == psScripted
    check decision.plans[3].congestionWeight == 0

  test "a recorded plan carries the batch's measured latency":
    ## `latency_ms` is in the replay's plan record and in the note's event
    ## table; it has to be the real wait, not a placeholder.
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        sleep(40)
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          result[i] = LlmReply(seat: request.seat,
            text: fakeReplyPlan(35, 70)))
    var game = newTestSim(960)
    let decision = client.decideAll(seatRequests(game, allKinds(skNone)))
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psLlm
      check decision.plans[seat].latencyMs >= 30
    discard runTurn(game, decision.plans)
    var planEvents = 0
    for event in game.events:
      if event.kind == sePlan:
        inc planEvents
        check event.body["latency_ms"].getInt() >= 30
    check planEvents == Seats

  test "a hung client is bounded by the two attempt deadlines":
    ## The fake reports a timeout rather than actually hanging; what the test
    ## pins is that decideAll makes at most two attempts and always returns.
    var attempts = 0
    var deadlines: seq[int]
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        inc attempts
        deadlines.add(timeoutSeconds)
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          result[i] = LlmReply(seat: request.seat,
            error: "llm transport: timed out"))
    var game = newTestSim(960)
    let decision = client.decideAll(seatRequests(game, allKinds(skNone)))
    check attempts == 2
    check deadlines == @[FirstAttemptSeconds, RetryAttemptSeconds]
    check FirstAttemptSeconds + RetryAttemptSeconds <= 22
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psFallback
      check planIsLegal(decision.plans[seat])

suite "wall-clock guards":
  test "the budget guard engages before two more turns would overrun":
    check not budgetGuardEngaged(0.0, 22.0, 660.0)
    check not budgetGuardEngaged(600.0, 22.0, 660.0)
    check budgetGuardEngaged(620.0, 22.0, 660.0)
    check budgetGuardEngaged(659.0, 22.0, 660.0)

  test "the spacing floor holds batches at least minTurnSpacing apart":
    check spacingRemaining(0.0, 10.0) == 10.0
    check spacingRemaining(4.0, 10.0) == 6.0
    check spacingRemaining(12.0, 10.0) == 0.0
    check spacingRemaining(1.0, 0.0) == 0.0
    ## Four requests a batch against a 30 req/min sidecar cap needs >= 8 s.
    check 10.0 >= 60.0 * float(Seats) / 30.0

  test "the guarded episode finishes complete/full_time on the scripted layer":
    var game = newTestSim(960)
    var guarded = false
    var elapsed = 0.0
    while game.tick < game.config.episodeTicks:
      if not guarded and budgetGuardEngaged(elapsed, 22.0, 60.0):
        guarded = true
        game.events.add(newEvent(seBudgetGuard, game.tick, game.turn,
          %*{"remaining_s": 60.0 - elapsed}))
      ## Guarded or not, the scripted layer costs microseconds a turn, so the
      ## episode reaches full time instead of the wall-clock stop.
      discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
      elapsed += 22.0
    endEpisode(game, "complete", "full_time")
    check guarded
    check game.reason == "complete"
    check game.endRule == "full_time"
    var guards = 0
    for event in game.events:
      if event.kind == seBudgetGuard: inc guards
    check guards == 1

  test "the wall-clock stop yields deadline/wall_clock with a partial replay":
    var game = newTestSim(4800, 21)
    discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
    discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
    endEpisode(game, "deadline", "wall_clock")
    let results = resultsJson(game)
    check results["reason"].getStr() == "deadline"
    check results["end_rule"].getStr() == "wall_clock"
    check results["final_tick"].getInt() == 480
    let bytes = replayBytes(game, results)
    let parsed = parseReplayBytes(bytes)
    check parsed.tickCount == 480
    check parsed.plans.len == 2

  test "a replan onto a route that does not start at the van's node faults":
    ## Step 14's route guard. It never fires on a healthy router — Dijkstra
    ## backtracks from the target to the vehicle's own node — so the test
    ## plants the broken route the guard exists to catch.
    var game = newTestSim(960, 21)
    discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
    check invariantFailure(game) == ""
    var g = -1
    for i in 0 ..< game.vehicles.len:
      if game.vehicles[i].lane >= 0 and game.vehicles[i].route.len >= 2:
        g = i
        break
    check g >= 0
    check routeStartFailure(game, g) == ""
    let here = laneOf(game.vehicles[g].lane).head
    var stale = -1
    for lane in 0 ..< LaneCount:
      if laneOf(lane).tail != here:
        stale = lane
        break
    check stale >= 0
    game.vehicles[g].route[1] = stale
    check routeStartFailure(game, g).len > 0
    game.vehicles[g].route[0] = stale
    check routeStartFailure(game, g).len > 0
    game.routeFault = routeStartFailure(game, g)
    check invariantFailure(game).len > 0

  test "a sim fault yields fault/sim_fault with zeros and a partial replay":
    var game = newTestSim(960, 21)
    discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
    ## Plant the invariant break the guard is there to catch.
    var a = -1
    var b = -1
    for g in 0 ..< game.vehicles.len:
      if game.vehicles[g].lane >= 0:
        if a < 0: a = g
        elif b < 0: b = g
        else: break
    check a >= 0 and b >= 0
    game.vehicles[b].lane = game.vehicles[a].lane
    game.vehicles[b].cell = game.vehicles[a].cell
    let failure = invariantFailure(game)
    check failure.len > 0
    endEpisode(game, "fault", "sim_fault", failure)
    let results = resultsJson(game)
    check results["reason"].getStr() == "fault"
    check results["winner"].kind == JNull
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() == 0.0
    let parsed = parseReplayBytes(replayBytes(game, results))
    check parsed.results["reason"].getStr() == "fault"

suite "seats that misbehave":
  test "a seat that never registers plays the dispatcher baseline":
    var seats = initRoster(@["a", "b", "c", "d"])
    check effectiveScript(seats.seats[0]) == skDispatcher
    check policyKindOf(seats.seats[0]) == "scripted"
    ## Registering with neither field is the same thing.
    seats.applyRegistration(0, %*{"type": "register", "prompt": "",
      "scripted": newJNull()})
    check effectiveScript(seats.seats[0]) == skDispatcher
    ## A prompt makes it an LLM seat.
    seats.applyRegistration(1, %*{"type": "register", "prompt": "route well",
      "scripted": newJNull(), "policy": "gridlock-flowwright"})
    check effectiveScript(seats.seats[1]) == skNone
    check policyKindOf(seats.seats[1]) == "llm"
    check seats.seats[1].policyLabel == "gridlock-flowwright"
    ## And an explicit baseline name wins.
    seats.applyRegistration(2, %*{"type": "register", "prompt": "ignored",
      "scripted": "beeline"})
    check effectiveScript(seats.seats[2]) == skBeeline
    check policyKindOf(seats.seats[2]) == "scripted"

  test "a no-show is declared to COGAME_PLAYER_FAILURE_URI":
    let dir = getTempDir() / "gridlock-failure-test"
    createDir(dir)
    let path = dir / "player_failure.json"
    removeFile(path)
    putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)
    declarePlayerFailure(2, "seat 2 never connected")
    delEnv("COGAME_PLAYER_FAILURE_URI")
    check fileExists(path)
    let payload = parseJson(readFile(path))
    check payload["failed_policy_index"].getInt() == 2
    removeFile(path)

  test "a bad token is refused and a good one is not":
    let seats = initRoster(@["t0", "t1", "t2", "t3"])
    check seats.authorize(0, "t0")
    check not seats.authorize(0, "t1")
    check not seats.authorize(-1, "t0")
    check not seats.authorize(9, "t0")
    check not seats.authorize(1, "")

  test "an over-long prompt is truncated on a rune boundary, never rejected":
    var seats = initRoster(@["a", "b", "c", "d"])
    var giant = ""
    for _ in 0 ..< (MaxPromptRunes + 500):
      giant.add("\xE2\x9C\x93")
    seats.applyRegistration(0, %*{"type": "register", "prompt": giant})
    check seats.seats[0].prompt.len < giant.len
    check seats.seats[0].registered
    check effectiveScript(seats.seats[0]) == skNone
