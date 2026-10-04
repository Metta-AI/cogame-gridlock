## Hosted calls must reach the native sidecar without provider credentials.
include "../src/gridlock/llm"

block:
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
  putEnv("ANTHROPIC_API_KEY", "local-key-must-not-be-used")
  let client = newLlmClient(128, "claude-haiku-4-5-20251001")
  for slot in 0 .. 1:
    let request = client.requestFor("rules", "private view", slot)
    doAssert request.url == "http://127.0.0.1:9100/v1/messages"
    doAssert request.headers["X-Coworld-Player-Slot"] == $slot
    let body = parseJson(request.body)
    doAssert body["model"].getStr() == "anthropic/claude-sonnet-4.6"
    doAssert not body.hasKey("anthropic_version")
    doAssert not body.hasKey("output_config")
  echo "hosted sidecar routing and seat attribution passed"

import std/unittest
import gridlock/roster

suite "private prompt parity":
  test "registration and hosted renderer agree after whitespace and rune limits":
    var text = "  "
    for _ in 0 .. 4000: text.add("雪")
    text.add("  ")
    var seats = initRoster(@["a", "b", "c", "d"])
    seats.applyRegistration(0, %*{"type": "register", "kind": "prompt",
      "scripted": newJNull(), "policy": "fixture", "prompt": text})
    for retry in [false, true]:
      check userMessage(SeatRequest(prompt: text, viewJson: "{}"), retry) ==
        userMessage(SeatRequest(prompt: seats.seats[0].prompt, viewJson: "{}"), retry)
