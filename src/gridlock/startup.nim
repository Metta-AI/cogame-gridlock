## The entrypoint's testable pieces: seed pinning, the file://-only artifact
## sinks, and the two wall-clock guards the turn loop runs on.
##
## They live here rather than in src/gridlock.nim because a `when isMainModule`
## entrypoint cannot be imported by a test.

import std/[json, os, strutils, sysrand]
import types

proc randomSeed*(): int =
  var buffer: array[4, byte]
  if not urandom(buffer):
    raise newException(GridlockError, "OS entropy source unavailable")
  (int(buffer[0]) shl 24 or int(buffer[1]) shl 16 or
    int(buffer[2]) shl 8 or int(buffer[3])) and 0x7FFF_FFFF

proc seedPinned*(configJson: string): bool =
  ## True only when the runtime config explicitly pins a non-zero seed.
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt() != 0
  except CatchableError:
    false

proc stripUnpinnedSeed*(configJson: string): string =
  ## Drops a sentinel seed from an unpinned config so it cannot clobber the
  ## randomized seed injected before config.update.
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson

proc fileUriProblem*(name, uri: string): string =
  ## COGAME_EVENTS_URI and COGAME_METRICS_URI are file:// only. Returns "" when
  ## the value is acceptable, or the message to die with.
  let value = strutils.strip(uri)
  if value.len == 0:
    return ""
  if value.startsWith("file://"):
    return ""
  name & " must be a file:// URI, got: " & value

proc envFileUriProblem*(name: string): string =
  fileUriProblem(name, getEnv(name))

proc budgetGuardEngaged*(elapsed, turnBudgetSeconds,
    wallClockBudgetSeconds: float): bool =
  ## Settle early rather than overrun: when two more full-cost turns would
  ## cross the engine budget, the LLM is skipped for every remaining turn and
  ## the episode finishes on the scripted layer — ending complete/full_time
  ## instead of deadline.
  elapsed + 2.0 * turnBudgetSeconds > wallClockBudgetSeconds

proc spacingRemaining*(turnElapsed, minSpacing: float): float =
  ## The sidecar caps 30 requests/minute per episode and gridlock issues four
  ## per batch, so batches must start at least 8 s apart; the floor is 10 s.
  if minSpacing - turnElapsed > 0.0: minSpacing - turnElapsed else: 0.0
