## Grid harness for the `dispatcher` baseline's parameters.
##
## Every constant in `dispatcherPlan` is a field of `DispatcherTuning`, so this
## sweeps the REAL baseline and not a copy of it. Each candidate tuning plays
## all-`dispatcher` episodes at three loads x three seeds and is scored by the
## total parcels delivered:
##
##   default  the shipped variant (50 vans, one order per fleet per 24 ticks)
##   rush     the shipped `rush` rate (one order per 12 ticks)
##   stress   200 vans and one order per 6 ticks — the only load at which the
##            city actually jams (200 vans on 288 lanes x 14 cells cannot fill
##            the network, so at the shipped scale the deep-jam half of the
##            ladder never engages). This is where the metering constants are
##            measured, and where four `beeline` seats collapse.
##
## The incumbent keeps a tie, and a challenger has to survive a HELD-OUT seed
## set: stages 1 and 2 rank on the tuning seeds, stage 3 replays the best
## challengers on three seeds the sweep never saw, and a challenger only
## replaces the shipped tuning if it wins on both sets by at least
## `MarginPct`% of the incumbent's total. Anything smaller is seed noise —
## the incumbent's own total moves by a few tenths of a percent between seed
## sets, which is the same size as the best challenger's edge.
##
##   nim c -d:release --path:src -o:tune tools/tune_baselines.nim
##   ./tune        > tools/tuning/dispatcher_grid.md
##   ./tune --json > tools/tuning/dispatcher_grid.json
##
## Those two files in this repo are that output, and `tests/test_baselines.nim`
## asserts the shipped `DefaultDispatcherTuning` is what the committed grid
## chose.

import std/[algorithm, json, os, strformat, strutils]
import gridlock/sim

const
  Seeds = [42, 7, 1234]
  ValidationSeeds = [5, 77, 2026]   ## disjoint from Seeds, never tuned on
  MarginPct = 1                     ## how much a challenger must win by
  EpisodeTicks = 4800
  Challengers = 5                   ## how many are replayed on the held-out set

type
  Load = object
    name: string
    fleetSize, orderPeriodTicks, backlogMax: int

  Outcome = object
    delivered: array[3, int]    ## per load, summed over the seeds
    total: int
    jamMean: int                ## the stress load's mean jam index
    gridlocks: int              ## the stress load's gridlock events

  Candidate = object
    label: string
    tuning: DispatcherTuning
    outcome: Outcome

const Loads = [
  Load(name: "default", fleetSize: 50, orderPeriodTicks: 24, backlogMax: 80),
  Load(name: "rush", fleetSize: 50, orderPeriodTicks: 12, backlogMax: 80),
  Load(name: "stress", fleetSize: 200, orderPeriodTicks: 6, backlogMax: 400)]

proc episodeConfig(load: Load, seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.numAgents = Seats
  result.fleetSize = load.fleetSize
  result.episodeTicks = EpisodeTicks
  result.turnTicks = 240
  result.orderPeriodTicks = load.orderPeriodTicks
  result.backlogMax = load.backlogMax
  result.minTurnSpacingSeconds = 0.0
  result.wallClockBudgetSeconds = 900.0
  result.playerConnectTimeoutSeconds = 0.0
  for i in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(i + 1)))
    result.tokens.add("token-" & $i)

proc play(load: Load, seed: int, tuning: DispatcherTuning, greedy: bool):
    tuple[delivered, jamMean, gridlocks: int] =
  ## One episode, all four seats on the same policy — the fair comparison, and
  ## the shape the ladder's all-scripted rounds actually play.
  var game = initSim(episodeConfig(load, seed), loadCitySpec("gridcity"))
  game.keepSnapshots = false
  while game.tick < game.config.episodeTicks and not game.finished:
    var plans: array[Seats, RoutingPlan]
    for seat in 0 ..< Seats:
      plans[seat] =
        if greedy: beelinePlan()
        else: dispatcherPlan(baselineInput(game, seat), tuning)
    let failure = runTurn(game, plans)
    if failure.len > 0:
      quit("sim fault during the sweep: " & failure, 1)
  for seat in 0 ..< Seats:
    result.delivered += game.delivered[seat]
  result.jamMean =
    if game.jamIndexSamples > 0: game.jamIndexSum div game.jamIndexSamples
    else: 0
  result.gridlocks = game.gridlockEvents

proc measure(tuning: DispatcherTuning, greedy = false,
    seeds: openArray[int] = Seeds): Outcome =
  var jam, gridlocks: int
  for i, load in Loads:
    for seed in seeds:
      let outcome = play(load, seed, tuning, greedy)
      result.delivered[i] += outcome.delivered
      result.total += outcome.delivered
      if load.name == "stress":
        jam += outcome.jamMean
        gridlocks += outcome.gridlocks
  result.jamMean = jam div seeds.len
  result.gridlocks = gridlocks div seeds.len

proc tuningJson(tuning: DispatcherTuning): JsonNode =
  %*{
    "weightBase": tuning.weightBase,
    "weightMin": tuning.weightMin,
    "weightMax": tuning.weightMax,
    "patienceJam": tuning.patienceJam,
    "patienceCalm": tuning.patienceCalm,
    "patienceJammed": tuning.patienceJammed,
    "dispatchJam1": tuning.dispatchJam1,
    "dispatchJam2": tuning.dispatchJam2,
    "dispatchJam3": tuning.dispatchJam3,
    "dispatchCalm": tuning.dispatchCalm,
    "dispatchBusy": tuning.dispatchBusy,
    "dispatchHeavy": tuning.dispatchHeavy,
    "dispatchSevere": tuning.dispatchSevere,
    "spreadJam": tuning.spreadJam,
    "spreadCalm": tuning.spreadCalm,
    "spreadJammed": tuning.spreadJammed,
    "avoidDigit": tuning.avoidDigit,
    "farBacklog": tuning.farBacklog}

# ---------------------------------------------------------------------------
# Stage 1: the full factorial over the four axes the rule leans on hardest —
# how hard a queue is repriced, how far the fleet meters itself in a bad jam,
# how patient a van is, and how staggered departures are once it is jammed.
# ---------------------------------------------------------------------------

const
  WeightBases = [0, 15, 30, 45, 60]
  DispatchSevere = [30, 45, 60]
  PatienceCalm = [35, 60, 85]
  SpreadJammed = [40, 80, 100]

proc factorial(): seq[Candidate] =
  for weightBase in WeightBases:
    for severe in DispatchSevere:
      for patience in PatienceCalm:
        for spread in SpreadJammed:
          var tuning = DefaultDispatcherTuning
          tuning.weightBase = weightBase
          tuning.dispatchSevere = severe
          tuning.patienceCalm = patience
          tuning.spreadJammed = spread
          result.add(Candidate(
            label: &"w{weightBase:>2} d{severe:>2} p{patience:>2} s{spread:>3}",
            tuning: tuning, outcome: measure(tuning)))

# ---------------------------------------------------------------------------
# Stage 2: a coordinate sweep of the remaining constants around stage 1's
# winner. These are mostly thresholds — where the ladder steps, not how far.
# ---------------------------------------------------------------------------

proc coordinate(best: DispatcherTuning): seq[Candidate] =
  proc axis(name: string, values: openArray[int],
      apply: proc (t: var DispatcherTuning, v: int)): seq[Candidate] =
    for value in values:
      var tuning = best
      apply(tuning, value)
      result.add(Candidate(label: &"{name}={value}", tuning: tuning,
        outcome: measure(tuning)))
  result.add(axis("weightMax", [75, 85, 95, 100],
    proc (t: var DispatcherTuning, v: int) = t.weightMax = v))
  result.add(axis("weightMin", [0, 15, 30, 45],
    proc (t: var DispatcherTuning, v: int) = t.weightMin = v))
  result.add(axis("patienceJammed", [15, 35, 55],
    proc (t: var DispatcherTuning, v: int) = t.patienceJammed = v))
  result.add(axis("patienceJam", [30, 40, 50],
    proc (t: var DispatcherTuning, v: int) = t.patienceJam = v))
  result.add(axis("dispatchHeavy", [45, 60, 75],
    proc (t: var DispatcherTuning, v: int) = t.dispatchHeavy = v))
  result.add(axis("dispatchBusy", [70, 80, 90],
    proc (t: var DispatcherTuning, v: int) = t.dispatchBusy = v))
  result.add(axis("dispatchJam1", [25, 35, 45],
    proc (t: var DispatcherTuning, v: int) = t.dispatchJam1 = v))
  result.add(axis("dispatchJam2", [45, 55, 65],
    proc (t: var DispatcherTuning, v: int) = t.dispatchJam2 = v))
  result.add(axis("dispatchJam3", [65, 75, 85],
    proc (t: var DispatcherTuning, v: int) = t.dispatchJam3 = v))
  result.add(axis("spreadJam", [35, 45, 55],
    proc (t: var DispatcherTuning, v: int) = t.spreadJam = v))
  result.add(axis("spreadCalm", [20, 40, 60],
    proc (t: var DispatcherTuning, v: int) = t.spreadCalm = v))
  result.add(axis("avoidDigit", [5, 6, 7, 8],
    proc (t: var DispatcherTuning, v: int) = t.avoidDigit = v))
  result.add(axis("farBacklog", [40, 55, 70],
    proc (t: var DispatcherTuning, v: int) = t.farBacklog = v))

proc rank(candidates: seq[Candidate]): seq[Candidate] =
  result = candidates
  result.sort(proc (a, b: Candidate): int =
    if a.outcome.total != b.outcome.total: cmp(b.outcome.total, a.outcome.total)
    else: cmp(a.label, b.label))

proc rows(candidates: seq[Candidate], shipped: Outcome): string =
  for candidate in rank(candidates):
    let mark =
      if candidate.outcome.total == shipped.total: " (=shipped)" else: ""
    result.add(&"| `{candidate.label}`{mark} | " &
      &"{candidate.outcome.delivered[0]} | {candidate.outcome.delivered[1]} " &
      &"| {candidate.outcome.delivered[2]} | **{candidate.outcome.total}** | " &
      &"{candidate.outcome.jamMean} | {candidate.outcome.gridlocks} |\n")

when isMainModule:
  let wantJson = paramCount() >= 1 and paramStr(1) == "--json"
  let shipped = measure(DefaultDispatcherTuning)
  let greedy = measure(DefaultDispatcherTuning, greedy = true)
  let grid = factorial()
  let ranked = rank(grid)
  ## Ties go to the incumbent: the stage-2 base is the shipped tuning unless a
  ## candidate strictly beat it.
  var best = Candidate(label: "shipped", tuning: DefaultDispatcherTuning,
    outcome: shipped)
  if ranked[0].outcome.total > shipped.total:
    best = ranked[0]
  let refined = coordinate(best.tuning)

  ## Stage 3. The top challengers, replayed on seeds the sweep never tuned on.
  ## Without this a 0.3 % edge over three seeds reads as an improvement when
  ## it is the seed draw.
  var pool: seq[Candidate]
  for candidate in rank(grid) & rank(refined):
    if candidate.outcome.total > shipped.total:
      pool.add(candidate)
  var challengers: seq[Candidate]
  var seenTotals: seq[int]
  for candidate in rank(pool):
    if challengers.len >= Challengers:
      break
    if candidate.outcome.total in seenTotals:
      continue
    seenTotals.add(candidate.outcome.total)
    challengers.add(candidate)
  let shippedHeld = measure(DefaultDispatcherTuning, seeds = ValidationSeeds)
  let margin = shipped.total * MarginPct div 100
  var held: seq[tuple[candidate: Candidate, outcome: Outcome]]
  var winner = Candidate(label: "shipped (incumbent)",
    tuning: DefaultDispatcherTuning, outcome: shipped)
  var winnerHeld = shippedHeld
  for candidate in challengers:
    let outcome = measure(candidate.tuning, seeds = ValidationSeeds)
    held.add((candidate, outcome))
    if candidate.outcome.total - shipped.total >= margin and
        outcome.total - shippedHeld.total >= margin and
        outcome.total > winnerHeld.total:
      winner = candidate
      winnerHeld = outcome

  if wantJson:
    var gridJson = newJArray()
    for candidate in rank(grid) & rank(refined):
      gridJson.add(%*{
        "label": candidate.label,
        "delivered": %(@(candidate.outcome.delivered)),
        "total": candidate.outcome.total,
        "stress_jam_index_mean": candidate.outcome.jamMean,
        "stress_gridlock_events": candidate.outcome.gridlocks})
    var loadsJson = newJArray()
    for load in Loads:
      loadsJson.add(%*{
        "name": load.name,
        "fleet_size": load.fleetSize,
        "order_period_ticks": load.orderPeriodTicks,
        "backlog_max": load.backlogMax})
    var heldJson = newJArray()
    for entry in held:
      heldJson.add(%*{
        "label": entry.candidate.label,
        "tuning_seeds_total": entry.candidate.outcome.total,
        "held_out_total": entry.outcome.total})
    echo (%*{
      "harness": "tools/tune_baselines.nim",
      "seeds": %(@Seeds),
      "validation_seeds": %(@ValidationSeeds),
      "margin_pct": MarginPct,
      "episode_ticks": EpisodeTicks,
      "loads": loadsJson,
      "metric": "total parcels delivered by four dispatcher seats, " &
        "summed over every load and seed",
      "tie_break": "the incumbent keeps a tie and any win under the margin " &
        "on either seed set",
      "beeline_reference": greedy.total,
      "shipped": shipped.total,
      "shipped_held_out": shippedHeld.total,
      "challengers": heldJson,
      "winner": {
        "label": winner.label,
        "total": winner.outcome.total,
        "held_out_total": winnerHeld.total,
        "tuning": tuningJson(winner.tuning)},
      "grid": gridJson}).pretty()
  else:
    echo "# dispatcher tuning grid"
    echo ""
    echo &"Produced by `tools/tune_baselines.nim`: {grid.len} full-factorial " &
      &"tunings plus {refined.len} coordinate steps, each played as " &
      &"all-`dispatcher` episodes of {EpisodeTicks} ticks at seeds " &
      &"{Seeds.join(\", \")} and three loads."
    echo ""
    echo "| load | fleet | order period | backlog cap |"
    echo "|---|---|---|---|"
    for load in Loads:
      echo &"| {load.name} | {load.fleetSize} | {load.orderPeriodTicks} " &
        &"ticks | {load.backlogMax} |"
    echo ""
    echo "The score is the total delivered summed over every load and seed. " &
      "`stress` is the only load at which the city can actually jam — 200 " &
      "vans cannot fill 288 lanes of 14 cells, so at the shipped scale the " &
      "deep-jam half of the ladder never engages and the constants that " &
      "govern it measure as inert. Ties go to the incumbent."
    echo ""
    echo &"Reference: the same three loads with four `beeline` seats deliver " &
      &"**{greedy.total}** (stress jam {greedy.jamMean}, " &
      &"{greedy.gridlocks} gridlocks); the shipped " &
      &"`DefaultDispatcherTuning` delivers **{shipped.total}** " &
      &"(stress jam {shipped.jamMean}, {shipped.gridlocks} gridlocks)."
    echo ""
    echo "## Stage 1 — full factorial"
    echo ""
    echo "`w` = weightBase, `d` = dispatchSevere, `p` = patienceCalm, " &
      "`s` = spreadJammed. Every other constant at its shipped value."
    echo ""
    echo "| tuning | default | rush | stress | total | stress jam | gridlocks |"
    echo "|---|---|---|---|---|---|---|"
    stdout.write(rows(grid, shipped))
    echo ""
    echo &"## Stage 2 — coordinate sweep around `{best.label}`"
    echo ""
    echo "| tuning | default | rush | stress | total | stress jam | gridlocks |"
    echo "|---|---|---|---|---|---|---|"
    stdout.write(rows(refined, shipped))
    echo ""
    echo "## Stage 3 — the challengers on held-out seeds"
    echo ""
    echo &"Seeds {ValidationSeeds.join(\", \")}, which stages 1 and 2 never " &
      &"saw. The shipped tuning scores **{shippedHeld.total}** there. A " &
      &"challenger has to beat the incumbent on BOTH seed sets by at least " &
      &"{MarginPct}% ({margin} parcels) to replace it."
    echo ""
    echo "| challenger | tuning seeds | held-out seeds | held-out vs shipped |"
    echo "|---|---|---|---|"
    for entry in held:
      let delta = entry.outcome.total - shippedHeld.total
      echo &"| `{entry.candidate.label}` | {entry.candidate.outcome.total} " &
        &"| {entry.outcome.total} | {(if delta >= 0: \"+\" else: \"\")}{delta} |"
    echo ""
    echo &"**Winner: `{winner.label}` — {winner.outcome.total} on the tuning " &
      &"seeds, {winnerHeld.total} on the held-out seeds.**"
