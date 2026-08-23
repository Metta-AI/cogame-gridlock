## The observation contract: what a seat can see, what it cannot, and the
## two-name-space assertion.

import std/[json, strutils, unittest]
import support/helpers

proc allStrings(node: JsonNode, into: var seq[string]) =
  case node.kind
  of JString: into.add(node.getStr())
  of JObject:
    for key, value in node.pairs:
      into.add(key)
      allStrings(value, into)
  of JArray:
    for child in node.items:
      allStrings(child, into)
  else: discard

suite "the per-seat view":
  setup:
    var game = newTestSim(960, 42)
    for _ in 0 ..< 3:
      discard runTurn(game, scriptedPlansFor(game, allKinds(skDispatcher)))

  test "events_last_turn covers the turn that just played, and only it":
    ## `buildView` runs before `installPlans` advances the turn, so the
    ## window is `[sim.turn * turnTicks, +turnTicks)`. A window one turn wider
    ## reports a jam that cleared two turns ago as if it were current.
    let lower = game.turn * game.config.turnTicks
    check lower > 0
    ## Plant one describable event inside the window and one just before it.
    game.events.add(newEvent(seJam, lower - 1, game.turn - 1, %*{
      "lane": 0, "from": "0,0", "to": "1,0", "class": "local", "q": 12}))
    game.events.add(newEvent(seJam, lower + 5, game.turn, %*{
      "lane": 1, "from": "1,0", "to": "2,0", "class": "arterial", "q": 13}))
    let lines = eventsLastTurn(game, 6)
    check lines.len >= 1
    for line in lines:
      check not line.contains("0,0->1,0")
    check lines[0].contains("1,0->2,0")


    let view = buildView(game, 0)
    for key in ["turn", "of", "tick", "ticks_left", "seconds_left", "you",
        "city", "fleets", "events_last_turn"]:
      check view.hasKey(key)
    for key in ["fleet", "colour", "depot", "depot_district", "vans",
        "docked", "loading", "waiting_dispatch", "on_road_loaded",
        "on_road_empty", "stalled", "delivered", "delivered_last_turn",
        "backlog", "mean_trip_seconds", "stalled_pct", "last_plan",
        "next_orders"]:
      check view["you"].hasKey(key)
    for key in ["grid", "districts", "lane_cells", "arterial_cols",
        "arterial_rows", "signal", "discharge_per_green_step", "jam_index",
        "districts_heat", "hot_lanes"]:
      check view["city"].hasKey(key)

  test "a view never contains a rival's plan, backlog or destinations":
    let view = buildView(game, 0)
    let text = $view
    ## Only the seat's OWN plan appears, under you.last_plan.
    check not text.contains("\"rival\"")
    for other in 1 ..< Seats:
      let otherPlan = $planJson(game.plans[other])
      if game.plans[other] != game.plans[0]:
        check not text.contains(otherPlan)
    ## fleets[] is public but carries exactly two numbers per fleet.
    check view["fleets"].len == Seats
    for entry in view["fleets"]:
      check entry.len == 3
      check entry.hasKey("fleet")
      check entry.hasKey("delivered")
      check entry.hasKey("on_road")
    ## next_orders are this seat's own, capped at six.
    check view["you"]["next_orders"].len <= 6
    var ownIds: seq[int]
    for parcel in game.backlog[0]:
      ownIds.add(parcel.id)
    for entry in view["you"]["next_orders"]:
      check entry["id"].getInt() in ownIds

  test "no lane readout carries a per-fleet composition":
    let view = buildView(game, 0)
    for lane in view["city"]["hot_lanes"]:
      check not lane.hasKey("fleets")
      check not lane.hasKey("owners")
      for key, _ in lane.pairs:
        check key in ["from", "to", "class", "q", "cap", "blocked_s"]

  test "hot_lanes is sorted worst first and capped at eight":
    let view = buildView(game, 0)
    let lanes = view["city"]["hot_lanes"]
    check lanes.len <= 8
    for i in 1 ..< lanes.len:
      check lanes[i - 1]["q"].getInt() >= lanes[i]["q"].getInt()
    for lane in lanes:
      check lane["q"].getInt() >= 1
      check lane["cap"].getInt() == game.config.laneCells

  test "districts_heat digits match a hand-computed occupancy":
    ## Plant a known occupancy and recompute the digits by hand.
    var planted = newTestSim(240, 1)
    let cells = planted.config.laneCells
    var g = 0
    for lane in 0 ..< LaneCount:
      if districtOfNode(laneOf(lane).head) != districtIndex(1, 1):
        continue
      if g + cells > planted.vehicles.len:
        break
      for cell in 0 ..< cells:
        planted.putVan(g, lane, cell)
        inc g
      break
    accumulateStats(planted)
    refreshHeat(planted)
    var sum = 0
    var count = 0
    for lane in 0 ..< LaneCount:
      if districtOfNode(laneOf(lane).head) == districtIndex(1, 1):
        sum += planted.laneOccAccum[lane]
        inc count
    let pct = (sum * 100) div (count * planted.occSamples * cells)
    check planted.districtHeat[districtIndex(1, 1)] == min(9, pct div 10)
    let view = buildView(planted, 0)
    let row = view["city"]["districts_heat"][1].getStr()
    check row.len == 3
    check row[1] == char(ord('0') + planted.districtHeat[districtIndex(1, 1)])

  test "jam_index and stalled_pct match hand-counted opportunities":
    var planted = newTestSim(240, 2)
    let lane = laneBetween(nodeIndex(0, 0), nodeIndex(1, 0))
    let cells = planted.config.laneCells
    ## One van at the stop line: it can never advance, so every move
    ## opportunity it gets is a blocked one.
    planted.putVan(0, lane, cells - 1)
    for _ in 0 ..< 96:
      inc planted.tick
      moveStep(planted)
      accumulateStats(planted)
    refreshHeat(planted)
    check planted.moveOpp > 0
    check planted.blockedOpp == planted.moveOpp
    check planted.jamIndex == 100
    check planted.ownStallPct[0] == 100
    for seat in 1 ..< Seats:
      check planted.ownStallPct[seat] == 0

  test "an empty city has a zero jam index":
    var quiet = newTestSim(240, 3)
    for _ in 0 ..< 48:
      inc quiet.tick
      accumulateStats(quiet)
    refreshHeat(quiet)
    check quiet.jamIndex == 0

suite "two name spaces":
  test "no view, event body or prompt in a whole episode carries a real name":
    var game = newTestSim(episodeTicks(2400), 42)
    game.names = ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
    game.policyKinds = ["llm", "llm", "scripted", "scripted"]
    runScripted(game, allKinds(skDispatcher))
    let results = resultsJson(game)
    var forbidden: seq[string]
    for entry in results["names"]:
      forbidden.add(entry.getStr())
    check forbidden.len == Seats

    var haystack: seq[string]
    for seat in 0 ..< Seats:
      allStrings(buildView(game, seat), haystack)
    for event in game.events:
      allStrings(jsonRow(event), haystack)
    for text in haystack:
      for name in forbidden:
        check not text.contains(name)

    ## The aliases ARE there, and they belong to the depot, not the seat.
    var sawAlias = false
    for seat in 0 ..< Seats:
      let view = buildView(game, seat)
      check view["you"]["fleet"].getStr() ==
        FleetAliases[game.seatDepot[seat]]
      for entry in view["fleets"]:
        if entry["fleet"].getStr() in FleetAliases:
          sawAlias = true
    check sawAlias

  test "the seat to depot permutation is re-drawn per episode":
    var seen: seq[array[Seats, int]]
    for seed in 1 .. 24:
      let game = newTestSim(240, seed)
      var mapping: array[Seats, int]
      for seat in 0 ..< Seats:
        mapping[seat] = game.seatDepot[seat]
      var sortedCheck: array[Seats, bool]
      for seat in 0 ..< Seats:
        check not sortedCheck[mapping[seat]]
        sortedCheck[mapping[seat]] = true
      seen.add(mapping)
    var novelCount = 0
    for i in 0 ..< seen.len:
      var novel = true
      for j in 0 ..< i:
        if seen[j] == seen[i]: novel = false
      if novel: inc novelCount
    check novelCount > 1
