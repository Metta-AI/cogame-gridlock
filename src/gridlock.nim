## Gridlock entrypoint: reads the Coworld runtime contract and starts either a
## live episode server or a replay viewer server.
##
## Seed randomisation happens HERE, before `config.update`, so every
## seed-derived draw — the seat->depot permutation and the canonical
## destination schedule — follows the FINAL seed. That rule is inherited from
## paintbot's `src/ctf.nim` verbatim in shape.

import std/[os, strutils]
import bitworld/runtime
import gridlock/city
import gridlock/config
import gridlock/server
import gridlock/startup
import gridlock/state
import gridlock/types

const Usage = """
gridlock — four parcel fleets sharing one signalised 9x9 city.

The game reads the Coworld runtime contract from the environment:
  COGAME_CONFIG_URI         (required) the episode config
  COGAME_RESULTS_URI        where results.json is written
  COGAME_SAVE_REPLAY_URI    where the .replay JSON is written
  COGAME_LOAD_REPLAY_URI    replay mode: the replay to serve
  COGAME_PLAYER_FAILURE_URI where a seat no-show is declared
  COGAME_EVENTS_URI         file:// only
  COGAME_METRICS_URI        file:// only
  COGAME_HOST / COGAME_PORT listen address

Players connect to ws://<host>:<port>/player?slot=N&token=T and send one
{"type":"register","prompt":…,"scripted":…} frame. Decisions are made in the
game server; see docs/PROTOCOL.md.
"""

proc requireFileUri(name: string) =
  ## COGAME_EVENTS_URI and COGAME_METRICS_URI are file:// only, and anything
  ## else is rejected loudly rather than silently posted somewhere.
  let problem = envFileUriProblem(name)
  if problem.len > 0:
    quit(problem, 2)

when isMainModule:
  for argument in commandLineParams():
    if argument == "--help" or argument == "-h":
      echo Usage
      quit(0)
    if argument == "--version":
      echo "gridlock ", GameVersion
      quit(0)

  requireFileUri("COGAME_EVENTS_URI")
  requireFileUri("COGAME_METRICS_URI")

  if strutils.strip(getEnv("COGAME_CONFIG_URI")).len == 0 and
      strutils.strip(getEnv("COGAME_LOAD_REPLAY_URI")).len == 0:
    quit("COGAME_CONFIG_URI is not set (see --help)", 2)

  var runtimeConfig: RuntimeConfig
  try:
    runtimeConfig = readRuntimeConfig()
  except CatchableError as error:
    quit("gridlock: cannot read the runtime config: " & error.msg, 2)

  if runtimeConfig.replayMode:
    try:
      runReplayServer(runtimeConfig)
    except CatchableError as error:
      quit("gridlock: cannot serve the replay: " & error.msg, 2)
  else:
    var gameConfig = defaultGameConfig()
    try:
      if seedPinned(runtimeConfig.config):
        gameConfig.update(runtimeConfig.config)
      else:
        gameConfig.seed = randomSeed()
        gameConfig.update(stripUnpinnedSeed(runtimeConfig.config))
        logLine("seed not pinned; randomized to ", gameConfig.seed)
    except CatchableError as error:
      quit("gridlock: invalid episode config: " & error.msg, 2)

    if gameConfig.players.len == 0:
      for i in 0 ..< Seats:
        gameConfig.players.add(PlayerConfig(name: "P" & $(i + 1)))
    if gameConfig.tokens.len == 0:
      for i in 0 ..< Seats:
        gameConfig.tokens.add("token-" & $i)

    var spec: CitySpec
    try:
      spec = loadCitySpec(gameConfig.cityPath)
    except CatchableError as error:
      quit("gridlock: cannot load the city: " & error.msg, 2)

    logLine("seats=", gameConfig.players.len, " seed=", gameConfig.seed,
      " ticks=", gameConfig.episodeTicks, " turns=",
      turnsPerEpisode(gameConfig), " city=", spec.name)
    try:
      runGameServer(gameConfig, spec, runtimeConfig)
    except CatchableError as error:
      quit("gridlock: " & error.msg, 2)
