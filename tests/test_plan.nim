## Tolerant parsing, repair, rune-safe truncation, and the derived router
## coefficients.

import std/[json, unicode, unittest]
import support/helpers

suite "tolerant parsing":
  setup:
    let previous = defaultPlan()

  test "a clean object parses":
    let plan = parsePlan(fakeReplyPlan(65, 80), previous)
    check plan.congestionWeight == 65
    check plan.dispatch == 80
    check plan.priority == prNear
    check plan.source == psLlm

  test "prose before the object is tolerated":
    let text = "Sure! Here is my plan for this turn:\n" &
      fakeReplyPlan(30, 90) & "\nLet me know if you want more."
    let plan = parsePlan(text, previous)
    check plan.congestionWeight == 30
    check plan.dispatch == 90

  test "markdown fences are tolerated":
    let text = "```json\n" & fakeReplyPlan(12, 70) & "\n```"
    let plan = parsePlan(text, previous)
    check plan.congestionWeight == 12

  test "numeric strings and percentages are accepted":
    let plan = parsePlan("""{"congestion_weight":"70%","patience":"25",
      "dispatch":55.4,"spread":"0","priority":"FaR"}""", previous)
    check plan.congestionWeight == 70
    check plan.patience == 25
    check plan.dispatch == 55
    check plan.spread == 0
    check plan.priority == prFar

  test "corridor as an object and as a district name":
    let a = parsePlan("""{"congestion_weight":10,"corridor":{"bx":1,"by":1}}""",
      previous)
    check a.corridor == districtIndex(1, 1)
    let b = parsePlan("""{"congestion_weight":10,"corridor":"centre"}""",
      previous)
    check b.corridor == districtIndex(1, 1)
    let c = parsePlan("""{"congestion_weight":10,"corridor":"SE"}""", previous)
    check c.corridor == districtIndex(2, 2)
    let d = parsePlan("""{"congestion_weight":10,"corridor":"nowhere"}""",
      previous)
    check d.corridor == -1

  test "out-of-range districts clamp and wrong arity becomes null":
    let a = parsePlan("""{"dispatch":50,"corridor":[9,-4]}""", previous)
    check a.corridor == districtIndex(2, 0)
    let b = parsePlan("""{"dispatch":50,"corridor":[1]}""", previous)
    check b.corridor == -1
    let c = parsePlan("""{"dispatch":50,"corridor":[1,1,1]}""", previous)
    check c.corridor == -1

  test "negative and 300-valued integers clamp":
    let plan = parsePlan("""{"congestion_weight":-40,"patience":300,
      "dispatch":-1,"spread":9999}""", previous)
    check plan.congestionWeight == 0
    check plan.patience == 100
    check plan.dispatch == 0
    check plan.spread == 100

  test "a plan may not prefer and shun the same district":
    let plan = parsePlan("""{"dispatch":80,"corridor":[1,1],"avoid":[1,1]}""",
      previous)
    check plan.corridor == districtIndex(1, 1)
    check plan.avoid == -1
    check planIsLegal(plan)

  test "garbage priority becomes fifo, missing priority becomes fifo":
    check parsePlan("""{"dispatch":80,"priority":"sideways"}""",
      previous).priority == prFifo
    check parsePlan("""{"dispatch":80}""", previous).priority == prFifo

  test "missing integers fall back to the previous turn's plan":
    var earlier = defaultPlan()
    earlier.congestionWeight = 77
    earlier.patience = 12
    earlier.dispatch = 34
    earlier.spread = 56
    let plan = parsePlan("""{"note":"held"}""", earlier)
    check plan.congestionWeight == 77
    check plan.patience == 12
    check plan.dispatch == 34
    check plan.spread == 56
    check plan.note == "held"

  test "turn zero defaults are the documented ones":
    let plan = parsePlan("""{"note":"first"}""", defaultPlan())
    check plan.congestionWeight == 40
    check plan.patience == 50
    check plan.dispatch == 100
    check plan.spread == 40

  test "a reply with no plan keys at all is rejected":
    expect GridlockError:
      discard parsePlan("""{"weather":"fine"}""", previous)
    expect GridlockError:
      discard parsePlan("I am not going to answer that.", previous)

  test "the quoted head of an unparseable reply is cut on a rune boundary":
    ## That message becomes `fallback.detail` in the replay, so it must not
    ## carry half a multi-byte character out of the model's reply. The truck
    ## emoji is 4 bytes, so a byte cut at 160 would split one.
    var prose = ""
    for _ in 0 ..< 300:
      prose.add("\xF0\x9F\x9A\x9A")
    var caught = ""
    try:
      discard parsePlan(prose, previous)
    except GridlockError as error:
      caught = error.msg
    check caught.len > 0
    check validateUtf8(caught) == -1
    check caught.runeLen <= MaxErrorHeadRunes + 40
    check cleanLine(caught, MaxDetailRunes).runeLen <= MaxDetailRunes
    check validateUtf8(cleanLine(caught, MaxDetailRunes)) == -1

suite "rune-safe truncation":
  test "a 400-character note is cut to 140 runes":
    var long = ""
    for _ in 0 ..< 400:
      long.add("a")
    let plan = parsePlan($ %*{"dispatch": 80, "note": long}, defaultPlan())
    check plan.note.runeLen == MaxNoteRunes

  test "a say whose 32nd and 33rd runes are a 4-byte emoji cuts on the rune":
    ## The bug this pins: a BYTE truncation splits the emoji, the replay
    ## renders in a browser and then fails a strict UTF-8 parser.
    var say = ""
    for _ in 0 ..< 31:
      say.add("x")
    say.add("\xF0\x9F\x9A\x9B")     # U+1F69B, a 4-byte truck
    say.add("\xF0\x9F\x9A\xA6")     # U+1F6A6, a 4-byte traffic light
    check say.runeLen == 33
    let plan = parsePlan($ %*{"dispatch": 80, "say": say}, defaultPlan())
    check plan.say.runeLen == MaxSayRunes
    check validateUtf8(plan.say) == -1
    ## And it still round-trips through the JSON writer and reader.
    let encoded = $planJson(plan)
    check validateUtf8(encoded) == -1
    let decoded = parseJson(encoded)
    check decoded["say"].getStr() == plan.say
    check decoded["say"].getStr().runeLen == MaxSayRunes

  test "the whole recorded string set is rune-truncated":
    var wide = ""
    for _ in 0 ..< 500:
      wide.add("\xE2\x9C\x93")      # U+2713, 3 bytes
    check clipRunes(wide, 140).runeLen == 140
    check validateUtf8(clipRunes(wide, 140)) == -1
    check cleanLine("a\nb\tc", 140) == "a b c"
    check clipRunes("short", 140) == "short"
    check clipRunes("anything", 0) == ""

suite "derived coefficients":
  test "replanQueue spans 3..13 across the patience range":
    var plan = defaultPlan()
    plan.patience = 0
    check replanQueue(plan) == 3
    plan.patience = 100
    check replanQueue(plan) == 13
    for patience in 0 .. 100:
      plan.patience = patience
      check replanQueue(plan) in 3 .. 13

  test "activeCap spans 0..fleetSize and releasePerStep spans 1..6":
    var plan = defaultPlan()
    for dispatch in 0 .. 100:
      plan.dispatch = dispatch
      check activeCap(plan, 50) in 0 .. 50
    plan.dispatch = 0
    check activeCap(plan, 50) == 0
    plan.dispatch = 100
    check activeCap(plan, 50) == 50
    for spread in 0 .. 100:
      plan.spread = spread
      check releasePerStep(plan) in 1 .. 6
    plan.spread = 0
    check releasePerStep(plan) == 6
    plan.spread = 100
    check releasePerStep(plan) == 1

suite "retry and fallback":
  test "two consecutive failures give the dispatcher plan plus a fallback":
    var calls = 0
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        inc calls
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          result[i] = LlmReply(seat: request.seat, text: "no idea"))
    var game = newTestSim(240)
    var seats: array[Seats, SeatRequest]
    for seat in 0 ..< Seats:
      seats[seat] = SeatRequest(prompt: "be good", viewJson: "{}",
        baseline: baselineInput(game, seat), scripted: skNone,
        previous: defaultPlan())
    let decision = client.decideAll(seats)
    check calls == 2                       ## one attempt plus exactly one retry
    check decision.fallbacks.len == Seats * 2
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psFallback
      check planIsLegal(decision.plans[seat])

  test "a timeout on attempt one gives exactly one retry, and it can succeed":
    var calls = 0
    let client = newOfflineLlmClient(
      proc (requests: seq[LlmRequest], timeoutSeconds: int): seq[LlmReply]
          {.closure.} =
        inc calls
        result = newSeq[LlmReply](requests.len)
        for i, request in requests:
          if calls == 1:
            result[i] = LlmReply(seat: request.seat,
              error: "llm transport: operation timed out")
          else:
            result[i] = LlmReply(seat: request.seat,
              text: fakeReplyPlan(55, 75)))
    var game = newTestSim(240)
    var seats: array[Seats, SeatRequest]
    for seat in 0 ..< Seats:
      seats[seat] = SeatRequest(prompt: "be good", viewJson: "{}",
        baseline: baselineInput(game, seat), scripted: skNone,
        previous: defaultPlan())
    let decision = client.decideAll(seats)
    check calls == 2
    check decision.llmSeats == Seats
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psLlm
      check decision.plans[seat].congestionWeight == 55
    check decision.fallbacks.len == Seats
    for record in decision.fallbacks:
      check record.attempt == 1
      check record.cause == fcTimeout
      check record.detail.runeLen <= MaxDetailRunes
