## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "gridlock-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

const CanonicalBriefing = """
You are the dispatcher for one parcel fleet of 50 vans in a city shared with three
rival fleets. The city is a 9x9 grid of intersections joined by two-way roads. Every
road holds at most 14 vans per direction. Every intersection runs a fixed 4-second
light: 2 seconds north-south, 2 seconds east-west, offset diagonally across the city.
Nobody controls the lights. A green approach lets through 1 van per service tick, or
2 on an arterial (the roads on grid lines 2, 4 and 6). If the road a van wants to enter
is FULL, it cannot cross, so it sits in the intersection mouth and the queue behind it
backs up. That is how a jam spreads.
Your depot sits in one corner. Vans load a parcel, drive to its address, drop it, and
come back for the next. One delivered parcel is one point. Your score is your own
deliveries - it is NOT a share, so nothing stops all four fleets from scoring badly at
once. That is the trap: the shortest route is the same shortest route everyone else
computed, and four fleets flooding the arterials deliver fewer parcels between them
than four fleets that spread out and meter themselves.
Every 10 seconds you set your fleet's ROUTING PLAN: how much your vans inflate the cost
of a queued road, how full a road must be before they re-plan at an intersection, how
many vans you allow on the road at once, how staggered their departures are, which
district they should prefer or avoid, and which parcel they take next. That is all.
You cannot steer one van, change a light, or talk to another fleet.
"""

const ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"congestion_weight":0-100, // how strongly a queued road is avoided when planning
 "patience":0-100,          // how full the next road must be before a van re-plans
 "dispatch":0-100,          // percent of your 50 vans allowed on the road at once
 "spread":0-100,            // 0 = release in bursts of 6, 100 = release one at a time
 "corridor":[bx,by]|null,   // district (0-2,0-2) your vans should prefer to route through
 "avoid":[bx,by]|null,      // district your vans should route around
 "priority":"near"|"far"|"fifo", // which waiting parcel a van loads next
 "note":"<=140 chars",      // your reasoning, shown to spectators only
 "say":"<=32 chars"}        // one short line, shown to spectators only
Districts are the 3x3 blocks of the node grid: [0,0] is NW, [1,1] is CENTRE, [2,2] is SE.
congestion_weight 0 is pure shortest path - fast when the city is empty, and the fastest
way to build a jam when it is not. dispatch below 100 is the only way to reduce total
traffic; it costs you deliveries in the short run and buys a moving city back.
"""

proc systemPrompt*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical:
    result = CanonicalBriefing
  of pvPlain:
    result = "Dispatch 50 parcel vans while three competing fleets share a 9x9 road grid. " &
      "Two-way roads hold at most 14 vans in each direction. Lights are fixed: a four-second " &
      "cycle gives two seconds north-south and two east-west, with diagonal offsets. A green " &
      "serves one van per service tick, or two on arterials along grid lines 2, 4, and 6. " &
      "A full outgoing road blocks crossing and backs up the queue behind it.\n" &
      "From a corner depot, vans load parcels, deliver them, then return. Each delivery by " &
      "your own fleet earns one point. Scores are independent, so all four fleets can do " &
      "poorly together. Shared shortest routes can jam the arterials; metering departures " &
      "and spreading routes can improve total throughput.\n" &
      "Every 10 seconds choose the fleet routing plan: queued-road cost, replan fullness " &
      "threshold, active fleet size, departure staggering, preferred and avoided districts, " &
      "and next-parcel priority. You cannot steer individual vans, alter lights, or talk " &
      "to other fleets.\n"
  of pvNumbered:
    result = "1. Fleet: 50 parcel vans under your dispatch, sharing a city with three rivals.\n" &
      "2. City: a 9x9 intersection grid with two-way roads, capacity 14 vans per direction.\n" &
      "3. Signals: fixed four-second cycles, two seconds north-south then two east-west, " &
      "offset diagonally. Greens serve one van per service tick; arterials on lines 2, 4, " &
      "and 6 serve two. Full outgoing roads prevent crossing and propagate queues backward.\n" &
      "4. Work: load at your corner depot, deliver to the parcel address, return for more.\n" &
      "5. Reward: one point per own delivery, never a share. All fleets can lose throughput " &
      "together when shared shortest routes flood arterials; spreading and metering help.\n" &
      "6. Decision: every 10 seconds set queued-road cost, replan fullness, on-road van " &
      "limit, departure staggering, district preference/avoidance, and parcel priority.\n" &
      "7. Limits: no individual steering, light control, or communication with rivals.\n"
  of pvQuestions:
    result = "What do you control? A 50-van parcel fleet; three rival fleets use the same city. " &
      "Every 10 seconds set a routing plan covering congestion pricing, replan fullness, " &
      "active vans, staggered departures, district preference/avoidance, and parcel priority. " &
      "You cannot steer a single van, change a signal, or talk to rivals.\n" &
      "What earns points? Own deliveries, one point each. Vans load at a corner depot, " &
      "deliver, and return. This is no score share: everyone can score poorly when shortest " &
      "routes overload arterials; spreading and metering can keep the city moving.\n" &
      "What causes jams? The 9x9 grid has two-way roads with only 14 vans per direction. " &
      "Fixed signals alternate two seconds north-south with two east-west, diagonally " &
      "offset. A green serves one van per service tick, or two on arterial lines 2, 4, " &
      "and 6. A full destination road blocks crossing and pushes the queue backward.\n"
  of pvReordered:
    result = "Earn one point for each parcel your own vans deliver. Scores are not shares; " &
      "all four fleets can score badly. Loading at a corner depot, delivering, and returning " &
      "is the work cycle for your 50 vans. If everyone takes the same shortest routes, " &
      "arterials clog; spreading routes and metering traffic can raise shared throughput.\n" &
      "The city is a 9x9 intersection grid with two-way roads, 14 vans per direction. " &
      "Uncontrollable lights repeat two seconds north-south and two east-west with diagonal " &
      "offsets. Each green service tick passes one van, or two on arterial grid lines " &
      "2, 4, and 6. When an outgoing road fills, crossing stops and queues spill backward.\n" &
      "With three rival fleets sharing the city, update your plan every 10 seconds: " &
      "queued-road costs, replan fullness, allowed on-road fleet size, departure stagger, " &
      "district preference and avoidance, and parcel selection. No single-van steering, " &
      "signal changes, or inter-fleet conversation are available.\n"
  of pvHeldoutBriefing:
    result = "You dispatch one of four fleets, each with 50 vans. Your corner depot loads " &
      "parcels for delivery, after which vans return. Each own delivery earns one point; " &
      "scores are independent, allowing everyone to perform badly at once.\n" &
      "Use a fleet-wide routing plan once per 10 seconds. Choose queued-road cost, " &
      "replanning fullness, active-van limit, departure staggering, district preference " &
      "and avoidance, and parcel priority. Individual steering, signal control, and " &
      "communication with other fleets are unavailable.\n" &
      "The 9x9 intersection grid has two-way roads holding 14 vans per direction. Fixed " &
      "four-second signals split equally between north-south and east-west with diagonal " &
      "offsets. Greens serve one van per service tick, doubled on arterial lines 2, 4, " &
      "and 6. Full downstream roads stop crossing and back up upstream queues. Shared " &
      "shortest routes can overload those arterials; spreading and metering can improve " &
      "the number of parcels all fleets deliver.\n"
  of pvHeldoutReference:
    result = "Fleet: 50 vans, three rival fleets. Task cycle: load at corner depot, deliver, " &
      "return. Payoff: one point per own delivery, no score sharing; all fleets can do poorly.\n" &
      "Network: 9x9 intersections, two-way roads, 14 vans per direction. Signals: fixed " &
      "four-second period, two north-south plus two east-west, diagonal offsets. Green " &
      "service: one van per tick, two on arterial lines 2/4/6. Spillback: full next road " &
      "blocks crossing, propagating its queue upstream.\n" &
      "Control interval: 10 seconds. Plan controls: congestion pricing, replan fullness, " &
      "on-road van limit, departure stagger, preferred/avoided district, next parcel. " &
      "Unavailable: single-van steering, signal changes, inter-fleet talk. Commons risk: " &
      "shared shortest paths flood arterials; spreading and metering can improve throughput.\n"
  of pvMixed:
    raise newException(ValueError, "mixed must resolve")
  result.add(ReplyRules)
