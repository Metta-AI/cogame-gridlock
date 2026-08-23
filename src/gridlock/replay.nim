## The replay: a self-sufficient, strict-UTF-8 JSON document, and the runtime
## that re-derives an episode from it.
##
## Deviation from paintbot, deliberate: paintbot writes the binary
## `COWLDCTF` format. Gridlock writes UTF-8 JSON, because SPEC §Definition of
## done check 4 fetches the replay from S3 and requires valid UTF-8 JSON with
## a matching `protocol` and a legal `results.reason`, and the shared
## `tools/ci/docker_smoke.sh` defaults to `SMOKE_REQUIRE_REPLAY_JSON=1`.
##
## The INPUT LOG IS THE PLAN STREAM — 20 turns x 4 seats of six values and two
## short strings — because the traffic is a pure function of
## (seed, city, plans). That is why the replay is small and why the viewer can
## re-derive every lane's occupancy, which is the picture the idea asks for.

import std/[base64, json]
import types
import config
import city
import plan
import events
import sim

type
  ReplayData* = object
    raw*: JsonNode
    config*: GameConfig
    city*: CitySpec
    seatDepots*: array[Seats, int]
    names*: array[Seats, string]
    aliases*: array[Seats, string]
    colours*: array[Seats, string]
    policyKinds*: array[Seats, string]
    plans*: seq[array[Seats, RoutingPlan]]
    keyframes*: seq[Keyframe]
    vehicles*: string
    events*: JsonNode
    results*: JsonNode
    tickCount*: int
    turnTicks*: int

  ReplayPlayer* = object
    data*: ReplayData
    sim*: Sim
    hashMismatchTick*: int
    installedTurns*: int

proc replayJson*(game: Sim, results: JsonNode): JsonNode =
  var plans = newJArray()
  for record in game.planLog:
    var entry = planJson(record.plan)
    entry["turn"] = %record.turn
    entry["seat"] = %record.seat
    entry["source"] = %($record.plan.source)
    entry["latency_ms"] = %record.plan.latencyMs
    plans.add(entry)
  var keyframes = newJArray()
  for frame in game.keyframes:
    var delivered = newJArray()
    var onRoad = newJArray()
    var backlog = newJArray()
    for seat in 0 ..< Seats:
      delivered.add(%frame.delivered[seat])
      onRoad.add(%frame.onRoad[seat])
      backlog.add(%frame.backlog[seat])
    keyframes.add(%*{
      "t": frame.t,
      "d": int64(frame.d),
      "del": delivered,
      "road": onRoad,
      "back": backlog,
      "jam": frame.jam})
  var seatDepots = newJArray()
  var players = newJArray()
  var aliases = newJArray()
  var kinds = newJArray()
  var colours = newJArray()
  for seat in 0 ..< Seats:
    seatDepots.add(%game.seatDepot[seat])
    players.add(%game.names[seat])
    aliases.add(%FleetAliases[game.seatDepot[seat]])
    colours.add(%FleetColours[game.seatDepot[seat]])
    kinds.add(%game.policyKinds[seat])
  %*{
    "protocol": ReplayProtocol,
    "format_version": ReplayFormatVersion,
    "game_version": GameVersion,
    "seed": game.config.seed,
    "config": configJson(game.config),
    "city": game.city.raw,
    "seat_depots": seatDepots,
    "names": {
      "players": players,
      "aliases": aliases,
      "policy_kinds": kinds,
      "colours": colours},
    "ticks_per_second": TargetFps,
    "turn_ticks": game.config.turnTicks,
    "tick_count": game.tick,
    "plans": plans,
    "keyframes": keyframes,
    "vehicles_b64": encode(game.vehicleBytes),
    "events": eventsJson(game.events),
    "results": results}

proc replayBytes*(game: Sim, results: JsonNode): string =
  $replayJson(game, results)

# ---------------------------------------------------------------------------
# Reading. Strict: every documented key must be present and consistent, and a
# malformed input is rejected with a message rather than a crash.
# ---------------------------------------------------------------------------

proc require(node: JsonNode, key: string): JsonNode =
  let field = node{key}
  if field == nil or field.kind == JNull:
    raise newException(GridlockError, "replay is missing '" & key & "'")
  field

proc parseReplayBytes*(bytes: string): ReplayData =
  var document: JsonNode
  try:
    document = parseJson(bytes)
  except CatchableError as error:
    raise newException(GridlockError, "replay is not JSON: " & error.msg)
  if document.kind != JObject:
    raise newException(GridlockError, "replay must be a JSON object")
  let protocol = document{"protocol"}.getStr()
  if protocol != ReplayProtocol:
    raise newException(GridlockError,
      "unsupported replay protocol: '" & protocol & "'")
  result.raw = document
  result.config = configFromJson(require(document, "config"))
  result.config.seed = document{"seed"}.getInt(result.config.seed)
  result.city = parseCitySpec(require(document, "city"))
  validateCitySpec(result.city)
  let depots = require(document, "seat_depots")
  if depots.len != Seats:
    raise newException(GridlockError, "seat_depots must name four depots")
  var seen: set[uint8]
  for seat in 0 ..< Seats:
    let depot = depots[seat].getInt()
    if depot < 0 or depot >= Seats or uint8(depot) in seen:
      raise newException(GridlockError, "seat_depots is not a permutation")
    seen.incl(uint8(depot))
    result.seatDepots[seat] = depot
  let names = require(document, "names")
  for seat in 0 ..< Seats:
    result.names[seat] = names{"players"}[seat].getStr()
    result.aliases[seat] = FleetAliases[result.seatDepots[seat]]
    result.colours[seat] = FleetColours[result.seatDepots[seat]]
    let kinds = names{"policy_kinds"}
    result.policyKinds[seat] =
      if kinds != nil and kinds.len > seat: kinds[seat].getStr("scripted")
      else: "scripted"
  result.tickCount = document{"tick_count"}.getInt()
  result.turnTicks = document{"turn_ticks"}.getInt(result.config.turnTicks)
  if result.turnTicks <= 0:
    raise newException(GridlockError, "turn_ticks must be positive")

  var turns: seq[array[Seats, RoutingPlan]]
  for entry in require(document, "plans"):
    let turn = entry{"turn"}.getInt(-1)
    let seat = entry{"seat"}.getInt(-1)
    if turn < 0 or seat < 0 or seat >= Seats:
      raise newException(GridlockError, "plan entry has a bad turn/seat")
    while turns.len <= turn:
      var blank: array[Seats, RoutingPlan]
      for s in 0 ..< Seats:
        blank[s] = defaultPlan()
      turns.add(blank)
    let recovered = planFromJson(entry)
    if not planIsLegal(recovered):
      raise newException(GridlockError,
        "plan entry is out of range at turn " & $turn & " seat " & $seat)
    turns[turn][seat] = recovered
  result.plans = turns

  for entry in require(document, "keyframes"):
    var frame = Keyframe(t: entry{"t"}.getInt(),
      d: uint32(entry{"d"}.getBiggestInt() and 0xFFFF_FFFF),
      jam: entry{"jam"}.getInt())
    for seat in 0 ..< Seats:
      frame.delivered[seat] = entry{"del"}[seat].getInt()
      frame.onRoad[seat] = entry{"road"}[seat].getInt()
      frame.backlog[seat] = entry{"back"}[seat].getInt()
    result.keyframes.add(frame)

  try:
    result.vehicles = decode(document{"vehicles_b64"}.getStr())
  except CatchableError as error:
    raise newException(GridlockError, "vehicles_b64 is not base64: " &
      error.msg)
  let expected = result.keyframes.len * Seats * result.config.fleetSize * 4
  if result.vehicles.len != expected:
    raise newException(GridlockError,
      "vehicles_b64 is " & $result.vehicles.len & " bytes, expected " &
        $expected)
  var offset = 0
  while offset + 1 < result.vehicles.len:
    let lane = int(uint8(result.vehicles[offset])) or
      (int(uint8(result.vehicles[offset + 1])) shl 8)
    if lane != DockedSentinel and (lane < 0 or lane >= LaneCount):
      raise newException(GridlockError, "vehicles_b64 holds lane " & $lane)
    offset += 4
  result.events = document{"events"}
  if result.events == nil:
    result.events = newJArray()
  result.results = document{"results"}
  if result.results == nil:
    result.results = newJObject()

proc initReplayRuntime*(data: ReplayData, mismatchQuit = false):
    ReplayPlayer =
  ## Rebuilds the sim the recording ran on. The seat -> depot permutation is
  ## re-derived from the seed and cross-checked against the recorded one — a
  ## disagreement means the rules moved under the replay.
  result.data = data
  result.hashMismatchTick = -1
  result.sim = initSim(data.config, data.city)
  result.sim.keepSnapshots = true
  for seat in 0 ..< Seats:
    if result.sim.seatDepot[seat] != data.seatDepots[seat]:
      raise newException(GridlockError,
        "seat_depots disagree with the seed-derived permutation")
    result.sim.names[seat] = data.names[seat]
    result.sim.policyKinds[seat] = data.policyKinds[seat]
  if mismatchQuit:
    discard

proc checkDigest(player: var ReplayPlayer) =
  ## Compared by TICK, not by index: a backward seek rewinds the live
  ## keyframe list, so an index comparison would drift after every scrub.
  if player.hashMismatchTick >= 0 or player.sim.keyframes.len == 0:
    return
  let frame = player.sim.keyframes[^1]
  let index = frame.t div TargetFps
  if index < 0 or index >= player.data.keyframes.len:
    return
  if player.data.keyframes[index].t != frame.t:
    return
  if player.data.keyframes[index].d != frame.d:
    player.hashMismatchTick = frame.t

proc advanceOneTick*(player: var ReplayPlayer): bool =
  ## One tick of playback, installing the recorded plan at every turn
  ## boundary. Returns false at the end of the recording.
  if player.sim.tick >= player.data.tickCount:
    return false
  if player.sim.tick mod player.data.turnTicks == 0:
    let turn = player.sim.tick div player.data.turnTicks
    ## `installedTurns` guards the seek path: after restoring a snapshot the
    ## turn it belongs to is ALREADY installed, and re-installing would
    ## re-draw the tie noise and re-emit the turn's events.
    if turn < player.data.plans.len and turn >= player.installedTurns:
      installPlans(player.sim, player.data.plans[turn])
      player.installedTurns = turn + 1
  let before = player.sim.keyframes.len
  stepTick(player.sim)
  if player.sim.keyframes.len != before:
    checkDigest(player)
  true

proc advanceFrames*(player: var ReplayPlayer, frames: int) =
  for _ in 0 ..< max(1, frames):
    if not advanceOneTick(player):
      break

proc seekTo*(player: var ReplayPlayer, tick: int) =
  ## A backward seek restarts from the nearest in-memory turn snapshot and
  ## replays at most one turn, instead of paintbot's replay-from-zero.
  let target = max(0, min(tick, player.data.tickCount))
  if target < player.sim.tick:
    var best = -1
    for i, snap in player.sim.snapshots:
      if snap.tick <= target:
        best = i
    if best >= 0:
      let snap = player.sim.snapshots[best]
      restoreSnapshot(player.sim, snap)
      player.sim.snapshots.setLen(best + 1)
      player.installedTurns = snap.turn + 1
    else:
      let keep = player.sim.names
      let kinds = player.sim.policyKinds
      player.sim = initSim(player.data.config, player.data.city)
      player.sim.names = keep
      player.sim.policyKinds = kinds
      player.installedTurns = 0
  while player.sim.tick < target:
    if not advanceOneTick(player):
      break

proc rederive*(data: ReplayData): Sim =
  ## Replays the whole recording from `seed` + `city` + `seat_depots` +
  ## `plans`. Used by the tests to prove every keyframe digest and every byte
  ## of `vehicles_b64` reproduce.
  var player = initReplayRuntime(data)
  player.sim.keepSnapshots = false
  while advanceOneTick(player):
    discard
  player.sim.recordKeyframe()
  player.sim
