## Startup behaviour: a clean one-line exit 2 with no traceback when the
## runtime contract is missing or wrong, --help, and the player's bounded
## connect retry.

import std/[json, os, strutils, unittest]
import support/helpers

let entry = readSource("src/gridlock.nim")
let player = readSource("src/gridlock_player.nim")

suite "the game entrypoint":
  test "a missing COGAME_CONFIG_URI is a clean exit 2, not a traceback":
    check entry.contains("quit(\"COGAME_CONFIG_URI is not set (see --help)\", 2)")
    ## Every failure path exits 2 with one line, and every one of them is
    ## inside a try/except so nothing reaches the user as a stack trace.
    check entry.count("except CatchableError as error:") >= 4
    check entry.count(", 2)") >= 5
    check not entry.contains("raise newException")

  test "--help and --version answer before anything else happens":
    let helpIndex = entry.find("argument == \"--help\"")
    let readIndex = entry.find("readRuntimeConfig()")
    check helpIndex > 0
    check readIndex > helpIndex
    check entry.contains("argument == \"--version\"")
    check entry.contains("echo Usage")

  test "the file:// only sinks are rejected loudly":
    check fileUriProblem("COGAME_EVENTS_URI", "http://x/y").contains(
      "must be a file:// URI")
    check fileUriProblem("COGAME_METRICS_URI", "file:///tmp/m.json") == ""
    check envFileUriProblem("COGAME_EVENTS_URI_THAT_IS_NOT_SET") == ""
    putEnv("GRIDLOCK_TEST_SINK", "https://example.invalid/x")
    check envFileUriProblem("GRIDLOCK_TEST_SINK").len > 0
    delEnv("GRIDLOCK_TEST_SINK")

  test "the seed is randomised BEFORE config.update":
    ## Every seed-derived draw — the seat-to-depot permutation and the
    ## canonical destination schedule — must follow the FINAL seed.
    let randomIndex = entry.find("gameConfig.seed = randomSeed()")
    let updateIndex = entry.find("gameConfig.update(stripUnpinnedSeed(")
    check randomIndex > 0
    check updateIndex > randomIndex

  test "seed pinning and stripping behave as documented":
    check seedPinned("""{"seed": 7}""")
    check not seedPinned("""{"seed": 0}""")
    check not seedPinned("""{"episodeTicks": 4800}""")
    check not seedPinned("")
    check not seedPinned("not json at all")
    let stripped = parseJson(stripUnpinnedSeed("""{"seed":0,"turnTicks":240}"""))
    check not stripped.hasKey("seed")
    check stripped["turnTicks"].getInt() == 240
    check stripUnpinnedSeed("") == ""
    check stripUnpinnedSeed("not json") == "not json"

  test "a random seed is a 31-bit non-negative integer":
    for _ in 0 ..< 20:
      let seed = randomSeed()
      check seed >= 0
      check seed <= 0x7FFF_FFFF

  test "an invalid city path is a clean exit 2":
    check entry.contains("cannot load the city")
    expect GridlockError:
      discard loadCitySpec("definitely-not-a-city")

suite "the player entrypoint":
  test "an unreachable websocket exits 0 after a bounded retry":
    check player.contains("ConnectAttempts")
    check player.contains("ConnectDelayMs")
    let index = player.find("for attempt in 1 .. ConnectAttempts:")
    check index > 0
    let body = player[index ..< min(player.len, index + 700)]
    check body.contains("quit(0)") or player.contains("if not connected:\n    quit(0)")

  test "the receive loop exits 0 on a dead socket":
    ## whisky's receiveMessage RAISES on a close frame; mummy's send only
    ## queues, so the game's quit(0) can outrun the flushed done frame.
    check player.contains("except CatchableError as error:")
    let index = player.find("while true:")
    check index > 0
    let tail = player[index .. ^1]
    check tail.contains("except CatchableError as error:")
    check tail.contains("exiting cleanly")
    check player.strip().endsWith("quit(0)")

  test "it sends exactly one register frame and then only receives":
    check player.contains("\"type\": \"register\"")
    check player.contains("PLAYER_PROMPT")
    check player.contains("PLAYER_SCRIPTED")
    check player.contains("PLAYER_POLICY_LABEL")
    check player.contains("COWORLD_PLAYER_WS_URL")
    ## It never decides anything: no plan is built player-side. Setting
    ## neither variable registers `scripted: "dispatcher"` — the server
    ## picks the plan, the player never invents one.
    check not player.contains("dispatcherPlan")
    check not player.contains("RoutingPlan")
    check not player.contains("import gridlock/")

  test "a seat that sets neither variable registers as dispatcher":
    ## README, docs/PROTOCOL.md and the design note all say so; substituting
    ## a default PROMPT here would quietly make it an LLM seat.
    check player.contains("\"dispatcher\"")
    let index = player.find("let scripted =")
    check index > 0
    let body = player[index ..< min(player.len, index + 260)]
    check body.contains("PLAYER_SCRIPTED")
    check body.contains("\"dispatcher\"")
    check not player.contains("DefaultPrompt")
