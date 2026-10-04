## Gridlock prompt/scripted player with one owned native reader per decision.
import std/[atomics, json, locks, math, monotimes, options, os, strutils, times]
import bitworld/[decision_trajectory, native_stop, native_websocket]
import gridlock/[llm, plan, types]

type PlayerCall = object
  socket: ptr NativeWebSocket
  decisionId, observation, prompt, policy: string
  slot, attempt: int
  deadline: MonoTime

var
  worker: Thread[PlayerCall]
  workerCreated = false
  workerFinished: Atomic[bool]
  evidenceLock: Lock
  workerEvidence: string

initLock(evidenceLock)

proc joinWorker() =
  if workerCreated:
    joinThread(worker)
    workerCreated = false

proc runDecision(call: PlayerCall) {.gcsafe.} =
  defer: workerFinished.store(true)
  let observation = parseJson(call.observation)
  var action = newJNull()
  var source = "llm"
  var attempt = newJNull()
  var failure = ""
  let client = newLlmClient(parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")),
    getEnv("PLAYER_MODEL", "anthropic/claude-haiku-4.5"))
  if client.disabled:
    source = "fallback"
  else:
    proc beforeCall(evidence: DecisionAttempt) =
      let started = evidence.attemptEvidenceJson()
      {.gcsafe.}:
        withLock evidenceLock: workerEvidence = $started
      let sent = call.socket[].sendNativeText($(%*{"type": "attempt_started",
        "decision_id": call.decisionId, "training_attempt": started}), call.deadline)
      if sent.kind != wsReady:
        raise newException(GridlockError, "native attempt start was not delivered")
    try:
      let response = client.choosePromptPlan(call.prompt, call.observation,
        call.attempt > 1, call.deadline, call.slot, call.decisionId & "-model",
        call.policy, beforeCall)
      let previous =
        if observation["you"]["last_plan"].kind == JNull: defaultPlan()
        else: planFromJson(observation["you"]["last_plan"])
      action = planJson(parsePlan(response, previous))
    except CatchableError as error:
      failure = error.msg
      echo "gridlock player: native policy call failed"
      source = "fallback"
      client.lastAttempt.rejectionReason = some(failure)
    attempt = client.lastAttempt.attemptEvidenceJson()
    {.gcsafe.}:
      withLock evidenceLock: workerEvidence = $attempt
  if not interruptionRequested():
    discard call.socket[].sendNativeText($(%*{"type": "action", "decision_id": call.decisionId,
      "protocol": PlayerProtocol, "action": action, "source": source,
      "cause": "transport_error", "training_attempt": attempt}), call.deadline)

proc stopAndAcknowledge(socket: NativeWebSocket, decisionId, stopId: JsonNode,
    cleanupDeadline: MonoTime): bool =
  ## Acknowledgement proves this owned worker joined, never a platform receipt.
  requestNativeStop()
  let hadWorker = workerCreated
  joinWorker()
  var attempts = newJArray()
  withLock evidenceLock:
    if workerEvidence.len > 0: attempts.add(parseJson(workerEvidence))
  let sent = socket.sendCleanupText($(%*{"type": "stopped", "decision_id": decisionId, "stop_id": stopId,
    "worker_status": (if hadWorker: "joined" else: "no_active_call"),
    "attempts": attempts}), cleanupDeadline)
  if sent.kind != wsReady: return false
  while getMonoTime() < cleanupDeadline:
    let received = socket.receiveCleanupText(cleanupDeadline)
    if received.kind != wsMessage: return false
    let frame = parseJson(received.data)
    if frame["type"].getStr() == "evidence_received" and
        frame["decision_id"] == decisionId and frame["stop_id"] == stopId:
      return true
  false

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0: quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let prompt = clipRunes(getEnv("PLAYER_PROMPT").strip(), 4000)
  let scriptedName = getEnv("PLAYER_SCRIPTED").strip()
  let scripted = prompt.strip().len == 0 or scriptedName.len > 0
  let policy = cleanLine(getEnv("PLAYER_POLICY_LABEL",
    if scripted: "scripted:" & (if scriptedName.len > 0: scriptedName else: "dispatcher")
    else: "prompt"), MaxPolicyRunes)
  if policy.len == 0: raise newException(GridlockError, "registered policy label must be nonempty")
  let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200"))
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    raise newException(GridlockError, "player timeout must be finite and positive")
  let started = getMonoTime()
  let playerDeadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connection = connectNativeWebSocket(url,
    min(playerDeadline, started + initDuration(seconds = 30)), 16 * 1024 * 1024)
  case connection.kind
  of wsInterrupted, wsDeadline: quit(0)
  of wsReady: discard
  else: raise newException(GridlockError, "native player connection failed")
  var socket = connection.socket
  var decisionId = newJNull()
  var welcomed = false
  var acknowledged = false
  var finalDeadline: MonoTime
  var cleanupBudgetMs = 0
  var cleanupStarted = false
  try:
    while true:
      if workerCreated and workerFinished.load(): joinWorker()
      if interruptionRequested() and not acknowledged:
        finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
        cleanupStarted = true
        acknowledged = stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
        break
      if getMonoTime() >= playerDeadline: break
      let received = socket.receiveNativeText(min(playerDeadline,
        getMonoTime() + initDuration(milliseconds = 50)))
      case received.kind
      of wsDeadline, wsInterrupted: continue
      of wsClosed: break
      of wsMessage: discard
      else: raise newException(GridlockError, "native player socket failed")
      let payload = parseJson(received.data)
      case payload["type"].getStr()
      of "welcome":
        if welcomed: raise newException(GridlockError, "duplicate player welcome")
        if payload["protocol"].getStr() != PlayerProtocol:
          raise newException(GridlockError, "unexpected player protocol")
        welcomed = true
        let registered = socket.sendNativeText($(%*{"type": "register",
          "kind": (if scripted: "scripted" else: "prompt"),
          "scripted": (if scripted: %(if scriptedName.len > 0: scriptedName else: "dispatcher") else: newJNull()),
          "prompt": prompt, "policy": policy}), playerDeadline)
        if registered.kind != wsReady:
          raise newException(GridlockError, "player registration was not delivered")
        echo "gridlock player: seated at slot ", payload["slot"].getInt()
      of "decision":
        if not welcomed or acknowledged or scripted:
          raise newException(GridlockError, "decision received outside registered model ownership")
        if payload["protocol"].getStr() != PlayerProtocol:
          raise newException(GridlockError, "unexpected player protocol")
        let receivedAt = getMonoTime()
        let budget = payload["transport"]["budget_ms"].getInt()
        if budget <= 0: raise newException(GridlockError, "decision transport budget must be positive")
        cleanupBudgetMs = payload["transport"]["cleanup_budget_ms"].getInt()
        if cleanupBudgetMs < 0: raise newException(GridlockError, "cleanup budget cannot be negative")
        let issuedId = payload["decision_id"]
        if issuedId.kind != JString or issuedId.getStr().len == 0:
          raise newException(GridlockError, "decision identity must be a nonempty string")
        joinWorker()
        # Preserve the previous operation's identity and final bytes when stop wins
        # while joining it. No new decision may clear that owned evidence.
        if interruptionRequested(): break
        decisionId = issuedId
        withLock evidenceLock: workerEvidence.setLen(0)
        workerFinished.store(false)
        createThread(worker, runDecision, PlayerCall(socket: socket.addr,
          decisionId: decisionId.getStr(), observation: $payload["observation"],
          prompt: prompt, policy: policy, slot: payload["slot"].getInt(),
          attempt: payload["attempt"].getInt(),
          deadline: min(playerDeadline, receivedAt + initDuration(milliseconds = budget))))
        workerCreated = true
      of "stop":
        finalDeadline = getMonoTime() + initDuration(milliseconds = payload["cleanup_budget_ms"].getInt())
        cleanupStarted = true
        acknowledged = stopAndAcknowledge(socket, payload["decision_id"], payload["stop_id"], finalDeadline)
        break  # Confirmed evidence delivery finishes this client's ownership.
      of "final":
        if not acknowledged:
          finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
          cleanupStarted = true
          acknowledged = stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
        break
      of "state", "turn", "evidence_received": discard
      else: raise newException(GridlockError, "unknown player frame")
  finally:
    requestNativeStop()
    joinWorker()
    if not cleanupStarted:
      finalDeadline = getMonoTime() + initDuration(milliseconds = cleanupBudgetMs)
      discard stopAndAcknowledge(socket, decisionId, newJNull(), finalDeadline)
    closeNativeWebSocket(socket)
