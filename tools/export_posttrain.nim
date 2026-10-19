## Export complete native Gridlock matches as Metta post-training examples.
## nim c -d:release --path:src -o:/tmp/gridlock-posttrain tools/export_posttrain.nim

import std/[json, options, os, strutils, sequtils]
import gridlock/[sim, llm, replay, prompts, prompt_evidence]
import bitworld/decision_trajectory

when isMainModule:
  let args = commandLineParams()
  if args.len notin [5, 7]:
    quit("usage: gridlock-posttrain OUTPUT EPISODES VARIANT GAME_VERSION SOURCE_REVISION [PROMPT_VARIANT PROMPT_SEED]", 1)
  let configured = promptSelection(if args.len == 7:
    %*{"promptVariant": args[5], "promptSeed": parseInt(args[6])} else: newJObject())
  doAssert configured.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference}, "held-out wording is evaluation only"
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let gameVersion = args[3]
  let revision = args[4]
  if revision.len != 40 or revision.anyIt(it notin {'0'..'9', 'a'..'f'}):
    quit("SOURCE_REVISION must be the reviewed immutable 40-hex source commit", 1)
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
  var
    teacherDecisions = 0
    trajectoryRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    var selection = configured
    if selection.variant == pvMixed: selection.seed += seed - 1
    let system = selection.systemPrompt()
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.validate()
    var game = initSim(config, loadCitySpec(config.cityPath))
    game.keepSnapshots = false
    let episodeId = "gridlock-" & variant & "-" & $seed & "-" & $selection.selectedVariant
    let trajectory = newDecisionTrajectory(episodeId, "gridlock-" & $seed,
      "gridlock", gameVersion, revision)
    var episodeDecisions = 0
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
        attempt.prompt = %*[{"role": "system", "content": system},
          {"role": "user", "content": view}]
        attempt.response = %reply
        attempt.parsedAction = planJson(accepted)
        attempt.accepted = true
        attempts[seat] = attempt
        inc teacherDecisions
        inc episodeDecisions
      let failure = runTurn(game, plans)
      doAssert failure.len == 0
      doAssert game.tick == min(config.episodeTicks, startTick + config.turnTicks)
      for seat in 0 ..< Seats:
        trajectory.recordDecision($startTick & "-" & $seat, $seat,
          promptObservation(views[seat], selection, @[attempts[seat]]),
          @[attempts[seat]], some(attempts[seat].attemptId), planJson(game.plans[seat]),
          asAccepted, terminal = game.tick >= config.episodeTicks)
    doAssert game.tick == config.episodeTicks
    if not game.finished:
      endEpisode(game, "complete", "full_time")
    let outcome = resultsJson(game)
    writePrivate(output / (episodeId & ".replay.json"), replayBytes(game, outcome))
    outcome["prompt_selection"] = selection.selectionMetadata()
    outcome["engine_rules_version"] = %GameVersion
    let scores = outcome["scores"]
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = scores[seat]
    trajectory.finish(esCompleted, outcome, outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    runs.add(%*{"seed": seed, "turns": episodeDecisions div Seats,
      "scores": scores})
  writePrivate(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "prompt_selection": configured.selectionMetadata(),
    "review_required": true,
    "game": "gridlock",
    "variant": variant,
    "source_revision": revision,
    "game_version": gameVersion,
    "engine_rules_version": GameVersion,
    "teacher": "dispatcher-view",
    "episodes": episodes,
    "decisions": teacherDecisions,
    "dataset_path": "canonical-trajectories-only; shared reviewed importer owns splits",
    "runs": runs
  }) & "\n")
  echo "episodes=", episodes, " decisions=", teacherDecisions
