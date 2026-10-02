## Export complete native Gridlock matches as Metta post-training examples.
## nim c -d:release --path:src -o:/tmp/gridlock-posttrain tools/export_posttrain.nim

import std/[json, options, os, osproc, strutils]
import gridlock/[sim, llm]
import bitworld/decision_trajectory

when isMainModule:
  let args = commandLineParams()
  if args.len != 4:
    quit("usage: gridlock-posttrain OUTPUT EPISODES VARIANT GAME_VERSION", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let gameVersion = args[3]
  doAssert gameVersion.len > 0
  if episodes < 10:
    quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    trajectoryRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.validate()
    var game = initSim(config, loadCitySpec(config.cityPath))
    game.keepSnapshots = false
    let episodeId = "gridlock-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "gridlock-" & $seed,
      "gridlock", gameVersion, revision)
    var rows: seq[string]
    while game.tick < config.episodeTicks and not game.finished:
      let startTick = game.tick
      var views: array[Seats, JsonNode]
      var attempts: array[Seats, DecisionAttempt]
      var plans: array[Seats, RoutingPlan]
      for seat in 0 ..< Seats:
        let observation = buildView(game, seat)
        views[seat] = observation
        let view = userMessage(SeatRequest(viewJson: $observation), false)
        let teacher = dispatcherPlan(baselineInput(observation))
        let reply = $planJson(teacher)
        let accepted = parsePlan(reply, game.plans[seat])
        doAssert planIsLegal(accepted)
        plans[seat] = accepted
        var attempt = newDecisionAttempt($startTick & "-" & $seat & "-teacher",
          "dispatcher-view", aoTeacher)
        attempt.model = some("dispatcher-view")
        attempt.modelIdentity = some(revision)
        attempt.prompt = %*[{"role": "system", "content": SystemPrompt},
          {"role": "user", "content": view}]
        attempt.request = %*{"teacher": "dispatcher-view", "observation": observation}
        attempt.response = %reply
        attempt.rawResponse = %reply
        attempt.decoder = %*{"method": "deterministic"}
        attempt.parsedAction = planJson(accepted)
        attempt.accepted = true
        attempts[seat] = attempt
        rows.add($(%*{
          "episode_id": "gridlock-" & variant & "-" & $seed,
          "seed": "gridlock-" & $seed,
          "decision_id": game.tick div config.turnTicks * Seats + seat,
          "observation": observation,
          "prompt": [
            {"role": "system", "content": SystemPrompt},
            {"role": "user", "content": view}
          ],
          "completion": [{"role": "assistant", "content": reply}],
          "game": "gridlock",
          "action_schema_revision": "gridlock-routing-v1"
        }))
      let failure = runTurn(game, plans)
      doAssert failure.len == 0
      doAssert game.tick == min(config.episodeTicks, startTick + config.turnTicks)
      for seat in 0 ..< Seats:
        trajectory.recordDecision($startTick & "-" & $seat, $seat, views[seat],
          @[attempts[seat]], some(attempts[seat].attemptId), planJson(game.plans[seat]),
          asAccepted, terminal = game.tick >= config.episodeTicks)
    doAssert game.tick == config.episodeTicks
    if not game.finished:
      endEpisode(game, "complete", "full_time")
    let outcome = resultsJson(game)
    let scores = outcome["scores"]
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = scores[seat]
    trajectory.finish(esCompleted, outcome, outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "turns": rows.len div Seats,
      "scores": scores})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "gridlock",
    "variant": variant,
    "source_revision": revision,
    "game_version": gameVersion,
    "teacher": "dispatcher-view",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  for name in ["train.jsonl", "validation.jsonl", "trajectories.jsonl", "manifest.json"]:
    setFilePermissions(output / name, {fpUserRead, fpUserWrite})
  echo "train=", trainRows.len, " validation=", validationRows.len
