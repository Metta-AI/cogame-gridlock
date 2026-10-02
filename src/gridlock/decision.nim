## Game-owned decision exchange, plan repair, fallback, and turn timing.
## Model calls and candidate ranking live in ordinary player policies.

import std/[json, monotimes, options, times]
import bitworld/decision_trajectory
import types, view, plan, baselines

const
  FirstAttemptSeconds = 14
  RetryAttemptSeconds = 6

type
  SeatSnapshot* = object
    view*: JsonNode
    baseline*: BaselineInput
    scripted*: ScriptKind
    previous*: RoutingPlan

  PlayerFallback* = object
    seat*: int
    attempt*: int
    cause*: FallbackCause
    detail*: string

  PlayerDecision* = object
    plans*: array[Seats, RoutingPlan]
    fallbacks*: seq[PlayerFallback]
    attempts*: array[Seats, seq[DecisionAttempt]]
    selectedAttemptIds*: array[Seats, Option[string]]

  DecisionExchange* = proc (requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.}

type
  ProposalKind* = enum pkAccepted, pkReportedFallback, pkRejected
  PlayerProposal* = object
    kind*: ProposalKind
    plan*: RoutingPlan
    evidence*: DecisionAttempt
    cause*: FallbackCause

proc playerProposal*(raw: string, requestId, seat: int,
    snapshot: SeatSnapshot): PlayerProposal =
  ## Shared hosted/language parser boundary; installation remains engine-owned.
  result.evidence = newDecisionAttempt($seat & "-" & $requestId, "external", aoUnknown)
  result.evidence.response = %raw
  result.evidence.rawResponse = %raw
  try:
    let reply = parseJson(raw)
    if reply.hasKey("training_attempt"):
      result.evidence = readAttemptEvidence(reply["training_attempt"])
      if result.evidence.origin in {aoTeacher, aoHuman}:
        result.evidence.origin = aoUnknown
    if reply["type"].getStr() == "attempt_timeout":
      raise newException(GridlockError, "player plan timed out after model request")
    if reply["type"].getStr() != "action" or
        reply["protocol"].getStr() != PlayerProtocol or
        reply["id"].getInt() != requestId:
      raise newException(GridlockError, "player action envelope mismatch")
    if reply{"source"}.getStr() == "fallback":
      result.kind = pkReportedFallback
      result.cause = case reply{"cause"}.getStr()
        of "no_credentials": fcNoCredentials
        of "timeout": fcTimeout
        else: fcTransportError
      result.evidence.rejectionReason = some("player policy reported fallback")
      return
    if reply{"source"}.getStr() != "llm":
      raise newException(GridlockError, "player action source must be llm")
    if reply.hasKey("response"):
      result.plan = parsePlan(reply["response"].getStr(), snapshot.previous)
    else:
      let proposed = reply["plan"]
      if proposed.kind != JObject or not hasAnyPlanKey(proposed):
        raise newException(GridlockError, "player action has no plan fields")
      result.plan = repairPlan(proposed, snapshot.previous)
    result.plan.source = psLlm
    result.kind = pkAccepted
    result.evidence.accepted = true
    result.evidence.parsedAction = planJson(result.plan)
  except CatchableError as error:
    result.kind = pkRejected
    result.cause = fcParseError
    result.evidence.rejectionReason = some(error.msg)

proc decidePlayers*(seats: array[Seats, SeatSnapshot], turn: int,
    guarded: bool, turnBudgetSeconds: float,
    exchange: DecisionExchange): PlayerDecision =
  ## Send all private views before either shared deadline starts. One invalid
  ## or missing reply gets a second attempt; the game repairs accepted plans.
  var pending: seq[int]
  for seat in 0 ..< Seats:
    if seats[seat].scripted != skNone or guarded:
      let kind =
        if seats[seat].scripted == skNone: skDispatcher
        else: seats[seat].scripted
      result.plans[seat] = scriptedPlan(seats[seat].baseline, kind)
      if seats[seat].scripted == skNone:
        result.plans[seat].source = psFallback
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: 0,
          cause: fcBudgetGuard, detail: "budget guard engaged"))
    else:
      pending.add(seat)

  let turnStart = getMonoTime()
  for attempt in 1 .. 2:
    if pending.len == 0:
      break
    let remainingMs = int(turnBudgetSeconds * 1000.0) -
      (getMonoTime() - turnStart).inMilliseconds.int
    if remainingMs <= 0:
      break
    let timeoutMs = min(remainingMs,
      if attempt == 1: FirstAttemptSeconds * 1000
      else: RetryAttemptSeconds * 1000)
    var requests: seq[JsonNode]
    for seat in pending:
      requests.add(%*{
        "type": "decision",
        "protocol": PlayerProtocol,
        "id": turn * 10 + attempt,
        "slot": seat,
        "turn": turn,
        "attempt": attempt,
        "timeout_ms": timeoutMs,
        "view": seats[seat].view
      })
    let started = getMonoTime()
    let replies = exchange(requests, timeoutMs)
    let latencyMs = max(0, (getMonoTime() - started).inMilliseconds.int)
    var retry: seq[int]
    for position, seat in pending:
      if position >= replies.len or replies[position].len == 0:
        var missing = newDecisionAttempt($seat & "-" & $requests[position]["id"].getInt(),
          "external", aoUnknown)
        missing.rejectionReason = some("player plan timed out")
        result.attempts[seat].add(missing)
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: fcTimeout, detail: "player plan timed out"))
        retry.add(seat)
        continue
      let proposal = playerProposal(replies[position],
        requests[position]["id"].getInt(), seat, seats[seat])
      result.attempts[seat].add(proposal.evidence)
      case proposal.kind
      of pkAccepted:
        result.plans[seat] = proposal.plan
        result.plans[seat].latencyMs = latencyMs
        result.selectedAttemptIds[seat] = some(proposal.evidence.attemptId)
      of pkReportedFallback:
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: proposal.cause, detail: "player policy reported fallback"))
        if proposal.cause != fcNoCredentials:
          retry.add(seat)
        else:
          result.plans[seat] = dispatcherPlan(seats[seat].baseline)
          result.plans[seat].source = psFallback
      of pkRejected:
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: proposal.cause, detail: "invalid private player reply"))
        retry.add(seat)
    pending = retry

  for seat in pending:
    result.plans[seat] = dispatcherPlan(seats[seat].baseline)
    result.plans[seat].source = psFallback
    result.plans[seat].latencyMs =
      max(0, (getMonoTime() - turnStart).inMilliseconds.int)
