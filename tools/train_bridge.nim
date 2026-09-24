## Numeric choices over the production Gridlock simulator and hosted view.
## nim c -d:release --path:src -o:/tmp/gridlock-train-bridge tools/train_bridge.nim

import std/[hashes, json, os]
import gridlock/[sim, llm]

var
  game: Sim
  plans: array[Seats, RoutingPlan]
  decisionId: int
  seat: int
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let view = $buildView(game, seat)
  %*{"kind": "decision", "game": "gridlock", "decision_id": decisionId,
    "seat": seat, "engine_seat": seat,
    "turn": game.tick div game.config.turnTicks,
    "semantic_view": {"system": SystemPrompt, "user": view},
    "inbox": [], "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 3}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  var config = defaultGameConfig()
  config.update($variantConfig)
  config.seed = int(hash(command["seed"].getStr()) mod 1_000_000_000)
  config.validate()
  let cityPath = manifestPath.parentDir / "data" /
    (config.cityPath & ".cityspec.json")
  let city = parseCitySpec(parseFile(cityPath))
  validateCitySpec(city)
  game = initSim(config, city)
  game.keepSnapshots = false
  decisionId = 0
  seat = 0
  currentDecision()

proc encode(): JsonNode =
  let view = buildView(game, seat)
  let own = view["you"]
  let city = view["city"]
  var values = newJArray()
  for name in ["default", "rush"]:
    values.add(%(if variant == name: 1 else: 0))
  values.add(%(float(game.tick) / float(game.config.episodeTicks)))
  for depot in 0 ..< Seats:
    values.add(%(if game.seatDepot[seat] == depot: 1 else: 0))
  for field in ["docked", "loading", "waiting_dispatch", "on_road_loaded",
                "on_road_empty", "stalled", "backlog"]:
    values.add(%(float(own[field].getInt()) / float(game.config.fleetSize)))
  for field in ["delivered", "delivered_last_turn"]:
    values.add(%(float(own[field].getInt()) / 100.0))
  values.add(%(own["mean_trip_seconds"].getFloat() / 100.0))
  values.add(%(float(own["stalled_pct"].getInt()) / 100.0))
  values.add(%(float(city["jam_index"].getInt()) / 100.0))
  for line in city["districts_heat"]:
    for digit in line.getStr():
      values.add(%(float(ord(digit) - ord('0')) / 9.0))
  for fleet in view["fleets"]:
    values.add(%(float(fleet["delivered"].getInt()) / 100.0))
    values.add(%(float(fleet["on_road"].getInt()) /
      float(game.config.fleetSize)))
  var destinations: array[DistrictCount, int]
  for order in own["next_orders"]:
    let district = order["district"]
    inc destinations[district[1].getInt() * DistrictCols + district[0].getInt()]
  for count in destinations:
    values.add(%(float(count) / 6.0))
  var actions = newJArray()
  for choice in 0 .. 3: actions.add(%*{"choice": choice})
  %*{"decision_id": decisionId, "values": values, "actions": actions}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 3
  var plan =
    if choice == 1: beelinePlan()
    else: dispatcherPlan(baselineInput(game, seat))
  if choice == 2: plan.dispatch = 40
  if choice == 3: plan.dispatch = 60
  doAssert planIsLegal(plan)
  plans[seat] = plan
  inc decisionId
  inc seat
  if seat == Seats:
    let failure = runTurn(game, plans)
    doAssert failure.len == 0
    seat = 0
  let observation = if game.tick >= game.config.episodeTicks or game.finished:
    if not game.finished:
      endEpisode(game, "complete", "full_time")
    let scores = resultsJson(game)["scores"]
    var scoresBySeat = newJObject()
    var utilities = newJObject()
    for index in 0 ..< Seats:
      scoresBySeat[$index] = scores[index]
      utilities[$index] = %(scores[index].getFloat() / 100.0)
    %*{"kind": "terminal", "scores": scoresBySeat,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: gridlock-train-bridge MANIFEST [default|rush]", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["default", "rush"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
