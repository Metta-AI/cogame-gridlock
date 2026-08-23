## An end-to-end episode writing a replay, parsed STRICTLY, and re-derived
## from the plan stream byte for byte.

import std/[base64, json, os, unicode, unittest]
import support/helpers

proc writeEpisode(path: string, ticks = 960, seed = 42): JsonNode =
  var game = newTestSim(ticks, seed)
  game.names = ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
  game.policyKinds = ["llm", "llm", "scripted", "scripted"]
  ## Force a non-ASCII `say` into the plan stream so the UTF-8 path is real.
  var turn = 0
  while game.tick < game.config.episodeTicks:
    var plans = scriptedPlansFor(game, allKinds(skDispatcher))
    if turn == 0:
      plans[0].say = cleanLine("caf\xC3\xA9 \xF0\x9F\x9A\x9B detour",
        MaxSayRunes)
      plans[0].note = cleanLine("\xE2\x9C\x93 metering the arterial cross",
        MaxNoteRunes)
      plans[0].source = psLlm
      plans[0].latencyMs = 4120
    discard runTurn(game, plans)
    inc turn
  endEpisode(game, "complete", "full_time")
  let results = resultsJson(game)
  writeFile(path, replayBytes(game, results))
  result = %*{"tick": game.tick, "turns": turn,
              "keyframes": game.keyframes.len}

## The episode is written ONCE at module scope: `setup:` runs before every
## test and a fresh 960-tick episode per test is pure cost.
let path = getTempDir() / "gridlock-test-replay.json"
let meta = writeEpisode(path)
let raw = readFile(path)

suite "the replay a real episode writes":

  test "the bytes are valid UTF-8 before anything parses them":
    check validateUtf8(raw) == -1
    check raw.len > 1000

  test "it parses strictly and carries every documented top-level key":
    let document = parseJson(raw)
    for key in ["protocol", "format_version", "game_version", "seed",
        "config", "city", "seat_depots", "names", "ticks_per_second",
        "turn_ticks", "tick_count", "plans", "keyframes", "vehicles_b64",
        "events", "results"]:
      check document.hasKey(key)
    check document["protocol"].getStr() == "gridlock.replay.v1"
    check document["game_version"].getStr() == GameVersion
    check document["ticks_per_second"].getInt() == 24
    for key in ["city", "names", "config", "seat_depots", "plans",
        "keyframes", "events", "results"]:
      check document[key].len > 0

  test "the non-ASCII say survived the round trip on a rune boundary":
    let document = parseJson(raw)
    var sawUnicode = false
    for entry in document["plans"]:
      if entry["say"].getStr().len != entry["say"].getStr().runeLen:
        sawUnicode = true
        check entry["say"].getStr().runeLen <= MaxSayRunes
        check validateUtf8(entry["say"].getStr()) == -1
    check sawUnicode

  test "vehicles_b64 decodes to keyframes x 200 x 4 bytes of legal lanes":
    let document = parseJson(raw)
    let bytes = decode(document["vehicles_b64"].getStr())
    let expected = document["keyframes"].len * Seats * 50 * 4
    check bytes.len == expected
    check meta["keyframes"].getInt() == document["keyframes"].len
    var offset = 0
    while offset < bytes.len:
      let lane = int(uint8(bytes[offset])) or
        (int(uint8(bytes[offset + 1])) shl 8)
      check lane == DockedSentinel or (lane >= 0 and lane < LaneCount)
      let cell = int(uint8(bytes[offset + 2]))
      check cell >= 0 and cell < 14
      let state = int(uint8(bytes[offset + 3]))
      check state >= 0 and state <= 3
      offset += 4

  test "results.reason is in the legal enum and the schema keys match":
    let document = parseJson(raw)
    check document["results"]["reason"].getStr() in
      ["complete", "deadline", "fault"]
    check document["results"]["end_rule"].getStr() in
      ["full_time", "wall_clock", "sim_fault", "host_error"]
    for key in ResultsKeys:
      check document["results"].hasKey(key)

  test "the event stream has exactly one plan per seat per turn":
    let document = parseJson(raw)
    var plans = 0
    var delivers = 0
    var heats = 0
    var turnStarts = 0
    for event in document["events"]:
      case event["type"].getStr()
      of "plan": inc plans
      of "deliver": inc delivers
      of "heat": inc heats
      of "turn_start": inc turnStarts
      else: discard
    check turnStarts == meta["turns"].getInt()
    check plans == meta["turns"].getInt() * Seats
    check delivers >= 1
    check heats >= 1
    check document["plans"].len == plans

  test "re-deriving from seed + city + seat_depots + plans reproduces it":
    let data = parseReplayBytes(raw)
    check data.tickCount == meta["tick"].getInt()
    let rederived = rederive(data)
    check rederived.keyframes.len == data.keyframes.len
    for i in 0 ..< data.keyframes.len:
      check rederived.keyframes[i].t == data.keyframes[i].t
      check rederived.keyframes[i].d == data.keyframes[i].d
    check rederived.vehicleBytes == decode(
      parseJson(raw)["vehicles_b64"].getStr())
    for seat in 0 ..< Seats:
      check rederived.delivered[seat] ==
        parseJson(raw)["results"]["delivered"][seat].getInt()

  test "playback can seek backwards off a turn snapshot and land exactly":
    let data = parseReplayBytes(raw)
    var player = initReplayRuntime(data)
    while player.advanceOneTick():
      discard
    check player.sim.tick == data.tickCount
    check player.hashMismatchTick == -1
    ## Seek to the middle, then backwards, then to the end.
    let middle = data.tickCount div 2
    player.seekTo(middle)
    check player.sim.tick == middle
    let midDigest = gridlockStateDigest(player.sim)
    player.seekTo(data.tickCount)
    check player.sim.tick == data.tickCount
    player.seekTo(middle)
    check player.sim.tick == middle
    check gridlockStateDigest(player.sim) == midDigest
    player.seekTo(0)
    check player.sim.tick == 0

let badPath = getTempDir() / "gridlock-test-replay-bad.json"
discard writeEpisode(badPath, 480, 9)
let badRaw = readFile(badPath)

suite "malformed replays are rejected with a message, not a crash":

  test "a bad protocol":
    let document = parseJson(badRaw)
    document["protocol"] = %"ctf.replay.v1"
    expect GridlockError:
      discard parseReplayBytes($document)

  test "truncated JSON":
    expect GridlockError:
      discard parseReplayBytes(badRaw[0 ..< badRaw.len div 2])

  test "a vehicles_b64 whose length disagrees with the keyframe count":
    let document = parseJson(badRaw)
    document["vehicles_b64"] = %encode("too short")
    expect GridlockError:
      discard parseReplayBytes($document)

  test "an out-of-range plan integer":
    let document = parseJson(badRaw)
    document["plans"][0]["congestion_weight"] = %400
    ## Repair clamps it, so the recovered plan is legal and playback survives.
    let data = parseReplayBytes($document)
    let seat = document["plans"][0]["seat"].getInt()
    let recovered = data.plans[0][seat]
    check recovered.congestionWeight == 100

  test "a missing top-level key":
    let document = parseJson(badRaw)
    document.delete("keyframes")
    expect GridlockError:
      discard parseReplayBytes($document)

  test "a seat_depots that is not a permutation":
    let document = parseJson(badRaw)
    document["seat_depots"] = %[0, 0, 1, 2]
    expect GridlockError:
      discard parseReplayBytes($document)
