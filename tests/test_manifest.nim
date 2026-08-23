## The manifest contract: num_agents everywhere, the closed results schema,
## both protocols, real docs, the static bundle, and the image placeholder
## that has to match the compose service name.

import std/[json, os, sets, strutils, unittest]
import support/helpers

let manifest = parseJson(readSource("coworld_manifest_template.json"))
let compose = readSource("compose.yaml")

suite "seat count":
  test "num_agents is 4 in every variant AND in the certification fixture":
    check manifest["variants"].len >= 1
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == 4
      check variant["game_config"]["players"].len == 4
      check variant.hasKey("id")
      check variant.hasKey("name")
      check variant["description"].getStr().len > 0
    check manifest["certification"]["game_config"]["num_agents"].getInt() == 4

  test "the certification fixture seats exactly num_agents players":
    check manifest["certification"]["players"].len == 4
    check manifest["certification"]["game_config"]["players"].len == 4

  test "every declared player entry occupies at least one certification slot":
    var seated = initHashSet[string]()
    for entry in manifest["certification"]["players"]:
      seated.incl(entry["player_id"].getStr())
    check manifest["player"].len >= 1
    for declared in manifest["player"]:
      check declared["id"].getStr() in seated
      check declared["type"].getStr() == "player"
      check declared["name"].getStr().len > 0
      check declared["description"].getStr().len > 0

  test "SMOKE_SEATS in docker_smoke.sh agrees with the fixture":
    let smoke = readSource("tools/ci/docker_smoke.sh")
    check smoke.contains("seats_expected=\"${SMOKE_SEATS:-4}\"")

suite "packaging":
  test "the replay viewer is the static bundle, never a pod":
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"

  test "the runnable is a game and carries the secret URI":
    let runnable = manifest["game"]["runnable"]
    check runnable["type"].getStr() == "game"
    check runnable["run"][0].getStr() == "/bin/gridlock"
    check runnable["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/gridlock/anthropic_api_key"
    check runnable["source_url"].getStr().contains("cogame-gridlock")

  test "the image placeholder matches the compose service name":
    ## Placeholders are derived from compose service names: service `gridlock`
    ## gives `{{GRIDLOCK_IMAGE}}`. `{{GAME_IMAGE}}` is not a thing.
    check compose.contains("  gridlock:")
    check compose.contains("image: coworld-gridlock:latest")
    check compose.contains("platform: linux/amd64")
    check compose.contains("network: host")
    check manifest["game"]["runnable"]["image"].getStr() ==
      "{{GRIDLOCK_IMAGE}}"
    for declared in manifest["player"]:
      check declared["image"].getStr() == "{{GRIDLOCK_IMAGE}}"

  test "the top-level shape the upload contract requires is present":
    check manifest.hasKey("$schema")
    check manifest["tags"].len >= 3
    check manifest["episode_timeout_minutes"].getInt() == 20
    check manifest["game"]["name"].getStr() == "gridlock"
    check manifest["game"]["owner"].getStr().len > 0

suite "schemas":
  test "config_schema is a real JSON Schema and covers every variant key":
    let schema = manifest["game"]["config_schema"]
    check schema["$schema"].getStr().contains("json-schema.org")
    check schema["type"].getStr() == "object"
    check schema["additionalProperties"].getBool() == false
    let properties = schema["properties"]
    check properties["num_agents"]["minimum"].getInt() == 4
    check properties["num_agents"]["maximum"].getInt() == 4
    for variant in manifest["variants"]:
      for key, _ in variant["game_config"].pairs:
        check properties.hasKey(key)
    for key, _ in manifest["certification"]["game_config"].pairs:
      check properties.hasKey(key)

  test "every variant validates against the documented ranges":
    let properties = manifest["game"]["config_schema"]["properties"]
    for variant in manifest["variants"]:
      for key, value in variant["game_config"].pairs:
        let rule = properties[key]
        if value.kind in {JInt, JFloat} and rule.hasKey("minimum"):
          check value.getFloat() >= rule["minimum"].getFloat()
          check value.getFloat() <= rule["maximum"].getFloat()

  test "every variant stays inside 60% of the platform episode timeout":
    let ceiling = 0.6 * float(manifest["episode_timeout_minutes"].getInt() * 60)
    check ceiling == 720.0
    for variant in manifest["variants"]:
      check variant["game_config"]["wallClockBudgetSeconds"].getFloat() <=
        ceiling
    check manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getFloat() <= ceiling

  test "results_schema keys equal the keys the results builder emits":
    var game = newTestSim(480, 5)
    runScripted(game, allKinds(skDispatcher))
    let emitted = resultsJson(game)
    let schema = manifest["game"]["results_schema"]
    check schema["additionalProperties"].getBool() == false
    var declared = initHashSet[string]()
    for key, _ in schema["properties"].pairs:
      declared.incl(key)
    var produced = initHashSet[string]()
    for key, _ in emitted.pairs:
      produced.incl(key)
    check declared == produced
    var required = initHashSet[string]()
    for key in schema["required"]:
      required.incl(key.getStr())
    check required == produced
    check schema["properties"]["reason"]["enum"].len == 3
    check schema["properties"]["end_rule"]["enum"].len == 4

suite "docs and protocols":
  test "game.protocols carries BOTH player and global as text":
    let protocols = manifest["game"]["protocols"]
    for key in ["player", "global"]:
      check protocols.hasKey(key)
      check protocols[key]["type"].getStr() == "text"
      check protocols[key]["value"].getStr().len > 400
    check protocols["player"]["value"].getStr().contains("register")
    check protocols["global"]["value"].getStr().contains(
      "static-replay-viewer")

  test "game.docs.readme and both pages are non-empty text":
    let docs = manifest["game"]["docs"]
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 500
    check docs["pages"].len == 2
    for page in docs["pages"]:
      check page["id"].getStr().len > 0
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 500

  test "the inlined docs match the committed files":
    let docs = manifest["game"]["docs"]
    check docs["readme"]["value"].getStr() == readSource("README.md")
    for page in docs["pages"]:
      let path =
        if page["id"].getStr() == "rules.md": "docs/RULES.md"
        else: "docs/PROTOCOL.md"
      check page["content"]["value"].getStr() == readSource(path)

suite "policies":
  test "two LLM champions and two scripted fillers, one image, env-switched":
    let policies = parseJson(readSource("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var owned = 0
    var names = initHashSet[string]()
    for policy in policies:
      check policy["run"].getStr() == "/bin/gridlock-player"
      check policy["name"].getStr().startsWith("gridlock-")
      check not names.contains(policy["name"].getStr())
      names.incl(policy["name"].getStr())
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check parseScriptKind(policy["env"]["PLAYER_SCRIPTED"].getStr()) !=
          skNone
      if policy.hasKey("player"):
        inc owned
        check policy["player"].getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check prompts == 2
    check scripted == 2
    check owned == 1

  test "the two champion prompts are different":
    let policies = parseJson(readSource("tools/ci/policies.json"))
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()

  test "no unsubstituted scaffold placeholder survives":
    for path in [".github/workflows/ci.yml",
        ".github/workflows/coworld-release.yml",
        ".github/workflows/coworld-submit.yml",
        "tools/ci/docker_smoke.sh", "tools/ci/policies.json"]:
      let source = readSource(path)
      check not source.contains("<slug>")
      check not source.contains("<IMAGE>")
      check not source.contains("<SEATS>")

  test "the scaffold hooks are committed executable":
    for path in ["tools/build_replay_viewer.sh", "tools/ci/docker_smoke.sh"]:
      check fileExists(path)
      let permissions = getFilePermissions(path)
      check fpUserExec in permissions
      check fpGroupExec in permissions
      check fpOthersExec in permissions
