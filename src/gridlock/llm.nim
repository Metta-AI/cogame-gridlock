## Native sidecar policy for one canonical private routing view.
## The game owns parsing, repairs, retry windows and installed plans.

import std/[base64, json, math, monotimes, options, os, sets, strutils, tables, unicode]
import bitworld/[decision_trajectory, native_http]
import types

const
  AnthropicVersion = "2023-06-01"

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
  SeatRequest* = object
    prompt*: string
    viewJson*: string

  LlmClient* = ref object
    sidecarEndpoint: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    temperature*: float
    lastAttempt*: DecisionAttempt

proc newLlmClient*(maxOutputTokens: int, model: string): LlmClient =
  result = LlmClient(model: getEnv("COWORLD_LLM_MODEL", model),
    maxOutputTokens: maxOutputTokens,
    temperature: parseFloat(getEnv("COWORLD_LLM_TEMPERATURE", "0.4")),
    sidecarEndpoint: getEnv("COWORLD_LLM_ENDPOINT").strip().strip(chars = {'/'}, leading = false))
  if classify(result.temperature) in {fcNan, fcInf, fcNegInf} or
      result.temperature < 0 or result.temperature > 1:
    raise newException(GridlockError, "COWORLD_LLM_TEMPERATURE must be finite and in [0, 1]")
  if result.maxOutputTokens <= 0:
    raise newException(GridlockError, "PLAYER_MAX_OUTPUT_TOKENS must be positive")
  if result.model.len == 0:
    raise newException(GridlockError, "native model must not be empty")
  result.disabled = result.sidecarEndpoint.len == 0

proc userMessage*(request: SeatRequest, retryHint: bool): string =
  result = clipRunes(strutils.strip(request.prompt), 4000)
  if result.len > 0:
    result.add("\n\n")
  result.add(request.viewJson)
  if retryHint:
    result.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
      "requested JSON object; it must begin with '{' and carry " &
      "congestion_weight, patience, dispatch, spread, corridor, avoid, " &
      "priority, note and say.")


proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  if slot < 0 or slot >= Seats:
    raise newException(GridlockError, "native player slot is outside the game seats")
  let body = %*{"max_tokens": client.maxOutputTokens,
    "temperature": client.temperature, "model": client.model,
    "system": system, "messages": [{"role": "user", "content": user}]}
  result.headers["content-type"] = "application/json"
  result.headers["anthropic-version"] = AnthropicVersion
  result.headers["X-Coworld-Player-Slot"] = $slot
  result.url = client.sidecarEndpoint & "/v1/messages"
  result.body = $body

proc completeText(client: LlmClient, system, user: string, slot: int,
    deadline: MonoTime,
    beforeCall: proc(attempt: DecisionAttempt) {.closure, gcsafe.}): string =
  let request = client.requestFor(system, user, slot)
  client.lastAttempt.prompt = %*[{"role": "system", "content": system},
    {"role": "user", "content": user}]
  client.lastAttempt.request = parseJson(request.body)
  client.lastAttempt.model = some(client.model)
  client.lastAttempt.decoder = %*{"temperature": client.temperature,
    "max_tokens": client.maxOutputTokens}
  beforeCall(client.lastAttempt)
  let response = performNativePost(request.url, request.headers, request.body, deadline)
  client.lastAttempt.latencyMs = response.latencyMs
  client.lastAttempt.responseReaderJoined = response.responseReaderJoined
  let observedResponse = response.httpStatus.isSome or response.headerBytes.len > 0 or response.bodyBytes.len > 0
  if observedResponse:
    client.lastAttempt.responseBodyB64 = some(encode(response.bodyBytes))
    client.lastAttempt.responseHeadersB64 = some(encode(response.headerBytes))
    client.lastAttempt.responseComplete = some(response.transferComplete)
    client.lastAttempt.httpStatus = response.httpStatus
    if validateUtf8(response.bodyBytes) == -1:
      client.lastAttempt.rawResponse = %response.bodyBytes
  if validateUtf8(response.headerBytes) != -1:
    raise newException(GridlockError, "received HTTP headers are not valid UTF-8")
  var responseHeaders: HttpHeaders
  var receivedHeaders = initTable[string, string]()
  var identityHeaders = initHashSet[string]()
  for line in response.headerBytes.splitLines():
    if line.startsWith("HTTP/"):
      responseHeaders.setLen(0)
      receivedHeaders.clear()
      identityHeaders.clear()
    elif line.len > 0:
      let colon = line.find(':')
      if colon <= 0:
        raise newException(GridlockError, "invalid received HTTP header")
      let name = line[0 ..< colon]
      let value = line[colon + 1 .. ^1].strip()
      let normalized = name.toLowerAscii()
      if normalized in ["request-id", "x-request-id", "x-softmax-llm-call-id",
          "x-coworld-checkpoint-sha256", "x-coworld-tokenizer-sha256",
          "x-coworld-chat-template-sha256"]:
        if normalized in identityHeaders:
          raise newException(GridlockError, "duplicate received identity header")
        identityHeaders.incl(normalized)
      responseHeaders.add((name, value))
      receivedHeaders[name] = value
  if observedResponse:
    client.lastAttempt.responseHeaders = some(receivedHeaders)
  if responseHeaders.contains("request-id") and responseHeaders.contains("x-request-id") and
      responseHeaders["request-id"] != responseHeaders["x-request-id"]:
    raise newException(GridlockError, "conflicting received request identity headers")
  for key in ["request-id", "x-request-id"]:
    if responseHeaders.contains(key):
      client.lastAttempt.providerRequestId = some(responseHeaders[key])
      break
  for (header, field) in [
      ("x-softmax-llm-call-id", "call"),
      ("x-coworld-checkpoint-sha256", "model"),
      ("x-coworld-tokenizer-sha256", "tokenizer"),
      ("x-coworld-chat-template-sha256", "template")]:
    if responseHeaders[header].len > 0:
      case field
      of "call":
        let identity = responseHeaders[header]
        if identity.len != 36:
          raise newException(GridlockError, "received platform call identity is not a UUID")
        for index, character in identity:
          if index in [8, 13, 18, 23]:
            if character != '-':
              raise newException(GridlockError, "received platform call identity is not a UUID")
          elif character notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            raise newException(GridlockError, "received platform call identity is not a UUID")
        client.lastAttempt.platformCallId = some(identity)
      of "model": client.lastAttempt.modelIdentity = some(responseHeaders[header])
      of "tokenizer": client.lastAttempt.tokenizerIdentity = some(responseHeaders[header])
      else: client.lastAttempt.chatTemplateSha256 = some(responseHeaders[header])
  if response.kind != nhComplete:
    raise newException(GridlockError, "native transport " & $response.kind)
  let status = response.httpStatus.get()
  if status == 401 or status == 403:
    client.disabled = true
    raise newException(GridlockError, "native inference auth failed (" & $status & ")")
  if status == 429:
    raise newException(GridlockError, "native inference throttled (429)")
  if status < 200 or status >= 300:
    raise newException(GridlockError, "native inference error " & $status)
  let payload = parseJson(response.bodyBytes)
  if payload.kind != JObject or payload["model"].kind != JString or
      payload["content"].kind != JArray:
    raise newException(GridlockError, "native response violates the completion schema")
  client.lastAttempt.model = some(payload["model"].getStr())
  case payload["stop_reason"].kind
  of JString: client.lastAttempt.stopReason = some(payload["stop_reason"].getStr())
  of JNull: discard
  else: raise newException(GridlockError, "native stop reason must be text or null")
  if payload.hasKey("usage") and payload["usage"].kind != JNull:
    let usage = payload["usage"]
    if usage.kind != JObject or usage["input_tokens"].kind != JInt or
        usage["output_tokens"].kind != JInt or usage["input_tokens"].getInt() < 0 or
        usage["output_tokens"].getInt() < 0:
      raise newException(GridlockError, "native usage must contain nonnegative integer counts")
    client.lastAttempt.inputTokens = some(usage["input_tokens"].getInt())
    client.lastAttempt.outputTokens = some(usage["output_tokens"].getInt())
  if payload.hasKey("sampling_evidence") and payload["sampling_evidence"].kind != JNull:
    let sampling = payload["sampling_evidence"]
    if sampling.kind != JObject or sampling["prompt_token_ids"].kind != JArray or
        sampling["completion_token_ids"].kind != JArray or sampling["stop_reason"].kind != JString:
      raise newException(GridlockError, "native sampling evidence violates the token schema")
    var promptIds, sampledIds: seq[int]
    var probabilities: seq[float]
    for token in sampling["prompt_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(GridlockError, "native prompt token IDs must be nonnegative integers")
      promptIds.add(token.getInt())
    for token in sampling["completion_token_ids"]:
      if token.kind != JInt or token.getInt() < 0:
        raise newException(GridlockError, "native sampled token IDs must be nonnegative integers")
      sampledIds.add(token.getInt())
    if sampling["behavior_log_probs"].kind != JNull:
      if sampling["behavior_log_probs"].kind != JArray:
        raise newException(GridlockError, "native draw probabilities must be an array or null")
      for probability in sampling["behavior_log_probs"]:
        if probability.kind notin {JInt, JFloat} or
            classify(probability.getFloat()) in {fcNan, fcInf, fcNegInf} or probability.getFloat() > 0:
          raise newException(GridlockError, "native draw probabilities must be finite nonpositive numbers")
        probabilities.add(probability.getFloat())
      if probabilities.len != sampledIds.len:
        raise newException(GridlockError, "native draw probabilities must match sampled token IDs")
    client.lastAttempt.promptTokenIds = some(promptIds)
    client.lastAttempt.sampledTokenIds = some(sampledIds)
    if sampling["behavior_log_probs"].kind != JNull:
      client.lastAttempt.behaviorLogprobs = some(probabilities)
    client.lastAttempt.stopReason = some(sampling["stop_reason"].getStr())
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GridlockError, "native inference refusal")
  for contentBlock in payload["content"]:
    if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
      raise newException(GridlockError, "native content block violates the completion schema")
    if contentBlock["type"].getStr() == "text":
      if contentBlock["text"].kind != JString:
        raise newException(GridlockError, "native text content must be text")
      result.add(contentBlock["text"].getStr())
  client.lastAttempt.response = %result
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GridlockError, "native reply ended before a JSON action")


proc choosePromptPlan*(client: LlmClient, prompt: string, viewJson: string,
    retryHint: bool, deadline: MonoTime, slot: int, attemptId, policy: string,
    beforeCall: proc(attempt: DecisionAttempt) {.closure, gcsafe.}): string =
  let user = userMessage(SeatRequest(prompt: prompt, viewJson: viewJson), retryHint)
  client.lastAttempt = newDecisionAttempt(attemptId, policy, aoModel)
  client.completeText(SystemPrompt, user, slot, deadline, beforeCall)
