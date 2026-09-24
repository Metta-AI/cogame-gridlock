## Export complete native Gridlock matches as Metta post-training examples.
## nim c -d:release --path:src -o:/tmp/gridlock-posttrain tools/export_posttrain.nim

import std/[json, os, osproc, strutils]
import gridlock/[sim, llm]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: gridlock-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
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
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.validate()
    var game = initSim(config, loadCitySpec(config.cityPath))
    game.keepSnapshots = false
    var rows: seq[string]
    while game.tick < config.episodeTicks and not game.finished:
      var plans: array[Seats, RoutingPlan]
      for seat in 0 ..< Seats:
        let view = $buildView(game, seat)
        let teacher = dispatcherPlan(baselineInput(game, seat))
        let reply = $planJson(teacher)
        let accepted = parsePlan(reply, game.plans[seat])
        doAssert planIsLegal(accepted)
        plans[seat] = accepted
        rows.add($(%*{
          "episode_id": "gridlock-" & variant & "-" & $seed,
          "seed": "gridlock-" & variant & "-" & $seed,
          "decision_id": game.tick div config.turnTicks * Seats + seat,
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
    doAssert game.tick == config.episodeTicks
    if not game.finished:
      endEpisode(game, "complete", "full_time")
    let scores = resultsJson(game)["scores"]
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "turns": rows.len div Seats,
      "scores": scores})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "gridlock",
    "variant": variant,
    "source_revision": revision,
    "teacher": "dispatcher",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
