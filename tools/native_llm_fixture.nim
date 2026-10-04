## Direct native transport probe; all provider identities are fixture-only.
import std/[json, monotimes, os, strutils, times]
import bitworld/[decision_trajectory, native_stop]
import gridlock/llm

when isMainModule:
  let args = commandLineParams()
  doAssert args.len == 2
  let output = args[0]
  let timeoutMs = parseInt(args[1])
  installNativeStopHandlers()
  let client = newLlmClient(128, "anthropic/claude-haiku-4.5")
  doAssert not client.disabled
  proc started(attempt: DecisionAttempt) =
    writePrivate(output / "started.json", $attempt.attemptEvidenceJson() & "\n")
  try:
    discard client.choosePromptPlan("fixture strategy", "{\"fixture\":true}", false,
      getMonoTime() + initDuration(milliseconds = timeoutMs), 0,
      "fixture-attempt", "fixture-native", started)
    echo "native transport fixture completed"
  finally:
    writePrivate(output / "finished.json", $client.lastAttempt.attemptEvidenceJson() & "\n")
