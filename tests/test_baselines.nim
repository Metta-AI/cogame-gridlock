## The bounded-orders / legality assertion on the scripted baselines, and the
## ordering that gives the ladder a spread.

import std/[json, tables, unicode, unittest]
import support/helpers

proc randomInput(rng: var Pcg32): BaselineInput =
  result.jamIndex = rng.rand(101)
  for d in 0 ..< DistrictCount:
    result.digits[d] = rng.rand(10)
  result.backlog = rng.rand(120)
  result.depotDistrict = rng.rand(DistrictCount)
  result.stalledPct = rng.rand(101)
  for _ in 0 ..< rng.rand(7):
    result.nextDestDistricts.add(rng.rand(DistrictCount))

suite "bounded, legal orders":
  test "500 random views x both baselines emit a schema-legal plan":
    var rng = initPcg32(4242)
    for _ in 0 ..< 500:
      let input = randomInput(rng)
      for kind in [skDispatcher, skBeeline]:
        let plan = scriptedPlan(input, kind)
        check plan.congestionWeight in 0 .. 100
        check plan.patience in 0 .. 100
        check plan.dispatch in 0 .. 100
        check plan.spread in 0 .. 100
        check plan.corridor in -1 .. (DistrictCount - 1)
        check plan.avoid in -1 .. (DistrictCount - 1)
        check plan.avoid < 0 or plan.avoid != plan.corridor
        check plan.priority in {prNear, prFar, prFifo}
        check plan.note.runeLen <= MaxNoteRunes
        check plan.say.runeLen <= MaxSayRunes
        check planIsLegal(plan)

  test "the derived router quantities stay inside their stated ranges":
    var rng = initPcg32(99)
    var occupancy = newSeq[int](LaneCount)
    var noise = newSeq[int](Seats * LaneCount)
    for i in 0 ..< noise.len:
      noise[i] = rng.rand(4)
    for _ in 0 ..< 200:
      let input = randomInput(rng)
      for kind in [skDispatcher, skBeeline]:
        let plan = scriptedPlan(input, kind)
        check replanQueue(plan) in 3 .. 13
        check activeCap(plan, 50) in 0 .. 50
        check releasePerStep(plan) in 1 .. 6
        for q in [0, 7, 14]:
          for id in 0 ..< LaneCount:
            occupancy[id] = q
          for id in 0 ..< LaneCount:
            let cost = laneCost(id, plan, occupancy[id], noise[id])
            check cost > 0
            check cost <= 1200

  test "the dispatcher meters itself as the jam index climbs":
    var input = BaselineInput(jamIndex: 0, backlog: 0, depotDistrict: 0)
    check dispatcherPlan(input).dispatch == 100
    input.jamIndex = 40
    check dispatcherPlan(input).dispatch == 80
    input.jamIndex = 60
    check dispatcherPlan(input).dispatch == 60
    input.jamIndex = 80
    check dispatcherPlan(input).dispatch == 45
    input.jamIndex = 90
    check dispatcherPlan(input).congestionWeight == 95

  test "the dispatcher avoids the worst district unless it needs it":
    var input = BaselineInput(jamIndex: 50, backlog: 0, depotDistrict: 0)
    input.digits[districtIndex(2, 2)] = 9
    check dispatcherPlan(input).avoid == districtIndex(2, 2)
    ## Not when the depot is there.
    input.depotDistrict = districtIndex(2, 2)
    check dispatcherPlan(input).avoid == -1
    ## Not when the next six destinations need it.
    input.depotDistrict = 0
    input.nextDestDistricts = @[districtIndex(2, 2)]
    check dispatcherPlan(input).avoid == -1
    ## Not when nothing is bad enough.
    input.nextDestDistricts = @[]
    input.digits[districtIndex(2, 2)] = 6
    check dispatcherPlan(input).avoid == -1

  test "the dispatcher takes far parcels only on a deep backlog":
    var input = BaselineInput(jamIndex: 10, backlog: 10, depotDistrict: 0)
    check dispatcherPlan(input).priority == prNear
    input.backlog = 56
    check dispatcherPlan(input).priority == prFar

  test "beeline is unconditional greed":
    var rng = initPcg32(5)
    for _ in 0 ..< 50:
      let plan = beelinePlan()
      check plan.congestionWeight == 0
      check plan.patience == 100
      check plan.dispatch == 100
      check plan.spread == 0
      check plan.corridor == -1
      check plan.avoid == -1
      check plan.priority == prFifo
      let other = scriptedPlan(randomInput(rng), skBeeline)
      check other.congestionWeight == plan.congestionWeight
      check other.dispatch == plan.dispatch

  test "PLAYER_SCRIPTED parsing follows the documented values":
    check parseScriptKind("dispatcher") == skDispatcher
    check parseScriptKind("1") == skDispatcher
    check parseScriptKind("true") == skDispatcher
    check parseScriptKind("YES") == skDispatcher
    check parseScriptKind("beeline") == skBeeline
    check parseScriptKind(" Beeline ") == skBeeline
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone

suite "the shipped tuning is the grid's tuning":
  ## `tools/tune_baselines.nim` sweeps every constant in `dispatcherPlan`
  ## across three loads x three seeds and validates its challengers on three
  ## held-out seeds; `tools/tuning/dispatcher_grid.{md,json}` is that run.
  ## This is what keeps the two in step: a hand-edited constant that the grid
  ## never chose fails here.
  let grid = parseJson(readSource("tools/tuning/dispatcher_grid.json"))

  test "every shipped constant is the one the committed grid picked":
    let winner = grid["winner"]["tuning"]
    let shipped = DefaultDispatcherTuning
    check winner["weightBase"].getInt() == shipped.weightBase
    check winner["weightMin"].getInt() == shipped.weightMin
    check winner["weightMax"].getInt() == shipped.weightMax
    check winner["patienceJam"].getInt() == shipped.patienceJam
    check winner["patienceCalm"].getInt() == shipped.patienceCalm
    check winner["patienceJammed"].getInt() == shipped.patienceJammed
    check winner["dispatchJam1"].getInt() == shipped.dispatchJam1
    check winner["dispatchJam2"].getInt() == shipped.dispatchJam2
    check winner["dispatchJam3"].getInt() == shipped.dispatchJam3
    check winner["dispatchCalm"].getInt() == shipped.dispatchCalm
    check winner["dispatchBusy"].getInt() == shipped.dispatchBusy
    check winner["dispatchHeavy"].getInt() == shipped.dispatchHeavy
    check winner["dispatchSevere"].getInt() == shipped.dispatchSevere
    check winner["spreadJam"].getInt() == shipped.spreadJam
    check winner["spreadCalm"].getInt() == shipped.spreadCalm
    check winner["spreadJammed"].getInt() == shipped.spreadJammed
    check winner["avoidDigit"].getInt() == shipped.avoidDigit
    check winner["farBacklog"].getInt() == shipped.farBacklog

  test "the grid actually swept, and the baselines are ordered in it":
    check grid["grid"].len >= 135
    check grid["seeds"].len >= 3
    check grid["loads"].len >= 3
    ## Held-out seeds are disjoint from the tuning seeds, or the sweep is
    ## validating on what it fitted.
    for seed in grid["validation_seeds"]:
      check seed notin grid["seeds"].elems
    ## And the grid records the thesis the ladder rests on: four greedy
    ## fleets deliver far less than four metered ones.
    check grid["beeline_reference"].getInt() < grid["shipped"].getInt()

  test "the shipped values beat the grid's neighbours where it discriminates":
    ## Not every constant moves the score — 200 vans cannot fill 288 lanes,
    ## so the deep-jam half of the ladder is inert at the shipped scale and
    ## the grid says so. These two do move it, and the shipped value wins.
    var scores: Table[string, int]
    for row in grid["grid"]:
      scores[row["label"].getStr()] = row["total"].getInt()
    check scores["dispatchJam1=25"] < grid["shipped"].getInt()
    check scores["farBacklog=40"] < grid["shipped"].getInt()

suite "the baselines are ordered, and greed costs the city":
  ## Rush-hour demand — an order every 12 ticks, exactly the `rush` variant's
  ## rate. The ordering is a claim about a city UNDER LOAD: at the default
  ## rate the fleets are order-limited rather than congestion-limited and all
  ## four simply clear their whole backlog, so the claim has nothing to bite
  ## on. Measured across seeds 42 / 7 / 1234 / 99 and 960 / 1920 / 4800 ticks.
  test "dispatcher seats out-deliver beeline seats at the same seed":
    var game = newTestSim(episodeTicks(4800), 42, orderPeriodTicks = 12)
    runScripted(game, kindsOf(skDispatcher, skBeeline, skDispatcher,
      skBeeline))
    check game.reason == "complete"
    let dispatched = game.delivered[0] + game.delivered[2]
    let greedy = game.delivered[1] + game.delivered[3]
    check dispatched > greedy

  test "an all-beeline city delivers fewer parcels than an all-dispatcher one":
    ## The idea's thesis, expressed as an assertion.
    var metered = newTestSim(episodeTicks(4800), 42, orderPeriodTicks = 12)
    runScripted(metered, allKinds(skDispatcher))
    var greedy = newTestSim(episodeTicks(4800), 42, orderPeriodTicks = 12)
    runScripted(greedy, allKinds(skBeeline))
    check totalDelivered(greedy) < totalDelivered(metered)
