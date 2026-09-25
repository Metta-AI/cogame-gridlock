## Game-owned decision exchange, plan repair, fallback, and turn timing.
## Model calls and candidate ranking live in ordinary player policies.

import std/[json, monotimes, times]
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

  DecisionExchange* = proc (requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.}

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
      var failure = ""
      if position >= replies.len or replies[position].len == 0:
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: fcTimeout, detail: "player plan timed out"))
        retry.add(seat)
        continue
      try:
        let reply = parseJson(replies[position])
        if reply["type"].getStr() != "action" or
            reply["protocol"].getStr() != PlayerProtocol or
            reply["id"].getInt() != requests[position]["id"].getInt():
          raise newException(GridlockError, "player action envelope mismatch")
        if reply{"source"}.getStr() == "fallback":
          let cause =
            case reply{"cause"}.getStr()
            of "no_credentials": fcNoCredentials
            of "timeout": fcTimeout
            else: fcTransportError
          result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
            cause: cause, detail: "player policy reported fallback"))
          if cause != fcNoCredentials:
            retry.add(seat)
          else:
            result.plans[seat] = dispatcherPlan(seats[seat].baseline)
            result.plans[seat].source = psFallback
          continue
        if reply{"source"}.getStr() != "llm":
          raise newException(GridlockError, "player action source must be llm")
        let rawPlan = reply["plan"]
        if rawPlan.kind != JObject or not hasAnyPlanKey(rawPlan):
          raise newException(GridlockError, "player action has no plan fields")
        result.plans[seat] = repairPlan(rawPlan, seats[seat].previous)
        result.plans[seat].source = psLlm
        result.plans[seat].latencyMs = latencyMs
      except CatchableError as error:
        failure = error.msg
      if failure.len > 0:
        result.fallbacks.add(PlayerFallback(seat: seat, attempt: attempt,
          cause: fcParseError, detail: cleanLine(failure, MaxDetailRunes)))
        retry.add(seat)
    pending = retry

  for seat in pending:
    result.plans[seat] = dispatcherPlan(seats[seat].baseline)
    result.plans[seat].source = psFallback
    result.plans[seat].latencyMs =
      max(0, (getMonoTime() - turnStart).inMilliseconds.int)
