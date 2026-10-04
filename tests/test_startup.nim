## Startup behaviour: a clean one-line exit 2 with no traceback when the
## runtime contract is missing or wrong, --help, and the player's bounded
## connect retry.

import std/[json, os, strutils, unittest]
import support/helpers

let entry = readSource("src/gridlock.nim")

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
