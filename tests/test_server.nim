## The websocket and HTTP contract, and the shapes the platform's probes
## depend on.
##
## The live socket round trip is exercised for real by
## `tools/ci/docker_smoke.sh`, which runs the production image with one game
## container and four player containers on a shared network. What this file
## pins is everything that can be checked without a socket: the auth
## decisions, the artifact-sink policy, the two /client pages that the episode
## runner probes BEFORE any player pod starts (and which must not seat
## anybody), the shutdown grace, and the frames the protocol promises.

import std/[json, strutils, unittest]
import support/helpers
import gridlock/roster
import gridlock/render
import gridlock/wire_constants

let serverSource = readSource("src/gridlock/server.nim")

suite "routes":
  test "every documented route is registered":
    for route in ["\"/healthz\"", "\"/client/player\"", "\"/client/global\"",
        "\"/client/replay\"", "\"/client/asset/@name\"", "\"/global\"",
        "\"/player\"", "\"/replay-data\""]:
      check serverSource.contains(route)

  test "the two client pages are registered before any catch-all asset route":
    ## A 404 on either is a game_contract_violation: the episode runner probes
    ## both before starting player pods (playbook gotcha, lantern 0.1.1).
    let player = serverSource.find("result.get(\"/client/player\"")
    let global = serverSource.find("result.get(\"/client/global\"")
    let asset = serverSource.find("result.get(\"/client/asset/@name\"")
    check player >= 0
    check global >= 0
    check asset > player
    check asset > global

  test "the player socket is only registered outside replay mode":
    let index = serverSource.find("if replayMode:")
    check index > 0
    let tail = serverSource[index .. ^1]
    check tail.contains("result.get(\"/player\", playerUpgradeHandler)")
    check tail.find("replay-data") < tail.find("/player\", playerUpgradeHandler")

  test "neither client page opens the player socket":
    let playerPage = readSource("client/player.html")
    ## It documents the route, but it never opens it: no script, no socket.
    check not playerPage.contains("new WebSocket")
    check not playerPage.contains("<script")
    let globalPage = readSource("client/global.html")
    check globalPage.contains("'/global'")
    check not globalPage.contains("/player?slot=")

  test "a bad slot or token is 403 and a duplicate connection is 409":
    check serverSource.contains("request.respond(403)")
    check serverSource.contains("request.respond(409)")

  test "/global answers a Ping with a Pong":
    check serverSource.contains("websocket.send(message.data, Pong)")

  test "the shutdown grace keeps healthz and global answering":
    check serverSource.contains("ShutdownGraceSeconds = 20.0")
    let finish = serverSource.find("proc finishEpisode")
    check finish > 0
    let body = serverSource[finish .. ^1]
    ## Order: broadcast done -> write the replay -> write the results -> grace.
    let done = body.find("\"done\": true")
    let replay = body.find("writeReplay")
    let results = body.find("writeResults")
    let grace = body.find("ShutdownGraceSeconds")
    check done >= 0
    check replay > done
    check results > replay
    check grace > results
    check body.find("quit(0)") > grace

suite "auth and registration":
  test "the register frame is accepted and its fields are applied":
    var seats = initRoster(@["t0", "t1", "t2", "t3"])
    seats.applyRegistration(1, %*{
      "type": "register", "prompt": "route around the arterial cross",
      "scripted": newJNull(), "policy": "gridlock-backstreet"})
    check seats.seats[1].registered
    check seats.seats[1].prompt.contains("arterial")
    check seats.seats[1].policyLabel == "gridlock-backstreet"
    check policyKindOf(seats.seats[1]) == "llm"

  test "a frame that is not a register frame is ignored":
    var seats = initRoster(@["t0", "t1", "t2", "t3"])
    seats.applyRegistration(0, %*{"type": "chat", "prompt": "hello"})
    check not seats.seats[0].registered
    seats.applyRegistration(0, newJNull())
    check not seats.seats[0].registered

  test "the policy label is rune-capped at 48":
    var seats = initRoster(@["t0", "t1", "t2", "t3"])
    var label = ""
    for _ in 0 ..< 300:
      label.add("z")
    seats.applyRegistration(0, %*{"type": "register", "policy": label})
    check seats.seats[0].policyLabel.len == MaxPolicyRunes

suite "artifact sinks":
  test "COGAME_EVENTS_URI and COGAME_METRICS_URI are file:// only":
    check fileUriProblem("COGAME_EVENTS_URI", "") == ""
    check fileUriProblem("COGAME_EVENTS_URI", "file:///coworld/events.jsonl") == ""
    check fileUriProblem("COGAME_EVENTS_URI",
      "https://example.invalid/events").len > 0
    check fileUriProblem("COGAME_METRICS_URI", "s3://bucket/metrics").len > 0
    check fileUriProblem("COGAME_METRICS_URI",
      "https://example.invalid/m").contains("COGAME_METRICS_URI")

suite "the frames the protocol promises":
  setup:
    var game = newTestSim(960, 42)
    game.names = ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
    discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))

  test "the spectator meta frame carries the geometry and the names":
    let meta = metaJson(game, newJObject())
    check meta["type"].getStr() == "meta"
    check meta["board"][0].getInt() == MapWidth
    check meta["lanes"].len == LaneCount
    check meta["depots"].len == Seats
    check meta["players"].len == Seats
    check meta["players"][0].getStr() == "daveey"
    check meta["aliases"][0].getStr() == FleetAliases[game.seatDepot[0]]
    check meta["protocol"].getStr() == ReplayProtocol

  test "the spectator frame carries the whole board state":
    let frame = frameJson(game, 0)
    check frame["type"].getStr() == "frame"
    check frame["q"].len == LaneCount
    check frame["v"].len == Seats * game.config.fleetSize * 3
    check frame["delivered"].len == Seats
    check frame["plans"].len == Seats
    check frame["digits"].len == DistrictCount
    check frame["events"].len > 0
    check frame["event_cursor"].getInt() == game.events.len

  test "the served replay page splices all three chrome markers":
    let page = readSource("client/replay_broadcast.html")
    check page.contains("<!-- WIRE_CONSTANTS -->")
    check page.contains("<!-- CHROME_COMMON -->")
    check page.contains("<!-- BROADCAST_CORE -->")

  test "the wire constants block names the engine constants once":
    check WireConstantsJs.startsWith("window.GRIDLOCK_WIRE={")
    check WireConstantsJs.contains("fps:24")
    check WireConstantsJs.contains("laneCount:288")
    check WireConstantsJs.contains("seats:4")
