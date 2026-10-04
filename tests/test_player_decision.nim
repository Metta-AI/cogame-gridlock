import std/[json, options, unittest]
import gridlock/[types, plan, baselines, view, decision]
import bitworld/decision_trajectory

var calls = 0

proc mixedReplies(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  inc calls
  if calls == 1:
    doAssert requests.len == 2
    doAssert requests[0]["observation"]["seat"].getInt() == 0
    doAssert requests[1]["observation"]["seat"].getInt() == 1
    doAssert requests[0]["decision_id"].getStr() != requests[1]["decision_id"].getStr()
    doAssert timeoutMs == 14000
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "decision_id": requests[0]["decision_id"], "source": "llm",
      "action": {"dispatch": 70, "priority": "near"}})
    result.add("not json")
  else:
    doAssert requests.len == 1
    doAssert requests[0]["slot"].getInt() == 1
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "decision_id": requests[0]["decision_id"], "source": "llm",
      "action": {"dispatch": 60, "priority": "far"}})

proc noCredentials(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  doAssert requests.len == 2
  for request in requests:
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "decision_id": request["decision_id"], "source": "fallback",
      "cause": "no_credentials"})

proc snapshots(): array[Seats, SeatSnapshot] =
  for seat in 0 ..< Seats:
    result[seat] = SeatSnapshot(
      view: %*{"seat": seat},
      baseline: BaselineInput(),
      previous: defaultPlan(),
      scripted: (if seat < 2: skNone else: skDispatcher))

suite "ordinary player decision exchange":
  test "simultaneous private views, retry, and game-owned plan repair":
    calls = 0
    let decision = decidePlayers(snapshots(), 0, false, 22.0, mixedReplies)
    check calls == 2
    check decision.plans[0].source == psLlm
    check decision.plans[0].dispatch == 70
    check decision.plans[1].source == psLlm
    check decision.plans[1].dispatch == 60
    check decision.plans[1].priority == prFar
    check decision.plans[2].source == psScripted
    check decision.fallbacks.len == 1
    check decision.fallbacks[0].seat == 1
    check decision.fallbacks[0].cause == fcParseError
    check decision.attempts[0].len == 1
    check decision.attempts[1].len == 2
    check not decision.attempts[1][0].accepted
    check decision.attempts[1][1].accepted
    check decision.attempts[1][1].parsedAction == planJson(decision.plans[1])
    check decision.selectedAttemptIds[1].get() == decision.attempts[1][1].attemptId

  test "explicit missing credentials use the ordinary fallback":
    let decision = decidePlayers(snapshots(), 0, false, 22.0, noCredentials)
    check decision.plans[0].source == psFallback
    check decision.plans[1].source == psFallback
    check decision.fallbacks.len == 2
    check decision.fallbacks[0].cause == fcNoCredentials
    check decision.selectedAttemptIds[0].isNone
    check decision.attempts[0].len == 1
    check not decision.attempts[0][0].accepted

  test "external origins cannot mint server-owned teacher or human labels":
    for origin in [aoTeacher, aoHuman]:
      let asserted = newDecisionAttempt("asserted", "external-policy", origin)
      let raw = $(%*{"type": "action", "protocol": PlayerProtocol, "decision_id": "1",
        "source": "llm", "action": {"dispatch": 70},
        "training_attempt": asserted.attemptEvidenceJson()})
      let proposal = playerProposal(raw, "1", 0, snapshots()[0])
      check proposal.kind == pkAccepted
      check proposal.evidence.origin == aoUnknown
      check proposal.evidence.accepted
      check proposal.evidence.parsedAction == planJson(proposal.plan)

  test "a model reply cannot label a different executed player plan":
    var evidence = newDecisionAttempt("sampled", "model-policy", aoModel)
    evidence.response = %"{\"dispatch\":40}"
    evidence.model = some("fixture-model")
    evidence.rawResponse = %($(%*{"model": "fixture-model", "content": [
      {"type": "text", "text": evidence.response}]}))
    evidence.responseComplete = some(true)
    evidence.responseReaderJoined = some(true)
    evidence.httpStatus = some(200)
    let raw = $(%*{"type": "action", "protocol": PlayerProtocol, "decision_id": "1",
      "source": "llm", "action": {"dispatch": 70},
      "training_attempt": evidence.attemptEvidenceJson()})
    let proposal = playerProposal(raw, "1", 0, snapshots()[0])
    check proposal.kind == pkRejected
    check not proposal.evidence.accepted
    check proposal.evidence.parsedAction["dispatch"].getInt() == 40
    check proposal.plan.dispatch == 70


suite "ordinary exchange retries":
  test "two invalid replies retain both attempts before dispatcher fallback":
    var exchanges = 0
    var seats = snapshots()
    for seat in 0 ..< Seats: seats[seat].scripted = skNone
    proc invalid(requests: seq[JsonNode], timeoutMs: int): seq[string] {.gcsafe.} =
      inc exchanges
      for request in requests: result.add("no idea")
    let decision = decidePlayers(seats, 0, false, 22.0, invalid)
    check exchanges == 2
    check decision.fallbacks.len == Seats * 2
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psFallback
      check planIsLegal(decision.plans[seat])
      check decision.attempts[seat].len == 2
      check decision.selectedAttemptIds[seat].isNone

  test "one missing first reply retries only once through the normal parser":
    var exchanges = 0
    var seats = snapshots()
    for seat in 0 ..< Seats: seats[seat].scripted = skNone
    proc retry(requests: seq[JsonNode], timeoutMs: int): seq[string] {.gcsafe.} =
      inc exchanges
      for request in requests:
        if exchanges == 1:
          result.add("")
        else:
          result.add($(%*{"type": "action", "protocol": PlayerProtocol,
            "decision_id": request["decision_id"], "source": "llm",
            "action": {"congestion_weight": 55, "patience": 75}}))
    let decision = decidePlayers(seats, 0, false, 22.0, retry)
    check exchanges == 2
    check decision.fallbacks.len == Seats
    for seat in 0 ..< Seats:
      check decision.plans[seat].source == psLlm
      check decision.plans[seat].congestionWeight == 55
      check decision.attempts[seat].len == 2
      check decision.attempts[seat][0].rejectionReason.get() == "player plan timed out"
      check decision.attempts[seat][1].accepted
