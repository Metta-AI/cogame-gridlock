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
## Player protocol (gridlock.player.v1), JSON text frames:
##   player -> game: {"type":"register","prompt":…,"scripted":…,"policy":…}
##   game -> player: {"type":"welcome",…}
##                   {"type":"turn","turn":N,"tick":T,"fleet":"Copper",
##                    "view":{…},"plan_source":"llm"}
##                   {"done":true,"result":{…}}
##
## Decisions are made HERE, not in the player container: the hosted Bedrock
## credentials are injected into the game pod, phase 60 greps the GAME log for
## `falling back`, and "one parallel batch per turn" is a game-server
## property. The player container is therefore thin.

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
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
  DoneBroadcastSeconds = 3.0

type
  GameState = object
    config: GameConfig
    game: Sim
    seats: Roster
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
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

proc declarePlayerFailure*(slot: int, message: string) =
  ## Charged to the lowest offending slot only; best-effort, and a no-op
  ## outside the platform.
  try:
    writeCogameEnv(
      "COGAME_PLAYER_FAILURE_URI",
      $(%*{"failed_policy_index": slot, "message": message}),
      "application/json")
  except CatchableError as error:
    logLine("player-failure declaration failed: ", error.msg)

proc seatRequestsLocked(gs: GameState): array[Seats, SeatRequest] =
  for slot in 0 ..< Seats:
    result[slot] = SeatRequest(
      prompt: gs.seats.seats[slot].prompt,
      viewJson: $buildView(gs.game, slot),
      baseline: baselineInput(gs.game, slot),
      scripted: effectiveScript(gs.seats.seats[slot]),
      previous: gs.game.plans[slot])

proc applyDecision(gs: var GameState, decision: TurnDecision, turn: int) =
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

proc finishEpisode(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    var results: JsonNode
    var replayData: string
    withLock stateLock:
      if appState.finished:
        return
      appState.finished = true
      if not appState.game.finished:
        endEpisode(appState.game, "complete", "full_time")
      results = resultsJson(appState.game)
      replayData = replayBytes(appState.game, results)
      ## Broadcast `done` to every seat BEFORE writing artifacts: the hosted
      ## worker tears player pods down as soon as results.json exists.
      let payload = $ %*{"done": true, "result": results}
      for _, socket in appState.playerSockets:
        socket.send(payload)
      appState.broadcastLocked()
    sleep(int(DoneBroadcastSeconds * 1000.0))
    logLine("writing replay and results")
    try:
      if runtimeConfig.replayUri.len > 0:
        runtimeConfig.writeReplay(replayData)
    except CatchableError as error:
      logLine("replay write failed: ", error.msg)
    try:
      if runtimeConfig.resultsUri.len > 0:
        runtimeConfig.writeResults($results & "\n")
    except CatchableError as error:
      logLine("results write failed: ", error.msg)
    logLine("episode complete: reason=", results{"reason"}.getStr(),
      " scores=", $results{"scores"})
    ## Keep /healthz and /global answering through the grace, then exit.
    sleep(int(ShutdownGraceSeconds * 1000.0))
    quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let cfg = appState.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + cfg.playerConnectTimeoutSeconds
    while epochTime() < connectDeadline:
      var connected = 0
      withLock stateLock:
        connected = appState.playerSockets.len
      if connected >= Seats:
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
        "baseline and the match continues")

    let client = newLlmClient(cfg.maxOutputTokens, cfg.model)
    var guarded = false
    let turns = turnsPerEpisode(cfg)

    for turn in 0 ..< turns:
      var done = false
      withLock stateLock:
        done = appState.game.finished or appState.game.tick >= cfg.episodeTicks
      if done:
        break
      let turnStart = epochTime()
      let elapsed = turnStart - gameStart
      ## Budget guard: settle early rather than overrun. Switching to the
      ## scripted layer costs microseconds a turn, so the episode ends
      ## complete/full_time instead of deadline.
      if not guarded and budgetGuardEngaged(elapsed, cfg.turnBudgetSeconds,
          cfg.wallClockBudgetSeconds):
        guarded = true
        client.disabled = true
        withLock stateLock:
          appState.game.events.add(newEvent(seBudgetGuard, appState.game.tick,
            turn, %*{"remaining_s": cfg.wallClockBudgetSeconds - elapsed}))
          for slot in 0 ..< Seats:
            inc appState.game.fallbackCauses[slot][fcBudgetGuard]
        logLine("budget guard engaged at turn ", turn, " (",
          int(elapsed), "s elapsed)")

      var requests: array[Seats, SeatRequest]
      withLock stateLock:
        requests = seatRequestsLocked(appState)
      var wantedLlm = false
      for slot in 0 ..< Seats:
        if requests[slot].scripted == skNone:
          wantedLlm = true

      ## The slow part — ONE parallel batch over every open seat — runs
      ## outside the lock; only this thread mutates the sim, so the snapshot
      ## cannot go stale.
      let decision = client.decideAll(requests)

      var failure = ""
      withLock stateLock:
        applyDecision(appState, decision, turn)
        failure = runTurn(appState.game, decision.plans)
        appState.broadcastLocked()
        for slot, socket in appState.playerSockets:
          socket.send(turnFrame(appState.game, slot))
      if failure.len > 0:
        logLine("sim fault: ", failure)
        withLock stateLock:
          endEpisode(appState.game, "fault", "sim_fault", failure)
        break

      if epochTime() - gameStart > cfg.wallClockBudgetSeconds:
        logLine("wall-clock budget reached; ending at tick ",
          appState.game.tick)
        withLock stateLock:
          endEpisode(appState.game, "deadline", "wall_clock")
        break

      ## Sidecar rate floor: 4 requests per batch against a 30 req/min cap
      ## means batches must start at least 8 s apart; gridlock floors the
      ## spacing at minTurnSpacingSeconds.
      if wantedLlm and not client.disabled and
          cfg.minTurnSpacingSeconds > 0.0:
        let rest = spacingRemaining(epochTime() - turnStart,
          cfg.minTurnSpacingSeconds)
        if rest > 0.0:
          sleep(int(rest * 1000.0))

    finishEpisode(runtimeConfig)

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
      duplicate = authorized and appState.playerSockets.hasKey(slot)
    if not authorized:
      request.respond(403)
      return
    if duplicate:
      request.respond(409)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
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
        withLock stateLock:
          appState.seats.applyRegistration(slot, payload)
          appState.game.policyKinds[slot] =
            policyKindOf(appState.seats.seats[slot])
          logLine("slot ", slot, " registered (",
            appState.game.policyKinds[slot], ")")
      except CatchableError as error:
        logLine("ignoring bad player frame: ", error.msg)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in appState.socketSlots:
          let slot = appState.socketSlots[websocket]
          appState.socketSlots.del(websocket)
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
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  logLine("replay mode on ", runtimeConfig.host, ":", runtimeConfig.port)
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(gameConfig: GameConfig, spec: CitySpec,
    runtimeConfig: RuntimeConfig) =
  if gameConfig.tokens.len != gameConfig.players.len:
    raise newException(GridlockError, "tokens and players must align")
  validate(gameConfig)
  appState.config = gameConfig
  appState.game = initSim(gameConfig, spec)
  appState.game.keepSnapshots = false
  appState.seats = initRoster(gameConfig.tokens)
  ## Bake before listening so a viewer's first frame is instant.
  appState.metaPayload = $metaJson(appState.game, newJObject())
  appState.refreshPayloadsLocked()
  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  logLine("serving on ", runtimeConfig.host, ":", runtimeConfig.port)
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
