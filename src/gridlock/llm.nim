## Claude-backed decision making for gridlock. A policy is just a prompt: the
## game server composes the seat's view plus that seat's PLAYER_PROMPT and
## asks the model for one ROUTING PLAN.
##
## Gridlock is a SIMULTANEOUS-decision game, so all four seats' calls go out
## as ONE parallel batch per turn (`curly.makeRequests`) — never sequentially.
## Every turn batches exactly four requests and at most four are ever in
## flight. First attempt 14 s; on timeout / transport error / non-JSON / no
## usable plan, ONE retry at 6 s with a hint; then the `dispatcher` scripted
## plan and a `fallback` record. Worst case 14 + 6 = 20 s inside the 22 s
## per-turn budget.
##
## Credentials, in order: Bedrock sidecar -> ANTHROPIC_API_KEY ->
## ANTHROPIC_API_KEY_URI -> none (disabled, instant fallback, one log line).
## With no credentials at all the whole episode finishes on the scripted
## layer, which is what makes offline certification and the docker smoke work.

import std/[json, os, strutils, times]
import bitworld/runtime
import curly
import types
import plan
import baselines
import view
import state

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  FirstAttemptSeconds* = 14
  RetryAttemptSeconds* = 6

const SystemPrompt* = """
You are the dispatcher for one parcel fleet of 50 vans in a city shared with three
rival fleets. The city is a 9x9 grid of intersections joined by two-way roads. Every
road holds at most 14 vans per direction. Every intersection runs a fixed 4-second
light: 2 seconds north-south, 2 seconds east-west, offset diagonally across the city.
Nobody controls the lights. A green approach lets through 1 van per service tick, or
2 on an arterial (the roads on grid lines 2, 4 and 6). If the road a van wants to enter
is FULL, it cannot cross, so it sits in the intersection mouth and the queue behind it
backs up. That is how a jam spreads.
Your depot sits in one corner. Vans load a parcel, drive to its address, drop it, and
come back for the next. One delivered parcel is one point. Your score is your own
deliveries - it is NOT a share, so nothing stops all four fleets from scoring badly at
once. That is the trap: the shortest route is the same shortest route everyone else
computed, and four fleets flooding the arterials deliver fewer parcels between them
than four fleets that spread out and meter themselves.
Every 10 seconds you set your fleet's ROUTING PLAN: how much your vans inflate the cost
of a queued road, how full a road must be before they re-plan at an intersection, how
many vans you allow on the road at once, how staggered their departures are, which
district they should prefer or avoid, and which parcel they take next. That is all.
You cannot steer one van, change a light, or talk to another fleet.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"congestion_weight":0-100, // how strongly a queued road is avoided when planning
 "patience":0-100,          // how full the next road must be before a van re-plans
 "dispatch":0-100,          // percent of your 50 vans allowed on the road at once
 "spread":0-100,            // 0 = release in bursts of 6, 100 = release one at a time
 "corridor":[bx,by]|null,   // district (0-2,0-2) your vans should prefer to route through
 "avoid":[bx,by]|null,      // district your vans should route around
 "priority":"near"|"far"|"fifo", // which waiting parcel a van loads next
 "note":"<=140 chars",      // your reasoning, shown to spectators only
 "say":"<=32 chars"}        // one short line, shown to spectators only
Districts are the 3x3 blocks of the node grid: [0,0] is NW, [1,1] is CENTRE, [2,2] is SE.
congestion_weight 0 is pure shortest path - fast when the city is empty, and the fastest
way to build a jam when it is not. dispatch below 100 is the only way to reduce total
traffic; it costs you deliveries in the short run and buys a moving city back.
"""

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmRequest* = object
    seat*: int
    url*: string
    body*: string

  LlmReply* = object
    seat*: int
    text*: string
    error*: string

  BatchProc* = proc (requests: seq[LlmRequest], timeoutSeconds: int):
    seq[LlmReply] {.closure.}
    ## Test seam only. Deliberately NOT gcsafe: a test closure records the
    ## in-flight window of every seat in a batch, which needs captured state,
    ## and the production path never installs one — the server's turn loop
    ## already runs inside a `{.gcsafe.}:` block.

  FallbackRecord* = object
    seat*: int
    attempt*: int
    cause*: FallbackCause
    detail*: string

  SeatRequest* = object
    ## Everything one seat needs for one turn, snapshotted out of the sim so
    ## the slow part runs without the state lock.
    prompt*: string
    viewJson*: string
    baseline*: BaselineInput
    scripted*: ScriptKind
    previous*: RoutingPlan

  TurnDecision* = object
    plans*: array[Seats, RoutingPlan]
    fallbacks*: seq[FallbackRecord]
    llmSeats*: int

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    batchOverride*: BatchProc
      ## Test seam: when set, decideAll drives this instead of libcurl, so
      ## tests can observe the in-flight window of every seat in a batch.

proc resolveApiKey(): string =
  result = strutils.strip(getEnv("ANTHROPIC_API_KEY"))
  if result.len > 0:
    return
  let uri = strutils.strip(getEnv("ANTHROPIC_API_KEY_URI"))
  if uri.len == 0:
    return ""
  try:
    result = strutils.strip(readCogameUri(uri, "ANTHROPIC_API_KEY_URI"))
  except CatchableError as error:
    logLine("llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg)
    result = ""

proc bedrockModelIds(): seq[string] =
  ## `us.anthropic.claude-sonnet-4-6` is deliberately NOT in this ladder: it
  ## times out on every sidecar call and one throttle cascades into scripted
  ## fallbacks (playbook gotcha, raid round 2, 2026-08-23).
  let pinned = strutils.strip(getEnv("BEDROCK_MODEL"))
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  inc client.bedrockModel
  logLine("llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel])
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(maxOutputTokens: int, model: string): LlmClient =
  result = LlmClient(model: model, maxOutputTokens: maxOutputTokens)
  let bedrockEndpoint = strutils.strip(getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME"))
  let bedrockToken = strutils.strip(getEnv("AWS_BEARER_TOKEN_BEDROCK"))
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    logLine("llm: bedrock transport, url ", result.bedrockUrl())
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    logLine("llm: anthropic transport, model ", result.model)
  else:
    result.transport = ltNone
    result.disabled = true
    logLine("llm: no LLM credentials; falling back to the scripted layer")

proc newOfflineLlmClient*(batch: BatchProc): LlmClient =
  ## A client with no transport but a batch hook — the shape the engine tests
  ## drive.
  LlmClient(transport: ltNone, disabled: false, maxOutputTokens: 900,
    model: "test", batchOverride: batch)

proc userMessage*(request: SeatRequest, retryHint: bool): string =
  result = strutils.strip(request.prompt)
  if result.len > 0:
    result.add("\n\n")
  result.add(request.viewJson)
  if retryHint:
    result.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
      "requested JSON object; it must begin with '{' and carry " &
      "congestion_weight, patience, dispatch, spread, corridor, avoid, " &
      "priority, note and say.")

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0.4,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a
    ## 400 when it is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  if error.len > 0:
    raise newException(GridlockError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(GridlockError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(GridlockError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(GridlockError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(GridlockError, "llm error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GridlockError, "model refusal")
  let content = payload{"content"}
  if content != nil and content.kind == JArray:
    for contentBlock in content:
      if contentBlock{"type"}.getStr() == "text":
        result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GridlockError,
      "reply cut off at max_tokens before any JSON")

proc causeOf(message: string): FallbackCause =
  let lower = message.toLowerAscii()
  if "timeout" in lower or "timed out" in lower: fcTimeout
  elif "transport" in lower or "auth" in lower or "throttled" in lower or
      "llm error" in lower: fcTransportError
  else: fcParseError

proc runBatch(client: LlmClient, requests: seq[LlmRequest],
    timeoutSeconds: int): seq[LlmReply] =
  ## ONE parallel batch. Every open seat's request is issued together.
  if client.batchOverride != nil:
    return client.batchOverride(requests, timeoutSeconds)
  result = newSeq[LlmReply](requests.len)
  var batch: RequestBatch
  ## The headers are identical for every seat in the batch; only the body
  ## differs, so build them once.
  let shared = client.requestFor(SystemPrompt, "")
  for i, request in requests:
    batch.post(request.url, shared.headers, request.body, $i)
  let responses = client.curl.makeRequests(batch, timeoutSeconds)
  for i in 0 ..< requests.len:
    result[i] = LlmReply(seat: requests[i].seat)
    try:
      result[i].text = client.textOf(responses[i].response,
        responses[i].error, requests[i].url)
    except CatchableError as error:
      result[i].error = error.msg

proc decideAll*(client: LlmClient, seats: array[Seats, SeatRequest]):
    TurnDecision =
  ## One plan per seat. NEVER raises: any failure ends on the scripted
  ## baseline so the episode always advances.
  var open: seq[int]
  for seat in 0 ..< Seats:
    if seats[seat].scripted != skNone or client.disabled:
      result.plans[seat] = scriptedPlan(seats[seat].baseline,
        (if seats[seat].scripted == skNone: skDispatcher
         else: seats[seat].scripted))
      if seats[seat].scripted == skNone and client.disabled:
        result.fallbacks.add(FallbackRecord(seat: seat, attempt: 1,
          cause: fcNoCredentials, detail: "no LLM credentials"))
    else:
      open.add(seat)
  let turnStart = epochTime()
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    let timeout =
      if attempt == 0: FirstAttemptSeconds else: RetryAttemptSeconds
    var requests: seq[LlmRequest]
    for seat in open:
      let user = userMessage(seats[seat], attempt > 0)
      let built = client.requestFor(SystemPrompt, user)
      requests.add(LlmRequest(seat: seat, url: built.url, body: built.body))
    let attemptStart = epochTime()
    let replies = runBatch(client, requests, timeout)
    let latencyMs = int((epochTime() - attemptStart) * 1000.0)
    var stillOpen: seq[int]
    for i, seat in open:
      var failure = ""
      if i < replies.len and replies[i].error.len == 0:
        try:
          result.plans[seat] = parsePlan(replies[i].text, seats[seat].previous)
          result.plans[seat].source = psLlm
          result.plans[seat].latencyMs = latencyMs
          inc result.llmSeats
        except CatchableError as error:
          failure = error.msg
      else:
        failure =
          if i < replies.len: replies[i].error else: "no reply for this seat"
      if failure.len > 0:
        logLine("llm: seat ", seat, " attempt ", attempt + 1, " failed: ",
          failure)
        result.fallbacks.add(FallbackRecord(seat: seat, attempt: attempt + 1,
          cause: causeOf(failure), detail: cleanLine(failure, MaxDetailRunes)))
        stillOpen.add(seat)
    open = stillOpen
  let spentMs = int((epochTime() - turnStart) * 1000.0)
  for seat in open:
    logLine("llm: seat ", seat, " falling back to the dispatcher plan")
    result.plans[seat] = dispatcherPlan(seats[seat].baseline)
    result.plans[seat].source = psFallback
    result.plans[seat].latencyMs = spentMs
