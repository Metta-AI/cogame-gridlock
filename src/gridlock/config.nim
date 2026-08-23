## GameConfig lifecycle and `configJson()`. Forked in shape from paintbot's
## `src/ctf/sim_config.nim`: defaults here, a JSON overlay from the runtime
## contract, and one resolved record pinned into the replay.
##
## Every field here also appears in `coworld_manifest_template.json`'s
## `game.config_schema`; the CLI validates every variant and the cert fixture
## against that schema, so the two must stay in sync.

import std/[json, strutils]
import types

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    numAgents: Seats,
    fleetSize: 50,
    episodeTicks: 4800,
    turnTicks: 240,
    moveTicks: 3,
    serviceTicks: 6,
    dispatchPeriodTicks: 12,
    laneCells: LaneCellsDefault,
    cellPx: CellPxDefault,
    loadTicks: 12,
    orderPeriodTicks: 24,
    backlogMax: 80,
    signalCycleTicks: 96,
    greenNsTicks: 48,
    routeBudgetPerTick: 24,
    jamThreshold: 11,
    turnBudgetSeconds: 22.0,
    minTurnSpacingSeconds: 10.0,
    wallClockBudgetSeconds: 660.0,
    playerConnectTimeoutSeconds: 90.0,
    episodeTimeoutSeconds: 1200,
    cityPath: "gridcity",
    showPlayerLabels: true,
    gameOverTicks: 96,
    maxOutputTokens: 900,
    model: "claude-haiku-4-5")

proc getNum(node: JsonNode, key: string, fallback: float): float =
  let field = node{key}
  if field == nil or field.kind == JNull:
    return fallback
  case field.kind
  of JInt:
    result = float(field.getInt())
  of JFloat:
    result = field.getFloat()
  of JString:
    try:
      result = parseFloat(strutils.strip(field.getStr()))
    except ValueError:
      result = fallback
  else:
    result = fallback

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults. Unknown keys are
  ## ignored; every known key is range-checked at the end.
  if strutils.strip(configJson).len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(GridlockError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player{"name"}.getStr()))
  config.seed = int(getNum(node, "seed", float(config.seed)))
  config.numAgents = int(getNum(node, "num_agents", float(config.numAgents)))
  config.numAgents = int(getNum(node, "numAgents", float(config.numAgents)))
  config.fleetSize = int(getNum(node, "fleetSize", float(config.fleetSize)))
  config.episodeTicks =
    int(getNum(node, "episodeTicks", float(config.episodeTicks)))
  config.turnTicks = int(getNum(node, "turnTicks", float(config.turnTicks)))
  config.moveTicks = int(getNum(node, "moveTicks", float(config.moveTicks)))
  config.serviceTicks =
    int(getNum(node, "serviceTicks", float(config.serviceTicks)))
  config.dispatchPeriodTicks =
    int(getNum(node, "dispatchPeriodTicks", float(config.dispatchPeriodTicks)))
  config.laneCells = int(getNum(node, "laneCells", float(config.laneCells)))
  config.cellPx = int(getNum(node, "cellPx", float(config.cellPx)))
  config.loadTicks = int(getNum(node, "loadTicks", float(config.loadTicks)))
  config.orderPeriodTicks =
    int(getNum(node, "orderPeriodTicks", float(config.orderPeriodTicks)))
  config.backlogMax = int(getNum(node, "backlogMax", float(config.backlogMax)))
  config.signalCycleTicks =
    int(getNum(node, "signalCycleTicks", float(config.signalCycleTicks)))
  config.greenNsTicks =
    int(getNum(node, "greenNsTicks", float(config.greenNsTicks)))
  config.routeBudgetPerTick =
    int(getNum(node, "routeBudgetPerTick", float(config.routeBudgetPerTick)))
  config.jamThreshold =
    int(getNum(node, "jamThreshold", float(config.jamThreshold)))
  config.turnBudgetSeconds =
    getNum(node, "turnBudgetSeconds", config.turnBudgetSeconds)
  config.minTurnSpacingSeconds =
    getNum(node, "minTurnSpacingSeconds", config.minTurnSpacingSeconds)
  config.wallClockBudgetSeconds =
    getNum(node, "wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  config.playerConnectTimeoutSeconds =
    getNum(node, "playerConnectTimeoutSeconds",
      config.playerConnectTimeoutSeconds)
  config.playerConnectTimeoutSeconds =
    getNum(node, "player_connect_timeout_seconds",
      config.playerConnectTimeoutSeconds)
  config.episodeTimeoutSeconds =
    int(getNum(node, "episodeTimeoutSeconds", float(config.episodeTimeoutSeconds)))
  if node.hasKey("cityPath"):
    config.cityPath = node["cityPath"].getStr(config.cityPath)
  if node.hasKey("showPlayerLabels"):
    config.showPlayerLabels =
      node["showPlayerLabels"].getBool(config.showPlayerLabels)
  config.gameOverTicks =
    int(getNum(node, "gameOverTicks", float(config.gameOverTicks)))
  config.maxOutputTokens =
    int(getNum(node, "maxOutputTokens", float(config.maxOutputTokens)))
  if node.hasKey("model"):
    config.model = node["model"].getStr(config.model)

proc validate*(config: GameConfig) =
  if config.numAgents != Seats:
    raise newException(GridlockError,
      "gridlock is a four-seat game; num_agents must be 4, got " &
        $config.numAgents)
  if config.fleetSize < 1 or config.fleetSize > 200:
    raise newException(GridlockError, "fleetSize must be 1..200")
  if config.episodeTicks < config.turnTicks:
    raise newException(GridlockError, "episodeTicks must cover one turn")
  if config.turnTicks mod 24 != 0:
    raise newException(GridlockError, "turnTicks must be a multiple of 24")
  if config.laneCells < 4 or config.laneCells > 64:
    raise newException(GridlockError, "laneCells must be 4..64")
  if config.moveTicks < 1 or config.serviceTicks < 1:
    raise newException(GridlockError, "moveTicks/serviceTicks must be >= 1")
  if config.greenNsTicks < 1 or config.greenNsTicks >= config.signalCycleTicks:
    raise newException(GridlockError, "greenNsTicks must be inside the cycle")
  if config.wallClockBudgetSeconds >
      0.6 * float(config.episodeTimeoutSeconds):
    raise newException(GridlockError,
      "wallClockBudgetSeconds must stay inside 60% of episodeTimeoutSeconds")

proc turnsPerEpisode*(config: GameConfig): int =
  (config.episodeTicks + config.turnTicks - 1) div config.turnTicks

proc configJson*(config: GameConfig): JsonNode =
  ## The fully resolved config, TOKENS EXCLUDED, pinned into the replay.
  var players = newJArray()
  for player in config.players:
    players.add(%*{"name": player.name})
  %*{
    "num_agents": config.numAgents,
    "fleetSize": config.fleetSize,
    "episodeTicks": config.episodeTicks,
    "turnTicks": config.turnTicks,
    "moveTicks": config.moveTicks,
    "serviceTicks": config.serviceTicks,
    "dispatchPeriodTicks": config.dispatchPeriodTicks,
    "laneCells": config.laneCells,
    "cellPx": config.cellPx,
    "loadTicks": config.loadTicks,
    "orderPeriodTicks": config.orderPeriodTicks,
    "backlogMax": config.backlogMax,
    "signalCycleTicks": config.signalCycleTicks,
    "greenNsTicks": config.greenNsTicks,
    "routeBudgetPerTick": config.routeBudgetPerTick,
    "jamThreshold": config.jamThreshold,
    "turnBudgetSeconds": config.turnBudgetSeconds,
    "minTurnSpacingSeconds": config.minTurnSpacingSeconds,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "playerConnectTimeoutSeconds": config.playerConnectTimeoutSeconds,
    "cityPath": config.cityPath,
    "showPlayerLabels": config.showPlayerLabels,
    "gameOverTicks": config.gameOverTicks,
    "players": players
  }

proc configFromJson*(node: JsonNode): GameConfig =
  ## Rebuilds the resolved config from a replay's `config` block.
  result = defaultGameConfig()
  result.update($node)
