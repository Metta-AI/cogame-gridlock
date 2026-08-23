## Determinism — the gate.
##
## Same seed + same resolved plan stream => the same digest at every keyframe.
## The whole step is integer, so this must hold in the native build and in the
## emscripten build alike; the wasm viewer proves the second half at runtime by
## comparing every keyframe against the recorded digest.

import std/[json, os, unittest]
import support/helpers

const GoldenPath = "tests/fixtures/golden_digests.json"

proc digestsOf(game: Sim): seq[int] =
  for frame in game.keyframes:
    result.add(int(frame.d))

proc playScripted(ticks, seed: int): Sim =
  result = newTestSim(ticks, seed)
  runScripted(result, allKinds(skDispatcher))

suite "determinism":
  test "two runs of one seed agree at every keyframe, in one process":
    let a = playScripted(episodeTicks(4800), 42)
    let b = playScripted(episodeTicks(4800), 42)
    check a.keyframes.len == b.keyframes.len
    check a.keyframes.len > 0
    for i in 0 ..< a.keyframes.len:
      check a.keyframes[i].t == b.keyframes[i].t
      check a.keyframes[i].d == b.keyframes[i].d
    check a.vehicleBytes == b.vehicleBytes
    check a.delivered == b.delivered

  test "a fresh instance built the other way round agrees too":
    ## Same seed, but the sim is constructed from a config object built
    ## separately — nothing carries over between the two.
    var first = initSim(testConfig(episodeTicks(1920), 4242), testCity())
    runScripted(first, allKinds(skDispatcher))
    var second = initSim(testConfig(episodeTicks(1920), 4242), testCity())
    runScripted(second, allKinds(skDispatcher))
    check digestsOf(first) == digestsOf(second)
    check first.vehicleBytes == second.vehicleBytes

  test "changing one plan integer on one turn changes the digest":
    var base = newTestSim(episodeTicks(1920), 7)
    var perturbed = newTestSim(episodeTicks(1920), 7)
    var turn = 0
    while base.tick < base.config.episodeTicks:
      var plans = scriptedPlansFor(base, allKinds(skDispatcher))
      discard runTurn(base, plans)
      var tweaked = scriptedPlansFor(perturbed, allKinds(skDispatcher))
      if turn == 1:
        ## One field, one seat, one turn. (The derived coefficients are
        ## coarse — replanQueue moves every 10 points of patience — so the
        ## perturbation has to clear a decade to be observable at all.)
        tweaked[0].congestionWeight =
          (tweaked[0].congestionWeight + 37) mod 101
      discard runTurn(perturbed, tweaked)
      inc turn
    check digestsOf(base) != digestsOf(perturbed)

  test "the replan FIFO order is a function of the seed and the plans alone":
    var a = newTestSim(episodeTicks(1440), 31)
    var b = newTestSim(episodeTicks(1440), 31)
    while a.tick < a.config.episodeTicks:
      discard runTurn(a, scriptedPlansFor(a, allKinds(skBeeline)))
      discard runTurn(b, scriptedPlansFor(b, allKinds(skBeeline)))
      check a.replanQueue.len - a.replanHead == b.replanQueue.len - b.replanHead
      for i in 0 ..< (a.replanQueue.len - a.replanHead):
        check a.replanQueue[a.replanHead + i] == b.replanQueue[b.replanHead + i]
    check digestsOf(a) == digestsOf(b)

  test "a turn snapshot reproduces the state the forward run had":
    var game = newTestSim(1920, 13)
    game.keepSnapshots = true
    for _ in 0 ..< 4:
      discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))
    check game.snapshots.len == 4
    let snap = game.snapshots[2]
    ## The keyframe at the snapshot's tick carries the digest the forward run
    ## had there.
    var forwardDigest = 0'u32
    for frame in game.keyframes:
      if frame.t == snap.tick:
        forwardDigest = frame.d
    check forwardDigest != 0'u32
    var rewound = game
    restoreSnapshot(rewound, snap)
    check rewound.tick == snap.tick
    check gridlockStateDigest(rewound) == forwardDigest
    ## Byte for byte on the state the snapshot owns.
    check rewound.vehicles.len == game.vehicles.len
    check rewound.cells == snap.cells
    check rewound.q == snap.q
    check rewound.delivered == snap.delivered

  test "the digest actually depends on the state it documents":
    var game = newTestSim(480, 3)
    runScripted(game, allKinds(skDispatcher))
    let before = gridlockStateDigest(game)
    game.delivered[0] += 1
    check gridlockStateDigest(game) != before
    game.delivered[0] -= 1
    check gridlockStateDigest(game) == before
    game.tick += 1
    check gridlockStateDigest(game) != before

suite "golden digests":
  test "seed 42 over 960 ticks matches the committed fixture":
    var game = newTestSim(960, 42)
    runScripted(game, allKinds(skDispatcher))
    var digests = newJArray()
    for frame in game.keyframes:
      digests.add(%*{"t": frame.t, "d": int(frame.d)})
    let document = %*{
      "game_version": GameVersion,
      "seed": 42,
      "ticks": 960,
      "baseline": "dispatcher",
      "keyframes": digests}
    if not fileExists(GoldenPath):
      ## The fixture is generated once, from a green CI run, and committed;
      ## after that any rule change shows up in the diff.
      createDir("tests/fixtures")
      writeFile(GoldenPath, pretty(document) & "\n")
      echo "GOLDEN DIGESTS WRITTEN (commit tests/fixtures/golden_digests.json):"
      echo pretty(document)
    else:
      let golden = parseJson(readFile(GoldenPath))
      check golden["game_version"].getStr() == GameVersion
      check golden["seed"].getInt() == 42
      check golden["ticks"].getInt() == 960
      check golden["keyframes"].len == digests.len
      for i in 0 ..< digests.len:
        check golden["keyframes"][i]["t"].getInt() == digests[i]["t"].getInt()
        check golden["keyframes"][i]["d"].getInt() == digests[i]["d"].getInt()
