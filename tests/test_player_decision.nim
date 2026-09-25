import std/[json, unittest]
import gridlock/[types, plan, baselines, view, decision]

var calls = 0

proc mixedReplies(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  inc calls
  if calls == 1:
    doAssert requests.len == 2
    doAssert requests[0]["view"]["seat"].getInt() == 0
    doAssert requests[1]["view"]["seat"].getInt() == 1
    doAssert requests[0]["id"].getInt() == requests[1]["id"].getInt()
    doAssert timeoutMs == 14000
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "id": requests[0]["id"], "source": "llm",
      "plan": {"dispatch": 70, "priority": "near"}})
    result.add("not json")
  else:
    doAssert requests.len == 1
    doAssert requests[0]["slot"].getInt() == 1
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "id": requests[0]["id"], "source": "llm",
      "plan": {"dispatch": 60, "priority": "far"}})

proc noCredentials(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  doAssert requests.len == 2
  for request in requests:
    result.add($ %*{
      "type": "action", "protocol": PlayerProtocol,
      "id": request["id"], "source": "fallback",
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

  test "explicit missing credentials use the ordinary fallback":
    let decision = decidePlayers(snapshots(), 0, false, 22.0, noCredentials)
    check decision.plans[0].source == psFallback
    check decision.plans[1].source == psFallback
    check decision.fallbacks.len == 2
    check decision.fallbacks[0].cause == fcNoCredentials
