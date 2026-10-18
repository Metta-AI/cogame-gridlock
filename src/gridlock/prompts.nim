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
  PromptBankVersion* = "gridlock-rules-v1"

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

const CanonicalSystemPrompt = """
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
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
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
  let introduction = case selection.selectedVariant
    of pvCanonical: "You are the dispatcher for one parcel fleet of 50 vans in a city shared with three\nrival fleets."
    of pvPlain: "You dispatch a parcel fleet with 50 vans. Three rival fleets share the city with you."
    of pvNumbered: "1. Your role is parcel-fleet dispatcher. 2. Your fleet has 50 vans. 3. You share the city with three rival fleets."
    of pvQuestions: "What is your role? Dispatcher of a 50-van parcel fleet. Who shares the city? Three rival fleets."
    of pvReordered: "Three rival fleets share the city with your parcel fleet. You dispatch its 50 vans."
    of pvHeldoutBriefing: "Dispatch the 50 vans belonging to your parcel fleet in a city shared with three competing fleets."
    of pvHeldoutReference: "Role: parcel-fleet dispatcher. Fleet size: 50 vans. Shared city: your fleet and three rival fleets."
    of pvMixed: raise newException(ValueError, "mixed must resolve")
  introduction & CanonicalSystemPrompt[96 .. ^1]
