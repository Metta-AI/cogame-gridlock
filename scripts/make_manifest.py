#!/usr/bin/env python3
"""Generates coworld_manifest_template.json.

The manifest inlines README.md, docs/RULES.md and docs/PROTOCOL.md as
`game.docs`, and tests/test_manifest.nim asserts they match byte for byte — so
edit the docs, then re-run this:

  python3 scripts/make_manifest.py
"""
import collections
import json

SRC = "https://github.com/Metta-AI/cogame-gridlock/tree/main"

readme = open("README.md").read()
rules = open("docs/RULES.md").read()
protocol = open("docs/PROTOCOL.md").read()


def num(desc, lo, hi, default, kind="integer"):
    return {"description": desc, "type": kind, "minimum": lo, "maximum": hi,
            "default": default}


def arr(desc, item):
    return {"description": desc, "type": "array", "minItems": 4,
            "maxItems": 4, "items": item}


config_props = collections.OrderedDict()
config_props["tokens"] = {
    "description": "One connection token per player slot, indexed by slot.",
    "type": "array", "minItems": 4, "maxItems": 4,
    "items": {"type": "string", "minLength": 1}}
config_props["players"] = {
    "description": "One player display-name object per seat, indexed by slot. Seats play under depot aliases in-game; these names are spectator-side only.",
    "type": "array", "minItems": 4, "maxItems": 4,
    "items": {"type": "object", "additionalProperties": False,
              "required": ["name"],
              "properties": {"name": {"type": "string", "minLength": 1}}}}
config_props["num_agents"] = {
    "description": "Seat count. Gridlock is a four-fleet game and nothing else: four depots on the mirror orbit of one corner is the largest seat count that stays exactly fair.",
    "type": "integer", "minimum": 4, "maximum": 4, "default": 4}
config_props["seed"] = {
    "description": "Pins the seat-to-depot permutation, the canonical destination schedule and the Dijkstra tie noise. Omit for a fresh random episode.",
    "type": "integer"}
config_props["fleetSize"] = num("Vans per fleet.", 1, 200, 50)
config_props["episodeTicks"] = num("Episode length in 24 Hz ticks.", 240, 20000, 4800)
config_props["turnTicks"] = num("Ticks between routing decisions (240 = 10.0 s).", 24, 2400, 240)
config_props["moveTicks"] = num("A van advances at most one cell every this many ticks.", 1, 24, 3)
config_props["serviceTicks"] = num("Intersections serve every this many ticks.", 1, 48, 6)
config_props["dispatchPeriodTicks"] = num("Fleet metering runs every this many ticks.", 1, 240, 12)
config_props["laneCells"] = num("Cells per directed lane; one van per cell, so this is the lane's capacity.", 4, 64, 14)
config_props["cellPx"] = num("Pixels per cell.", 1, 64, 8)
config_props["loadTicks"] = num("Ticks a van spends loading a parcel at the depot.", 0, 240, 12)
config_props["orderPeriodTicks"] = num("Ticks between new orders (one per fleet).", 1, 240, 24)
config_props["backlogMax"] = num("Backlog cap; orders beyond it are not created.", 1, 500, 80)
config_props["signalCycleTicks"] = num("Traffic-signal cycle length in ticks.", 8, 480, 96)
config_props["greenNsTicks"] = num("Ticks of north-south green at the start of each cycle.", 1, 479, 48)
config_props["routeBudgetPerTick"] = num("Dijkstra runs allowed per tick.", 1, 200, 24)
config_props["jamThreshold"] = num("Lane occupancy that raises a jam event.", 2, 64, 11)
config_props["turnBudgetSeconds"] = num("Wall-clock ceiling for one decision turn.", 1, 120, 22, "number")
config_props["minTurnSpacingSeconds"] = num("Floor on the wall-clock spacing between LLM batches; the hosted Bedrock sidecar caps 30 requests/minute per episode and gridlock issues four per batch.", 0, 60, 10, "number")
config_props["wallClockBudgetSeconds"] = num("Engine hard stop. Must stay inside 60% of the platform episode timeout.", 30, 720, 660, "number")
config_props["playerConnectTimeoutSeconds"] = num("How long the game waits for seats before starting; a no-show plays the dispatcher baseline.", 0, 600, 90, "number")
config_props["episodeTimeoutSeconds"] = num("Platform kill time assumed when the environment is silent (the game container does not receive COWORLD_TIMEOUT_SECONDS).", 60, 6000, 1200)
config_props["cityPath"] = {
    "description": "Which authored city to load from data/<name>.cityspec.json.",
    "type": "string", "default": "gridcity"}
config_props["showPlayerLabels"] = {
    "description": "Show real player names in the spectator chrome.",
    "type": "boolean", "default": True}
config_props["gameOverTicks"] = num("Ticks the endcard holds before the process settles.", 0, 480, 96)
config_props["maxOutputTokens"] = num("Model output cap. 400 truncates the plan object.", 64, 2000, 900)
config_props["model"] = {"description": "Anthropic model id used when the direct API transport is in play.",
                         "type": "string", "default": "claude-haiku-4-5"}

results_props = collections.OrderedDict()
results_props["names"] = arr("Policy display names, indexed by slot.", {"type": "string"})
results_props["aliases"] = arr("The depot alias each seat played under this episode.", {"type": "string"})
results_props["colours"] = arr("Each seat's depot colour.", {"type": "string"})
results_props["depots"] = arr("Each seat's depot node as [ix, iy].", {"type": "array", "minItems": 2, "maxItems": 2, "items": {"type": "integer"}})
results_props["policy_kinds"] = arr("llm or scripted, per seat.", {"type": "string"})
results_props["scores"] = arr("Parcels this seat's vans delivered. Higher is better; a raw count, not a share.", {"type": "number", "minimum": 0})
results_props["win"] = arr("True for the unique maximum, false otherwise.", {"type": "boolean"})
results_props["delivered"] = arr("Same as scores, as an integer.", {"type": "integer", "minimum": 0})
results_props["total_delivered"] = {"description": "Sum of the four delivery counts: the city's whole output, and the thing the commons destroys.", "type": "integer", "minimum": 0}
results_props["orders_created"] = arr("Orders that entered this seat's backlog.", {"type": "integer", "minimum": 0})
results_props["backlog_final"] = arr("Orders still waiting at the end.", {"type": "integer", "minimum": 0})
results_props["mean_trip_seconds"] = arr("Mean release-to-delivery time.", {"type": "number", "minimum": 0})
results_props["stalled_vehicle_seconds"] = arr("Van-seconds spent stalled in a queue.", {"type": "integer", "minimum": 0})
results_props["own_stall_pct"] = arr("Share of this seat's move opportunities that were blocked.", {"type": "integer", "minimum": 0, "maximum": 100})
results_props["vans"] = arr("Fleet size.", {"type": "integer", "minimum": 0})
results_props["jam_index_mean"] = {"description": "Mean city jam index over the episode.", "type": "integer", "minimum": 0, "maximum": 100}
results_props["jam_index_peak"] = {"description": "Worst city jam index reached.", "type": "integer", "minimum": 0, "maximum": 100}
results_props["gridlock_events"] = {"description": "Districts that locked up, counted.", "type": "integer", "minimum": 0}
results_props["turns_llm"] = arr("Turns this seat's plan came from the model.", {"type": "integer", "minimum": 0})
results_props["fallback_turns"] = arr("Turns this seat played the scripted fallback after the model failed twice.", {"type": "integer", "minimum": 0})
results_props["fallback_causes"] = arr("Per-cause fallback counts.", {
    "type": "object", "additionalProperties": False,
    "properties": {c: {"type": "integer", "minimum": 0} for c in
                   ["timeout", "parse_error", "transport_error", "no_credentials", "budget_guard"]}})
results_props["reason"] = {"description": "complete, deadline or fault.", "type": "string", "enum": ["complete", "deadline", "fault"]}
results_props["end_rule"] = {"description": "The detail behind reason.", "type": "string", "enum": ["full_time", "wall_clock", "sim_fault", "host_error"]}
results_props["winner"] = {"description": "Slot index of the unique maximum, or null on a tie.", "type": ["integer", "null"], "minimum": 0, "maximum": 3}
results_props["final_tick"] = {"description": "Tick the episode stopped at.", "type": "integer", "minimum": 0}
results_props["final_turn"] = {"description": "Routing turn the episode stopped in.", "type": "integer", "minimum": 0}
results_props["seed"] = {"description": "The resolved episode seed.", "type": "integer"}

player_protocol = (
 "gridlock.player.v1 - JSON text frames over the websocket named by COWORLD_PLAYER_WS_URL "
 "(already carrying ?slot=N&token=T). A gridlock policy is a prompt: the player container's only "
 "job is to deliver it, and the game server makes every decision by sending that prompt plus the "
 "seat's view to the model once per routing turn.\n\n"
 "player -> game, exactly once on connect:\n"
 "  {\"type\":\"register\",\"prompt\":\"<strategy text>\",\"scripted\":null|\"dispatcher\"|\"beeline\","
 "\"policy\":\"<label, <=48 runes>\"}\n"
 "  prompt is truncated at 4000 runes, never rejected, and is never written to the replay or the "
 "results. A seat that never registers, or registers with neither field, plays the dispatcher "
 "baseline; a no-show never ends the episode.\n\n"
 "game -> player:\n"
 "  {\"type\":\"welcome\",\"protocol\":\"gridlock.player.v1\",\"slot\":N,\"fleet\":\"Carbon\","
 "\"colour\":\"#e07a3f\",\"turns\":20,\"turn_seconds\":10}\n"
 "  {\"type\":\"turn\",\"turn\":7,\"tick\":1680,\"fleet\":\"Carbon\",\"view\":{...},"
 "\"plan_source\":\"llm\"} once per routing turn (informational; the seat is not required to answer)\n"
 "  {\"done\":true,\"result\":{...the results document...}} then close.\n\n"
 "The view carries: turn/of/tick/ticks_left/seconds_left; you.{fleet,colour,depot,depot_district,"
 "vans,docked,loading,waiting_dispatch,on_road_loaded,on_road_empty,stalled,delivered,"
 "delivered_last_turn,backlog,mean_trip_seconds,stalled_pct,last_plan,next_orders[<=6]}; "
 "city.{grid,districts,lane_cells,arterial_cols,arterial_rows,signal,discharge_per_green_step,"
 "jam_index,districts_heat[3 strings of 3 digits],hot_lanes[<=8, worst first]}; the PUBLIC "
 "fleets[] block of every fleet's delivered and on_road counts in fixed alias order; and "
 "events_last_turn.\n\n"
 "Hidden from a seat: the per-fleet composition of any lane's queue, every rival's plan, note, say, "
 "prompt, policy kind, destinations, backlog and trip times, individual rival van positions, the "
 "canonical destination schedule beyond its own next six orders, the seat-to-depot permutation for "
 "any other seat, the episode seed, and the future. The only names in a view are the depot aliases "
 "Carbon / Oxygen / Germanium / Silicon, re-permuted every episode.\n\n"
 "The routing plan the model returns: {\"congestion_weight\":0-100,\"patience\":0-100,"
 "\"dispatch\":0-100,\"spread\":0-100,\"corridor\":[bx,by]|null,\"avoid\":[bx,by]|null,"
 "\"priority\":\"near\"|\"far\"|\"fifo\",\"note\":\"<=140 runes\",\"say\":\"<=32 runes\"}. Parsing "
 "is tolerant (fences stripped, outermost balanced object taken, numeric strings and \"70%\" "
 "accepted, district names accepted); every field is repaired and clamped, one retry is issued, and "
 "a second failure falls back to the dispatcher plan with a fallback event. Strings are truncated on "
 "RUNE boundaries."
)

global_protocol = (
 "gridlock.global - the spectator surface, and the static replay bundle.\n\n"
 "GET /healthz answers {\"ok\":true} and keeps answering through a 20 s shutdown grace after the "
 "artifacts are written. GET /client/global and GET /client/player return real pages and neither "
 "opens the player socket. ws://<host>:<port>/global streams one meta message (board geometry, the "
 "288-lane table, the four depots with aliases and colours, the real player names, the results once "
 "known) followed by one frame message per drawn frame:\n"
 "  {\"type\":\"frame\",\"t\":1680,\"turn\":7,\"jam\":46,\"digits\":[9 district digits],"
 "\"delivered\":[4],\"on_road\":[4],\"backlog\":[4],\"q\":[288 lane occupancies],"
 "\"v\":[200 x (lane,cell,state), lane 65535 = docked],\"plans\":[4],\"events\":[since the last frame]}\n"
 "mummy hands Ping frames to the application, and the game answers them with Pong.\n\n"
 "REPLAY: a STATIC WASM BUNDLE, never a pod - the manifest declares "
 "replay_viewer.bundle = static-replay-viewer. The bytes are strict UTF-8 JSON and self-sufficient: "
 "protocol gridlock.replay.v1, format_version, game_version, seed, the fully resolved config, the "
 "city inlined verbatim, seat_depots, names.{players,aliases,policy_kinds,colours}, "
 "ticks_per_second, turn_ticks, tick_count, the whole plan stream (20 turns x 4 seats - the input "
 "log IS the plan stream, because the traffic is a pure function of seed + city + plans), a keyframe "
 "every 24 ticks carrying a u32 state digest, vehicles_b64 (keyframes x 200 x 4 bytes of "
 "(lane u16 LE, cell u8, state u8)), the event stream, and the results document. The viewer "
 "re-runs the same integer sim in the browser and contacts no server except S3 for the .replay file.\n\n"
 "Event vocabulary: match_start, turn_start, plan, fallback, budget_guard, deliver, jam, jam_clear, "
 "gridlock, heat, meter, end."
)

variant_players = [{"name": n} for n in
                   ["Carbon Line", "Oxygen Line", "Germanium Line", "Silicon Line"]]

manifest = collections.OrderedDict()
manifest["$schema"] = "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json"
manifest["tags"] = ["logistics", "traffic", "commons", "real-time", "congestion"]
manifest["episode_timeout_minutes"] = 20
manifest["game"] = collections.OrderedDict([
    ("name", "gridlock"),
    ("replay_viewer", {"bundle": "static-replay-viewer"}),
    ("description",
     "Gridlock: four parcel fleets share one signalised 9x9 city. Each seat is a single policy "
     "routing fifty vans; a fleet scores one point per parcel its OWN vans deliver. Intersections "
     "have hard capacity and lanes spill back into the intersections behind them, so the fastest, "
     "greediest routing plan is the one that builds the jam everybody - including its author - then "
     "sits in. Nobody controls the lights. A policy is just a prompt."),
    ("owner", "daveey@softmax.com"),
    ("runnable", collections.OrderedDict([
        ("type", "game"),
        ("image", "{{GRIDLOCK_IMAGE}}"),
        ("run", ["/bin/gridlock"]),
        ("env", {"ANTHROPIC_API_KEY_URI": "secret://coworld/gridlock/anthropic_api_key"}),
        ("source_url", SRC)])),
    ("config_schema", collections.OrderedDict([
        ("$schema", "https://json-schema.org/draft/2020-12/schema"),
        ("type", "object"),
        ("additionalProperties", False),
        ("required", ["tokens", "players", "num_agents"]),
        ("properties", config_props)])),
    ("results_schema", collections.OrderedDict([
        ("$schema", "https://json-schema.org/draft/2020-12/schema"),
        ("type", "object"),
        ("additionalProperties", False),
        ("required", list(results_props.keys())),
        ("properties", results_props)])),
    ("protocols", {
        "player": {"type": "text", "value": player_protocol},
        "global": {"type": "text", "value": global_protocol}}),
    ("docs", {
        "readme": {"type": "text", "value": readme},
        "pages": [
            {"id": "rules.md", "title": "Rules",
             "content": {"type": "text", "value": rules}},
            {"id": "protocol.md", "title": "Wire protocol",
             "content": {"type": "text", "value": protocol}}]}),
])

manifest["player"] = [collections.OrderedDict([
    ("id", "baseline"),
    ("type", "player"),
    ("name", "dispatcher"),
    ("description",
     "Congestion-aware shortest-path dispatcher with jam-triggered fleet metering. The bundled "
     "certification player: it registers its seat as scripted, so the game server plays it "
     "deterministically with no LLM in the loop. Field your own policy by uploading this same image "
     "with a PLAYER_PROMPT instead."),
    ("image", "{{GRIDLOCK_IMAGE}}"),
    ("run", ["/bin/gridlock-player"]),
    ("env", {"PLAYER_SCRIPTED": "dispatcher"}),
    ("resources", {"requests": {"cpu": "100m", "memory": "64Mi"},
                   "limits": {"cpu": "1"}}),
    ("source_url", SRC)])]

manifest["variants"] = [
    collections.OrderedDict([
        ("id", "default"),
        ("name", "Gridcity (4 fleets, 200 s)"),
        ("description",
         "Four fleets, fifty vans each, 200 seconds of city time over twenty routing turns."),
        ("game_config", collections.OrderedDict([
            ("players", variant_players),
            ("num_agents", 4),
            ("fleetSize", 50),
            ("episodeTicks", 4800),
            ("turnTicks", 240),
            ("orderPeriodTicks", 24),
            ("turnBudgetSeconds", 22),
            ("wallClockBudgetSeconds", 660),
            ("playerConnectTimeoutSeconds", 90),
            ("cityPath", "gridcity")]))]),
    collections.OrderedDict([
        ("id", "rush"),
        ("name", "Rush hour (4 fleets, 120 s)"),
        ("description",
         "A shorter, denser round: same city, double the parcel demand, twelve routing turns."),
        ("game_config", collections.OrderedDict([
            ("players", variant_players),
            ("num_agents", 4),
            ("fleetSize", 50),
            ("episodeTicks", 2880),
            ("turnTicks", 240),
            ("orderPeriodTicks", 12),
            ("turnBudgetSeconds", 22),
            ("wallClockBudgetSeconds", 420),
            ("playerConnectTimeoutSeconds", 90),
            ("cityPath", "gridcity")]))]),
]

manifest["certification"] = collections.OrderedDict([
    ("game_config", collections.OrderedDict([
        ("players", [{"name": "P1"}, {"name": "P2"}, {"name": "P3"}, {"name": "P4"}]),
        ("num_agents", 4),
        ("seed", 42),
        ("fleetSize", 50),
        ("episodeTicks", 960),
        ("turnTicks", 240),
        ("turnBudgetSeconds", 22),
        ("minTurnSpacingSeconds", 0),
        ("wallClockBudgetSeconds", 180),
        ("playerConnectTimeoutSeconds", 60),
        ("cityPath", "gridcity")])),
    ("players", [{"player_id": "baseline"} for _ in range(4)]),
])

with open("coworld_manifest_template.json", "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
print("wrote coworld_manifest_template.json")
