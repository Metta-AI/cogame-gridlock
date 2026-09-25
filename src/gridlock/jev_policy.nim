## Jev ranks independent fields of the ordinary Gridlock routing plan.

import std/[json, os, strutils]
import curly

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(ValueError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc numericChoices(previous: JsonNode, field: string): JsonNode =
  result = newJObject()
  for value in countup(0, 100, 10):
    result[$value] = %(field & " = " & $value)
  if previous.kind == JObject and previous.hasKey(field):
    let value = previous[field].getInt()
    if value in 0 .. 100:
      result[$value] = %("Keep previous " & field & " = " & $value)

proc chooseJevPlan*(decision: JsonNode, timeoutSeconds: int): JsonNode =
  let view = decision["view"]
  let previous = view["you"]["last_plan"]
  let congestion = numericChoices(previous, "congestion_weight")
  let patience = numericChoices(previous, "patience")
  let dispatch = numericChoices(previous, "dispatch")
  let spread = numericChoices(previous, "spread")
  var districts = %*{"none": "No preferred district"}
  var avoids = %*{"none": "Do not avoid a district"}
  for by in 0 .. 2:
    for bx in 0 .. 2:
      let key = $bx & "," & $by
      districts[key] = %("Prefer routing through district " & key)
      avoids[key] = %("Route around district " & key)
  let priority = %*{
    "near": "Load the nearest waiting parcel first.",
    "far": "Load the farthest waiting parcel first.",
    "fifo": "Load parcels in arrival order."
  }
  let notes = %*{
    "quiet": "",
    "meter": "Meter vans to reduce spillback.",
    "reroute": "Route around the hottest district.",
    "deliver": "Prioritize near deliveries while roads move."
  }
  let sayings = %*{
    "quiet": "",
    "meter": "metering fleet",
    "reroute": "routing around jams",
    "deliver": "clear the backlog"
  }
  let questions = %*{
    "congestion_weight": {"type": "choice", "instructions":
      "Choose how strongly queued roads raise route cost.",
      "criteria": congestion},
    "patience": {"type": "choice", "instructions":
      "Choose the queue threshold before vans replan.",
      "criteria": patience},
    "dispatch": {"type": "choice", "instructions":
      "Choose the percentage of vans allowed on roads.",
      "criteria": dispatch},
    "spread": {"type": "choice", "instructions":
      "Choose how evenly departures are spaced.",
      "criteria": spread},
    "corridor": {"type": "choice", "instructions":
      "Choose a preferred district or none.", "criteria": districts},
    "avoid": {"type": "choice", "instructions":
      "Choose a district to avoid or none.", "criteria": avoids},
    "priority": {"type": "choice", "instructions":
      "Choose which parcel a van loads next.", "criteria": priority},
    "note": {"type": "choice", "instructions":
      "Choose a short spectator note.", "criteria": notes},
    "say": {"type": "choice", "instructions":
      "Choose a short public line.", "criteria": sayings}
  }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $decision["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You route one fleet of 50 vans in Gridlock. Choose a complete " &
      "routing plan for the next turn. The game repairs and validates it. " &
      "Use only this private observation:\n" & $view,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, timeoutSeconds)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let answers = parseJson(response.body)["answers"]
  let corridor = bestChoice(answers["corridor"], districts)
  let avoid = bestChoice(answers["avoid"], avoids)
  result = %*{
    "congestion_weight": parseInt(bestChoice(answers["congestion_weight"],
      congestion)),
    "patience": parseInt(bestChoice(answers["patience"], patience)),
    "dispatch": parseInt(bestChoice(answers["dispatch"], dispatch)),
    "spread": parseInt(bestChoice(answers["spread"], spread)),
    "priority": bestChoice(answers["priority"], priority),
    "note": notes[bestChoice(answers["note"], notes)],
    "say": sayings[bestChoice(answers["say"], sayings)]
  }
  result["corridor"] =
    if corridor == "none": newJNull()
    else: %*[parseInt(corridor.split(',')[0]), parseInt(corridor.split(',')[1])]
  result["avoid"] =
    if avoid == "none": newJNull()
    else: %*[parseInt(avoid.split(',')[0]), parseInt(avoid.split(',')[1])]
