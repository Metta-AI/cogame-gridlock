## The gridlock game server: the Coworld game contract over mummy.
##
## Routes:
##   GET /healthz                      liveness (answers through the grace)
##   GET /client/global                spectator page   (real page, no socket)
##   GET /client/player                player page      (real page, NEVER
##                                     opens the player socket)
##   GET /client/replay                replay page (replay mode)
##   GET /client/asset/<name>          chrome js/css and art
##   GET /replay-data                  the replay bytes (replay mode)
##   WS  /player?slot=N&token=T        player protocol
##   WS  /global                       spectator snapshots
##
## Player protocol (gridlock.player.v3), private JSON text frames:
##   player -> game: {"type":"register","kind":…,"scripted":…,"policy":…}
##   game -> player: {"type":"welcome",…}
##                   {"type":"decision","decision_id":"issued","observation":{…},…}
##   player -> game: {"type":"action","decision_id":"issued","action":{…},…}
##                   {"type":"turn","turn":N,"tick":T,"fleet":"Carbon",
##                    "view":{…},"plan_source":"llm"}
##                   stop -> joined stopped -> evidence_received -> final
##
## The game owns shared deadlines, validation, fallback, and replay. Model
## calls and candidate ranking run only in the player container.

import std/[base64, json, locks, monotimes, options, os, sets, sysrand, strutils, tables, times]
import bitworld/[runtime, decision_trajectory, native_stop, artifact_runtime]
import mummy
import mummy/routers
import types
import config
import city
import rules
import events
import state
import view
import baselines
import roster
import decision
import llm
import startup
import wire_constants
import render
import replay
import sim

const
  ShutdownGraceSeconds = 20.0
    ## /healthz and /global keep answering this long after the artifacts are
    ## written: the cert runner pings /global with a 2 s deadline AFTER the
    ## player pods start, and a short episode would otherwise already be gone
    ## (playbook gotcha, lantern 0.1.3).

type
  PendingRecord = object
    id, seat: string
    observation: JsonNode
    attempts: seq[DecisionAttempt]
    selected: Option[string]
    action: JsonNode
    terminal: bool
    fallback: Option[string]

  GameState = object
    config: GameConfig
    game: Sim
    seats: Roster
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    actionReplies: Table[int, string]
    issuedSeats: Table[string, int]
    issuedPrompts: Table[string, JsonNode]
    issuedObservations: Table[string, JsonNode]
    issuedAt: Table[string, MonoTime]
    issuedDeadline: Table[string, MonoTime]
    startedAttempts: Table[string, JsonNode]
    completedAttempts: Table[string, JsonNode]
    latestDecisions: Table[int, string]
    records: seq[PendingRecord]
    stoppedSlots: HashSet[int]
    stopping: bool
    stopId: string
    stopIssuedAt, acknowledgementDeadline: MonoTime
    trajectory: DecisionTrajectory
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool
    metaPayload: string
    framePayload: string
    eventCursor: int

var
  stateLock: Lock
  appState: GameState
  gameServer: Server
  replayPayloadGlobal: string
  replayMetaGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc assetDirs(): seq[string] =
  let appDir = getAppDir()
  @[clientDir(), clientDir() / "art", cityDataDir(),
    appDir / "replay-viewer", appDir / ".." / "replay-viewer",
    "replay-viewer"]

# ---------------------------------------------------------------------------
# Broadcast.
# ---------------------------------------------------------------------------

proc refreshPayloadsLocked(gs: var GameState) =
  gs.framePayload = $frameJson(gs.game, gs.eventCursor)
  gs.eventCursor = gs.game.events.len

proc broadcastLocked(gs: var GameState) =
  refreshPayloadsLocked(gs)
  if gs.globalSockets.len == 0:
    return
  for socket in gs.globalSockets:
    socket.send(gs.framePayload)

proc turnFrame(game: Sim, slot: int): string =
  let depot = game.seatDepot[slot]
  $ %*{
    "type": "turn",
    "turn": game.turn,
    "tick": game.tick,
    "fleet": FleetAliases[depot],
    "view": buildView(game, slot),
    "plan_source": $game.plans[slot].source}

# ---------------------------------------------------------------------------
# The turn loop.
# ---------------------------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string, deadline: MonoTime) =
  if uri.len == 0: return
  let httpMethod = case getEnv(methodEnv, "PUT").toUpperAscii()
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(GridlockError, "unsupported artifact method")
  writeCogameArtifact(uri, data, contentType, methodEnv, deadline, httpMethod)

proc declarePlayerFailure*(slot: int, message: string, deadline: MonoTime) =
  let destination = getEnv("COGAME_PLAYER_FAILURE_URI")
  writeArtifact(destination, $(%*{"failed_policy_index": slot, "message": message}),
    "application/json", "COGAME_PLAYER_FAILURE_METHOD", deadline)

proc seatRequestsLocked(gs: GameState): array[Seats, SeatSnapshot] =
  for slot in 0 ..< Seats:
    let view = buildView(gs.game, slot)
    result[slot] = SeatSnapshot(
      view: view,
      prompt: gs.seats.seats[slot].prompt,
      baseline: baselineInput(view),
      scripted: effectiveScriptNow(gs.seats.seats[slot]),
      previous: gs.game.plans[slot])

proc applyDecision(gs: var GameState, decision: PlayerDecision, turn: int) =
  ## `turn` is the turn these plans are FOR. `sim.turn` still holds the
  ## previous turn's index here: it is only assigned in `installPlans`, which
  ## `runTurn` calls after this, so reading it would date every fallback one
  ## turn early.
  for record in decision.fallbacks:
    inc gs.game.fallbackCauses[record.seat][record.cause]
    gs.game.events.add(newEvent(seFallback, gs.game.tick, turn, %*{
      "seat": record.seat,
      "attempt": record.attempt,
      "cause": $record.cause,
      "detail": record.detail}))
  for slot in 0 ..< Seats:
    if decision.plans[slot].source == psFallback:
      inc gs.game.fallbackTurns[slot]

proc retainExternalAttempt(gs: var GameState, seat: int, id: string,
    evidence: JsonNode, completed: bool) =
  if not gs.issuedSeats.hasKey(id) or gs.issuedSeats[id] != seat:
    raise newException(GridlockError, "attempt does not belong to authenticated issued seat")
  let attempt = readAttemptEvidence(evidence)
  if attempt.attemptId != id & "-model" or attempt.origin != aoModel:
    raise newException(GridlockError, "external attempt must identify its issued model call")
  if attempt.policy != gs.seats.seats[seat].policyLabel:
    raise newException(GridlockError, "native attempt differs from its frozen registered policy")
  let prompt = gs.issuedPrompts[id]
  if attempt.prompt != prompt or attempt.request.kind != JObject or
      attempt.request["system"] != prompt[0]["content"] or
      attempt.request["messages"] != %*[prompt[1]]:
    raise newException(GridlockError, "model call rewrites the exact private prompt")
  if not gs.startedAttempts.hasKey(id):
    if completed:
      raise newException(GridlockError, "completed model evidence lacks pre-request start")
    if attempt.response.kind != JNull or attempt.rawResponse.kind != JNull or
        attempt.platformCallId.isSome or attempt.providerRequestId.isSome or
        attempt.responseHeaders.isSome or attempt.responseHeadersB64.isSome or
        attempt.responseBodyB64.isSome or attempt.responseComplete.isSome or
        attempt.responseReaderJoined.isSome or attempt.httpStatus.isSome or
        attempt.latencyMs.isSome or attempt.inputTokens.isSome or attempt.outputTokens.isSome or
        attempt.promptTokenIds.isSome or attempt.sampledTokenIds.isSome or
        attempt.behaviorLogprobs.isSome or attempt.stopReason.isSome or attempt.rejectionReason.isSome or
        attempt.modelIdentity.isSome or attempt.tokenizerIdentity.isSome or attempt.chatTemplateSha256.isSome:
      raise newException(GridlockError, "first model start must precede observed response facts")
  else:
    let before = gs.startedAttempts[id]
    if (before["latency_ms"].kind != JNull or before["response_reader_joined"] == %true) and evidence != before:
      raise newException(GridlockError, "finished native attempt evidence is immutable")
    for key in ["prompt", "request", "decoder", "policy"]:
      if evidence[key] != before[key]:
        raise newException(GridlockError, "started model request evidence is immutable")
    for key in ["response_body_b64", "response_headers_b64"]:
      if before[key].kind != JNull:
        if evidence[key].kind != JString or
            not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr())):
          raise newException(GridlockError, "received native bytes cannot be rewritten")
    if before["response_complete"] == %true and
        (evidence["response_complete"] != %true or evidence["response_body_b64"] != before["response_body_b64"] or
          evidence["response_headers_b64"] != before["response_headers_b64"]):
      raise newException(GridlockError, "complete native response cannot be rewritten")
    for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
        "model_identity", "tokenizer_identity", "chat_template_sha256"]:
      if before[key].kind != JNull and evidence[key] != before[key]:
        raise newException(GridlockError, "received native identity cannot be rewritten")
  if gs.completedAttempts.hasKey(id) and evidence != gs.completedAttempts[id]:
    raise newException(GridlockError, "completed native evidence is immutable")
  gs.startedAttempts[id] = copy(evidence)
  if completed: gs.completedAttempts[id] = copy(evidence)
proc exchangeDecisions(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.gcsafe.} =
  result = newSeq[string](requests.len)
  {.gcsafe.}:
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    withLock stateLock:
      for request in requests:
        let slot = request["slot"].getInt()
        let id = request["decision_id"].getStr()
        appState.issuedSeats[id] = slot
        appState.issuedObservations[id] = copy(request["observation"])
        appState.issuedAt[id] = getMonoTime()
        appState.issuedDeadline[id] = deadline
        appState.latestDecisions[slot] = id
        appState.issuedPrompts[id] = %*[
          {"role": "system", "content": SystemPrompt},
          {"role": "user", "content": userMessage(SeatRequest(
            prompt: request["prompt"].getStr(), viewJson: $request["observation"]),
            request["attempt"].getInt() > 1)}]
        appState.actionReplies.del(slot)
        if appState.playerSockets.hasKey(slot):
          appState.playerSockets[slot].send($request)
    while getMonoTime() < deadline and not interruptionRequested():
      var pending = false
      withLock stateLock:
        for position, request in requests:
          if result[position].len > 0: continue
          let slot = request["slot"].getInt()
          if appState.actionReplies.hasKey(slot):
            result[position] = appState.actionReplies[slot]
            appState.actionReplies.del(slot)
          elif appState.playerSockets.hasKey(slot): pending = true
      if not pending: break
      sleep(10)
    withLock stateLock:
      for position, request in requests:
        let id = request["decision_id"].getStr()
        let slot = request["slot"].getInt()
        # An on-time received action remains eligible after the wait loop expires.
        # Ingress already validates its immutable issued receipt window.
        if result[position].len == 0 and appState.actionReplies.hasKey(slot):
          result[position] = appState.actionReplies[slot]
          appState.actionReplies.del(slot)
        if result[position].len == 0 and appState.startedAttempts.hasKey(id):
          result[position] = $(%*{"type": "attempt_timeout",
            "training_attempt": appState.startedAttempts[id]})

proc waitUntil(deadline: MonoTime) =
  while getMonoTime() < deadline and not interruptionRequested(): sleep(10)

proc finishEpisode(runtimeConfig: RuntimeConfig, episodeDeadline: MonoTime, failed = false) =
  let cleanupDeadline = getMonoTime() + initDuration(seconds = 5)
  var interrupted = interruptionRequested() or failed
  var targets: seq[int]
  withLock stateLock:
    if appState.finished: return
    appState.stopping = true
    appState.stopId = ""
    for byte in urandom(16): appState.stopId.add(toHex(byte, 2).toLowerAscii())
    appState.stopIssuedAt = getMonoTime()
    appState.acknowledgementDeadline = min(cleanupDeadline, getMonoTime() + initDuration(seconds = 3))
    for slot in 0 ..< Seats:
      if appState.seats.seats[slot].registered and appState.seats.seats[slot].kind != pkScripted:
        targets.add(slot)
        if appState.playerSockets.hasKey(slot):
          appState.playerSockets[slot].send($(%*{"type": "stop", "stop_id": appState.stopId,
            "decision_id": (if appState.latestDecisions.hasKey(slot): %appState.latestDecisions[slot] else: newJNull()),
            "cleanup_budget_ms": max(0'i64, (appState.acknowledgementDeadline - getMonoTime()).inMilliseconds)}))
  while getMonoTime() < appState.acknowledgementDeadline:
    var joined = true
    withLock stateLock:
      for slot in targets: joined = joined and slot in appState.stoppedSlots
    if joined: break
    sleep(10)
  withLock stateLock:
    for slot in targets:
      if slot notin appState.stoppedSlots: interrupted = true
  var results, privateOutcome: JsonNode
  var replayData: string
  withLock stateLock:
    if appState.finished: return
    appState.finished = true
    if not appState.game.finished:
      if not interrupted and appState.game.tick >= appState.config.episodeTicks:
        endEpisode(appState.game, "complete", "full_time")
      else:
        endEpisode(appState.game, (if failed: "fault" else: "deadline"),
          (if failed: "runtime_failure" else: "interrupted_or_unresolved"))
    if resultsJson(appState.game)["reason"].getStr() != "complete": interrupted = true
    results = resultsJson(appState.game)
    var cleanup = newJObject()
    for slot in targets: cleanup[$slot] = %(if slot in appState.stoppedSlots: "joined" else: "unresolved")
    privateOutcome = copy(results)
    privateOutcome["engine_rules_version"] = %GameVersion
    privateOutcome["player_cleanup"] = cleanup
    replayData = replayBytes(appState.game, results)
    if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
      var represented = initHashSet[string]()
      for pending in appState.records:
        var attempts = pending.attempts
        for attempt in attempts.mitems:
          represented.incl(attempt.attemptId)
          for _, evidence in appState.startedAttempts:
            if evidence["attempt_id"] == %attempt.attemptId:
              let parsed = attempt.parsedAction
              let accepted = attempt.accepted
              let rejection = attempt.rejectionReason
              attempt = readAttemptEvidence(evidence)
              attempt.parsedAction = parsed
              attempt.accepted = accepted
              attempt.rejectionReason = rejection
        appState.trajectory.recordDecision(pending.id, pending.seat,
          pending.observation, attempts, pending.selected, pending.action,
          (if pending.selected.isSome: asAccepted else: asFallback), terminal = pending.terminal, fallbackOrigin = pending.fallback)
      for id, evidence in appState.startedAttempts:
        var attempt = readAttemptEvidence(evidence)
        if attempt.attemptId notin represented:
          attempt.rejectionReason = some("issued native attempt never reached an applied engine action")
          appState.trajectory.recordDecision(id, $appState.issuedSeats[id],
            appState.issuedObservations[id], @[attempt], none(string), newJNull(),
            asMissing, terminal = true)
      var outcomes = newJObject()
      for seat in 0 ..< Seats: outcomes[$seat] = results["scores"][seat]
      appState.trajectory.finish(
        if failed: esFailed
        elif not interrupted and appState.game.finished and results["reason"].getStr() == "complete":
          esCompleted else: esTruncated,
        privateOutcome, if interrupted: newJNull() else: outcomes)
    if not interrupted:
      let final = %*{"type": "final", "done": true, "result": results}
      for _, socket in appState.playerSockets: socket.send($final)
      appState.broadcastLocked()
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    let trajectoryMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
      of "PUT": ahPut
      of "POST": ahPost
      else: raise newException(ValueError, "unsupported artifact method")
    writeTrajectoryArtifact(appState.trajectory, getEnv(CogameSaveTrajectoryUriEnv), cleanupDeadline, trajectoryMethod)
  if interrupted: return
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json", "COGAME_RESULTS_METHOD", cleanupDeadline)
  writeArtifact(runtimeConfig.replayUri, replayData, "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline)
  waitUntil(min(episodeDeadline, getMonoTime() + initDuration(milliseconds = int(ShutdownGraceSeconds * 1000))))

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let cfg = appState.config
    let trajectoryUri = getEnv(CogameSaveTrajectoryUriEnv)
    let monoStart = getMonoTime()
    let episodeDeadline = monoStart + initDuration(nanoseconds = int64(cfg.wallClockBudgetSeconds * 1_000_000_000))
    var finalizationStarted = false
    defer:
      let wasInterrupted = interruptionRequested()
      requestNativeStop()
      if not finalizationStarted:
        finalizationStarted = true
        finishEpisode(runtimeConfig, episodeDeadline, failed = not wasInterrupted)
      gameServer.close()
    let connectDeadline = min(episodeDeadline, monoStart + initDuration(nanoseconds = int64(cfg.playerConnectTimeoutSeconds * 1_000_000_000)))
    while getMonoTime() < connectDeadline and not interruptionRequested():
      var ready = 0
      withLock stateLock:
        for slot in 0 ..< Seats:
          if appState.playerSockets.hasKey(slot) and
              appState.seats.seats[slot].registered:
            inc ready
      if ready >= Seats:
        break
      sleep(200)

    var missing = -1
    withLock stateLock:
      appState.started = true
      for slot in 0 ..< Seats:
        if not appState.seats.seats[slot].everConnected and missing < 0:
          missing = slot
        appState.game.policyKinds[slot] = policyKindOf(appState.seats.seats[slot])
      logLine("starting with ", appState.playerSockets.len, "/", Seats,
        " seats connected")
      appState.broadcastLocked()
    if missing >= 0:
      declarePlayerFailure(missing,
        "seat " & $missing & " never connected; it plays the dispatcher " &
        "baseline and the match continues",
        min(episodeDeadline, getMonoTime() + initDuration(seconds = 5)))

    var guarded = false
    let turns = turnsPerEpisode(cfg)

    for turn in 0 ..< turns:
      var done = false
      withLock stateLock:
        done = appState.game.finished or appState.game.tick >= cfg.episodeTicks
      if done or interruptionRequested() or getMonoTime() >= episodeDeadline:
        break
      let turnStart = getMonoTime()
      let elapsed = float((turnStart - monoStart).inNanoseconds) / 1_000_000_000.0
      ## Budget guard: settle early rather than overrun. Switching to the
      ## scripted layer costs microseconds a turn, so the episode ends
      ## complete/full_time instead of deadline.
      if not guarded and budgetGuardEngaged(elapsed, cfg.turnBudgetSeconds,
          cfg.wallClockBudgetSeconds):
        guarded = true
        withLock stateLock:
          appState.game.events.add(newEvent(seBudgetGuard, appState.game.tick,
            turn, %*{"remaining_s": cfg.wallClockBudgetSeconds - elapsed}))
          for slot in 0 ..< Seats:
            inc appState.game.fallbackCauses[slot][fcBudgetGuard]
        logLine("budget guard engaged at turn ", turn, " (",
          int(elapsed), "s elapsed)")

      var requests: array[Seats, SeatSnapshot]
      withLock stateLock:
        requests = seatRequestsLocked(appState)
      var wantedLlm = false
      for slot in 0 ..< Seats:
        if requests[slot].scripted == skNone:
          wantedLlm = true

      ## The slow part runs outside the lock. Every model seat receives the
      ## same pre-action snapshot before the shared deadline starts.
      let decision = decidePlayers(requests, turn, guarded,
        cfg.turnBudgetSeconds, exchangeDecisions)

      if interruptionRequested(): break
      var failure = ""
      withLock stateLock:
        applyDecision(appState, decision, turn)
        let startTick = appState.game.tick
        failure = runTurn(appState.game, decision.plans)
        if trajectoryUri.len > 0:
          for slot in 0 ..< Seats:
            let selected = decision.selectedAttemptIds[slot]
            var attempts = decision.attempts[slot]
            var selectedApplied = selected
            let installed = planJson(appState.game.plans[slot])
            if selected.isSome:
              for attempt in attempts.mitems:
                if attempt.attemptId == selected.get() and attempt.parsedAction != installed:
                  attempt.accepted = false
                  attempt.rejectionReason = some("engine installation changed the proposed action")
                  selectedApplied = none(string)
            appState.records.add(PendingRecord(id: $startTick & "-" & $slot,
              seat: $slot, observation: requests[slot].view, attempts: attempts,
              selected: selectedApplied, action: installed,
              terminal: appState.game.tick >= cfg.episodeTicks,
              fallback: (if selectedApplied.isSome: none(string)
                else: some("engine-" & $appState.game.plans[slot].source))))
        appState.broadcastLocked()
        for slot, socket in appState.playerSockets:
          socket.send(turnFrame(appState.game, slot))
      if failure.len > 0:
        logLine("sim fault: ", failure)
        withLock stateLock:
          endEpisode(appState.game, "fault", "sim_fault", failure)
        break

      if getMonoTime() >= episodeDeadline:
        logLine("wall-clock budget reached; ending at tick ",
          appState.game.tick)
        withLock stateLock:
          endEpisode(appState.game, "deadline", "wall_clock")
        break

      ## Sidecar rate floor: up to four player calls per turn against a
      ## 30 req/min cap. Keep turns at least minTurnSpacingSeconds apart.
      if wantedLlm and not guarded and cfg.minTurnSpacingSeconds > 0.0:
        let rest = spacingRemaining(float((getMonoTime() - turnStart).inNanoseconds) / 1_000_000_000.0,
          cfg.minTurnSpacingSeconds)
        if rest > 0.0:
          waitUntil(min(episodeDeadline, getMonoTime() + initDuration(nanoseconds = int64(rest * 1_000_000_000))))

    finalizationStarted = true
    finishEpisode(runtimeConfig, episodeDeadline)

var gameThread: Thread[RuntimeConfig]

# ---------------------------------------------------------------------------
# HTTP.
# ---------------------------------------------------------------------------

proc contentTypeFor(name: string): string =
  if name.endsWith(".js"): "text/javascript; charset=utf-8"
  elif name.endsWith(".css"): "text/css; charset=utf-8"
  elif name.endsWith(".html"): "text/html; charset=utf-8"
  elif name.endsWith(".json"): "application/json; charset=utf-8"
  elif name.endsWith(".png"): "image/png"
  elif name.endsWith(".jpg"): "image/jpeg"
  elif name.endsWith(".ttf"): "font/ttf"
  else: "application/octet-stream"

proc serveText(request: Request, body, contentType: string) =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  request.respond(200, headers, body)

proc splicePage(body: string): string =
  ## The same three markers `Dockerfile.replay-viewer` splices for the static
  ## bundle, pointed at the served copies instead.
  body.replace(WireConstantsMarker,
      "<script>" & WireConstantsJs & "</script>")
    .replace("<!-- CHROME_COMMON -->",
      "<script src=\"/client/asset/chrome_common.js\"></script>")
    .replace("<!-- BROADCAST_CORE -->",
      "<script src=\"/client/asset/static_replay.js\"></script>")

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      let path = clientDir() / name
      if fileExists(path):
        serveText(request, splicePage(readFile(path)),
          "text/html; charset=utf-8")
      else:
        serveText(request, "<!doctype html><title>gridlock</title>" &
          "<h1>gridlock</h1><p>" & name & " is not bundled in this image.</p>",
          "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    for dir in assetDirs():
      let path = dir / name
      if fileExists(path):
        var headers: HttpHeaders
        headers["Content-Type"] = contentTypeFor(name)
        request.respond(200, headers, readFile(path))
        return
    request.respond(404)

proc healthzHandler(request: Request) {.gcsafe.} =
  serveText(request, """{"ok": true}""", "application/json")

proc metaHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var payload = ""
    withLock stateLock:
      payload = appState.metaPayload
    if payload.len == 0:
      payload = replayMetaGlobal
    serveText(request, payload, "application/json")

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayloadGlobal.len == 0:
      request.respond(404)
    else:
      serveText(request, replayPayloadGlobal, "application/json")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var slot = -1
    try:
      slot = parseInt(request.queryParams["slot"])
    except ValueError:
      discard
    let token = request.queryParams["token"]
    var authorized = false
    var duplicate = false
    withLock stateLock:
      authorized = appState.seats.authorize(slot, token)
      duplicate = authorized and (appState.started or appState.stopping or appState.finished or appState.playerSockets.hasKey(slot))
    if not authorized:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    withLock stateLock:
      if appState.started or appState.stopping or appState.finished or appState.playerSockets.hasKey(slot):
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      appState.playerSockets[slot] = websocket
      appState.socketSlots[websocket] = slot
      appState.seats.seats[slot].connected = true
      appState.seats.seats[slot].everConnected = true
      let depot = appState.game.seatDepot[slot]
      websocket.send($ %*{
        "type": "welcome",
        "protocol": PlayerProtocol,
        "slot": slot,
        "fleet": FleetAliases[depot],
        "colour": FleetColours[depot],
        "turns": turnsPerEpisode(appState.config),
        "turn_seconds": appState.config.turnTicks div TargetFps})
    logLine("player slot ", slot, " connected")

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      appState.globalSockets.incl(websocket)
      if appState.metaPayload.len > 0:
        websocket.send(appState.metaPayload)
      elif replayMetaGlobal.len > 0:
        websocket.send(replayMetaGlobal)
      if appState.framePayload.len > 0:
        websocket.send(appState.framePayload)

proc websocketHandler(websocket: WebSocket, event: WebSocketEvent,
    message: Message) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      let receivedAt = getMonoTime()
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = appState.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload["type"].getStr() == "register":
          withLock stateLock:
            if appState.started or appState.stopping or appState.finished or appState.seats.seats[slot].registered:
              raise newException(GridlockError, "policy registration is frozen")
            appState.seats.applyRegistration(slot, payload)
            appState.game.policyKinds[slot] = policyKindOf(appState.seats.seats[slot])
        elif payload["type"].getStr() in ["attempt_started", "action"]:
          let id = payload["decision_id"].getStr()
          withLock stateLock:
            if appState.finished: return
            if appState.seats.seats[slot].kind == pkScripted or
                not appState.issuedSeats.hasKey(id) or appState.issuedSeats[id] != slot or
                receivedAt < appState.issuedAt[id]:
              raise newException(GridlockError, "decision does not belong to authenticated issued seat")
            if payload["type"].getStr() == "attempt_started":
              appState.retainExternalAttempt(slot, id, payload["training_attempt"], completed = false)
              return
            let evidence = payload["training_attempt"]
            let source = payload["source"].getStr()
            if evidence.kind != JNull:
              appState.retainExternalAttempt(slot, id, evidence, completed = true)
            elif source == "llm":
              raise newException(GridlockError, "model action requires native evidence")
            if appState.stopping or interruptionRequested() or
                appState.latestDecisions[slot] != id or
                receivedAt > appState.issuedDeadline[id] or appState.actionReplies.hasKey(slot): return
            appState.actionReplies[slot] = message.data
        elif payload["type"].getStr() == "stopped":
          withLock stateLock:
            if appState.finished: return
            if appState.seats.seats[slot].kind == pkScripted or payload["worker_status"].getStr() notin ["joined", "no_active_call"] or
                payload["attempts"].kind != JArray:
              raise newException(GridlockError, "stop must carry its authenticated worker status and attempts")
            let id = payload["decision_id"]
            if id.kind == JString:
              if not appState.issuedSeats.hasKey(id.getStr()) or appState.issuedSeats[id.getStr()] != slot or
                  receivedAt < appState.issuedAt[id.getStr()]:
                raise newException(GridlockError, "stop evidence does not belong to authenticated issued seat")
              for evidence in payload["attempts"]:
                appState.retainExternalAttempt(slot, id.getStr(), evidence, completed = false)
            elif id.kind != JNull or payload["attempts"].len != 0:
              raise newException(GridlockError, "stop without issued decision cannot assert model attempts")
            if appState.playerSockets.hasKey(slot) and appState.playerSockets[slot] == websocket:
              websocket.send($(%*{"type": "evidence_received", "decision_id": id, "stop_id": payload["stop_id"]}))
            let latest = if appState.latestDecisions.hasKey(slot): %appState.latestDecisions[slot] else: newJNull()
            if not appState.stopping or id != latest or receivedAt < appState.stopIssuedAt or
                receivedAt > appState.acknowledgementDeadline or payload["stop_id"] != %appState.stopId:
              raise newException(GridlockError, "stop acknowledgement differs from issued cleanup window")
            for evidence in payload["attempts"]:
              if readAttemptEvidence(evidence).responseReaderJoined != some(true):
                raise newException(GridlockError, "stop retains an unjoined native reader")
            for issued, known in appState.startedAttempts:
              if appState.issuedSeats[issued] == slot and readAttemptEvidence(known).responseReaderJoined != some(true):
                raise newException(GridlockError, "stop omitted an unjoined issued native reader")
            appState.stoppedSlots.incl(slot)
      except CatchableError as error:
        logLine("ignoring bad private player frame")
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in appState.socketSlots:
          let slot = appState.socketSlots[websocket]
          appState.seats.seats[slot].connected = false
          if appState.playerSockets.getOrDefault(slot) == websocket:
            appState.playerSockets.del(slot)
        appState.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## The two /client/ pages are registered FIRST and neither opens the player
  ## socket: the episode runner probes both before starting player pods and a
  ## 404 there is a game_contract_violation (playbook gotcha, lantern 0.1.1).
  result.get("/healthz", healthzHandler)
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/asset/@name", assetHandler)
  result.get("/meta", metaHandler)
  result.get("/global", globalUpgradeHandler)
  if replayMode:
    result.get("/replay-data", replayDataHandler)
  else:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  let data = parseReplayBytes(runtimeConfig.replay)
  var player = initReplayRuntime(data)
  replayPayloadGlobal = runtimeConfig.replay
  replayMetaGlobal = $metaJson(player.sim, data.results)
  appState.config = data.config
  appState.game = player.sim
  appState.seats = initRoster(@[])
  appState.actionReplies = initTable[int, string]()
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  logLine("replay mode on ", runtimeConfig.host, ":", runtimeConfig.port)
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(gameConfig: GameConfig, spec: CitySpec,
    runtimeConfig: RuntimeConfig) =
  if gameConfig.tokens.len != gameConfig.players.len:
    raise newException(GridlockError, "tokens and players must align")
  validate(gameConfig)
  appState.config = gameConfig
  appState.game = initSim(gameConfig, spec)
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    appState.trajectory = newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
      "gridlock-" & $gameConfig.seed, "gridlock", getEnv("COWORLD_GAME_VERSION"),
      getEnv("COWORLD_SOURCE_REVISION"))
  appState.game.keepSnapshots = false
  appState.seats = initRoster(gameConfig.tokens)
  appState.actionReplies = initTable[int, string]()
  ## Bake before listening so a viewer's first frame is instant.
  appState.metaPayload = $metaJson(appState.game, newJObject())
  appState.refreshPayloadsLocked()
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  installNativeStopHandlers()
  var ownerCreated = false
  logLine("serving on ", runtimeConfig.host, ":", runtimeConfig.port)
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(gameThread, runGame, runtimeConfig)
          ownerCreated = true)
  finally:
    let wasInterrupted = interruptionRequested()
    requestNativeStop()
    if ownerCreated: joinThread(gameThread)
    else: finishEpisode(runtimeConfig, getMonoTime() + initDuration(seconds = 5), failed = not wasInterrupted)
