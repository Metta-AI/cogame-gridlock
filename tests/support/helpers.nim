## Shared test helpers. They live in tests/support/ (a subdirectory) so the
## `tests/*.nim` glob ci.yml runs never executes a helper module as a test.

import std/[json, os, strutils]
import gridlock/sim
import gridlock/llm
import gridlock/replay
import gridlock/startup

export sim, llm, replay, startup

const DebugTicks* = 960
  ## Debug builds run the whole step with range and overflow checks, which is
  ## 10-50x slower. Every test scales its episode with this so `nim r` in both
  ## modes stays inside CI's budget while release still exercises full length.

proc episodeTicks*(full: int): int =
  when defined(release): full
  else: min(full, DebugTicks)

proc testCity*(): CitySpec =
  loadCitySpec("gridcity")

proc testConfig*(ticks = 960, seed = 42, fleet = 50,
    orderPeriodTicks = 24): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.numAgents = Seats
  result.fleetSize = fleet
  result.episodeTicks = ticks
  result.turnTicks = 240
  result.orderPeriodTicks = orderPeriodTicks
  result.minTurnSpacingSeconds = 0.0
  result.wallClockBudgetSeconds = 180.0
  result.playerConnectTimeoutSeconds = 0.0
  result.players = @[]
  result.tokens = @[]
  for i in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(i + 1)))
    result.tokens.add("token-" & $i)

proc newTestSim*(ticks = 960, seed = 42, fleet = 50,
    orderPeriodTicks = 24): Sim =
  initSim(testConfig(ticks, seed, fleet, orderPeriodTicks), testCity())

proc allKinds*(kind: ScriptKind): array[Seats, ScriptKind] =
  for seat in 0 ..< Seats:
    result[seat] = kind

proc kindsOf*(a, b, c, d: ScriptKind): array[Seats, ScriptKind] =
  [a, b, c, d]

proc runScripted*(game: var Sim, kinds: array[Seats, ScriptKind]) =
  runScriptedEpisode(game, kinds)

proc quickEpisode*(ticks = 960, seed = 42,
    kind = skDispatcher): Sim =
  result = newTestSim(ticks, seed)
  runScriptedEpisode(result, allKinds(kind))

proc readSource*(path: string): string =
  ## Source-grep tests read the repo from the CWD, which is the repo root when
  ## ci.yml runs `nim r --path:src tests/<file>`.
  if not fileExists(path):
    raise newException(IOError, "source not found from " & getCurrentDir() &
      ": " & path)
  readFile(path)

proc stripComments*(source: string): string =
  ## Naive but adequate for the step-path modules, none of which put a '#'
  ## inside a string literal.
  for line in source.splitLines():
    let hash = line.find('#')
    result.add(if hash >= 0: line[0 ..< hash] else: line)
    result.add("\n")

proc containsCall*(source, name: string): bool =
  ## True when `name(` appears as a WHOLE identifier. Searching for the bare
  ## substring would trip the `tan(` guard on `manhattan(`.
  const IdentChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}
  var index = source.find(name & "(")
  while index >= 0:
    if index == 0 or source[index - 1] notin IdentChars:
      return true
    index = source.find(name & "(", index + 1)
  false

proc totalDelivered*(game: Sim): int =
  for seat in 0 ..< Seats:
    result += game.delivered[seat]

proc cellOccupant*(game: Sim, lane, cell: int): int =
  game.cells[lane * game.config.laneCells + cell]

proc putVan*(game: var Sim, g, lane, cell: int, loaded = false) =
  ## Plants one van on the board for a hand-built scenario.
  liftVehicle(game, g)
  placeVehicle(game, g, lane, cell)
  game.vehicles[g].hasParcel = loaded
  game.vehicles[g].state = if loaded: vsLoaded else: vsEmpty
  game.vehicles[g].route = @[lane]

proc fakeReplyPlan*(congestion, dispatch: int): string =
  $ %*{"congestion_weight": congestion, "patience": 50,
       "dispatch": dispatch, "spread": 40, "corridor": newJNull(),
       "avoid": newJNull(), "priority": "near", "note": "fake", "say": ""}
