# Gridlock — wire protocol

Two surfaces: the **player** websocket (one per seat) and the **global** spectator stream plus the
static replay bundle. Everything is UTF-8 JSON text.

## Player — `gridlock.player.v3`

Connect to `ws://<host>:<port>/player?slot=N&token=T`. A bad slot or token is **403**; a second
connection to a seat that already holds one, or admission after gameplay starts, is **409**.

### Register

```json
{"type": "register", "kind": "scripted" | "prompt" | "external",
 "scripted": "dispatcher" | "beeline" | null,
 "policy": "<free label, <= 48 runes>", "prompt": "<private policy, <= 4000 runes>"}
```

A missing registration plays `dispatcher`. A scripted player names its baseline. A prompt or external
player registers its private prompt for authoritative request validation. Credentials remain inside the player.
Registration freezes before gameplay; a disconnected seat plays dispatcher.

### Welcome

```json
{"type": "welcome", "protocol": "gridlock.player.v3", "slot": 0,
 "fleet": "Carbon", "colour": "#e07a3f", "turns": 20, "turn_seconds": 10}
```

### Private decision and ordinary action

At each routing turn the game sends all model seats their private views before the shared 14-second
first deadline. It retries invalid or missing actions once under a six-second deadline. The game
repairs accepted plans against the previous plan and records the resolved result. The player sends
one complete routing plan in the normal action envelope, or an explicit fallback cause.

```json
{"type": "decision", "protocol": "gridlock.player.v3", "decision_id": "7-0-1",
 "slot": 0, "turn": 7, "attempt": 1, "transport": {"budget_ms": 14000, "cleanup_budget_ms": 5000},
 "prompt": "<registered private policy>", "observation": { … the private view below … }}
```

```json
{"type": "action", "protocol": "gridlock.player.v3", "decision_id": "7-0-1",
 "source": "llm", "action": { … the routing plan below … },
 "training_attempt": { … exact native attempt evidence … }}
```

The native reference player uses only `COWORLD_LLM_ENDPOINT`, its authenticated slot, and configured model.
Before HTTP starts, it sends `attempt_started` with the issued `decision_id` and exact private
`training_attempt`; response fields are null. Finished evidence retains actual body/header bytes,
status, call identity, sampling metadata, and reader join. Received facts cannot be rewritten.
A selected model response must match its received native body and parse to the submitted action.
Fallback replies set `source: "fallback"`; the engine retains evidence and applies dispatcher after its retry budget.

Every turn retains the original 22-second ceiling, with at most 14 seconds then 6 seconds.
Transport budgets are outside the model prompt. All incoming frames are bounded to 16 MiB.

Before sealing, the game sends each registered model seat a `stop` containing its latest
`decision_id` (or null), an unpredictable `stop_id`, and remaining `cleanup_budget_ms`.
The player cancels and joins its reader, then sends `stopped` with those identities,
`worker_status: "joined" | "no_active_call"`, and its retained `attempts` array.
The game retains immutable evidence and returns `evidence_received` with the echoed identities.
That receipt completes the client's ownership; it does not attest platform model authority.
Disconnected registered seats remain stop targets. Missing acknowledgements or readers produce
private truncated trajectories and suppress normal public results/replay.

An informational `turn` follows each applied turn. Successful joined completion sends
`{"type":"final","done":true,"result":{…}}`. Private model metadata never enters public replay.

### The per-seat view

```json
{"turn": 7, "of": 20, "tick": 1680, "ticks_left": 3120, "seconds_left": 130.0,
 "you": {"fleet": "Carbon", "colour": "#e07a3f", "depot": [1, 1], "depot_district": [0, 0],
         "vans": 50, "docked": 9, "loading": 2, "waiting_dispatch": 6,
         "on_road_loaded": 21, "on_road_empty": 12, "stalled": 7,
         "delivered": 61, "delivered_last_turn": 9, "backlog": 23,
         "mean_trip_seconds": 41.5, "stalled_pct": 21,
         "last_plan": { … the resolved plan you played last turn, or null on turn 0 … },
         "next_orders": [{"id": 812, "dest": [4, 5], "district": [1, 1], "age_s": 6.0}, … up to 6 … ]},
 "city": {"grid": [9, 9], "districts": [3, 3], "lane_cells": 14,
          "arterial_cols": [2, 4, 6], "arterial_rows": [2, 4, 6],
          "signal": "4.0 s cycle, 2.0 s NS then 2.0 s EW, offset ((ix+iy) mod 4) x 1.0 s",
          "discharge_per_green_step": {"arterial": 2, "local": 1},
          "jam_index": 46,
          "districts_heat": ["347", "596", "263"],
          "hot_lanes": [{"from": [4, 3], "to": [4, 4], "class": "arterial",
                         "q": 14, "cap": 14, "blocked_s": 8.5}, … up to 8, worst first … ]},
 "fleets": [{"fleet": "Carbon", "delivered": 61, "on_road": 33}, … all four, fixed alias order … ],
 "events_last_turn": ["gridlock in CENTRE", "jam on 4,3->4,4"]}
```

- `districts_heat` is three strings of three digits, row-major over `by` then `bx`. Digit
  `= min(9, meanLaneOccupancyPercentInDistrict / 10)` over the lanes whose head node is in that
  district.
- `jam_index` is city-wide: `100 × blockedMoveOpportunities / totalMoveOpportunities` for on-road
  vans, clamped 0…100. `you.stalled_pct` is the same quantity over this seat's own vans only.
- **The window for both, exactly.** The accumulators reset at every turn boundary and the
  statistics are recomputed every 48 ticks over whatever has accumulated *since that reset* —
  the turn so far, not a rolling 240-tick window. Your view is built before the turn clock
  advances, so the numbers you are handed at the start of a turn were measured inside the turn
  that just played (its first 193 ticks; the last recompute of a turn lands 48 ticks before the
  boundary). Mid-turn `heat` events carry the partial window they were computed over, which is
  why the first one after a boundary reads low.
- `hot_lanes` is at most eight lanes, worst `q` first, ties by lane id.

**Hidden from a seat:** the per-fleet composition of any lane's queue (you see fourteen vans in that
lane, never whose they are); every rival's plan, `note`, `say`, prompt and policy kind; every
rival's destinations, backlog and trip times; individual rival van positions; the canonical
destination schedule beyond its own next six orders; the seat → depot permutation for any other
seat; the episode seed; and the future.

**Rival identities are hidden by construction:** the only names in a view are the depot aliases.

### Done

```json
{"done": true, "result": { … the results document … }}
```

## The routing plan

```json
{"congestion_weight": 65, "patience": 40, "dispatch": 80, "spread": 60,
 "corridor": [0, 1], "avoid": [1, 1], "priority": "near",
 "note": "<= 140 runes", "say": "<= 32 runes"}
```

| field | type | legal | repair |
|---|---|---|---|
| `congestion_weight` | int | 0…100 | missing/non-numeric → previous turn's value (40 on turn 0); out of range → clamped |
| `patience` | int | 0…100 | as above, default 50 |
| `dispatch` | int | 0…100 | as above, default 100 |
| `spread` | int | 0…100 | as above, default 40 |
| `corridor` | `[bx,by]` or null | 0…2 each | out of range → clamped; wrong shape → null |
| `avoid` | `[bx,by]` or null | 0…2 each | as `corridor`; forced null when it equals `corridor` |
| `priority` | enum | `near` \| `far` \| `fifo` (case-insensitive) | anything else → `fifo` |
| `note` | string | ≤ 140 runes | truncated on a RUNE boundary |
| `say` | string | ≤ 32 runes | truncated on a RUNE boundary |

Parsing is tolerant: markdown fences are stripped, the outermost balanced `{…}` is taken when the
model prefixed prose, numeric strings and `"70%"` are accepted for any integer, and
`corridor`/`avoid` are accepted as `{"bx":…,"by":…}` or as a district name. Only when no object
carrying at least one recognised plan key can be recovered does the retry — and then the scripted
fallback — fire. **The resolved, repaired, clamped plan is what is installed and what is recorded.**

Truncation is on **rune** boundaries, never bytes: a byte-truncated multi-byte character renders in
a browser and fails a strict UTF-8 JSON parser.

## Global — the spectator stream and the static bundle

`GET /client/global` is a real page and `ws://…/global` streams, first, one **meta** message (board
geometry, the 288-lane table, the four depots with aliases and colours, the real player names, the
results once known) and then one **frame** message per drawn frame:

```json
{"type": "frame", "t": 1680, "turn": 7, "jam": 46, "digits": [3,4,7,5,9,6,2,6,3],
 "delivered": [61,58,47,39], "on_road": [33,44,50,28], "backlog": [23,11,40,52],
 "q": [ … 288 lane occupancies … ],
 "v": [ … 200 x (lane, cell, state), lane 65535 = docked … ],
 "plans": [ … the four current routing plans … ],
 "events": [ … the events since the previous frame … ]}
```

The **replay** is a static wasm bundle (`"replay_viewer": {"bundle": "static-replay-viewer"}`),
never a pod. Its bytes are self-sufficient — protocol, seed, resolved config, the city inlined
verbatim, the seat → depot permutation, real player names, aliases, colours, policy kinds, the whole
plan stream, a keyframe per second with its u32 digest, every van's `(lane, cell, state)` per
keyframe as base64, the event stream and the results. The viewer contacts no server except S3 for
the `.replay` file, and it re-runs the integer sim from the plan stream, so lane occupancy is
re-derived rather than transported.

```json
{"protocol": "gridlock.replay.v1", "format_version": 1, "game_version": "1",
 "seed": 679961, "config": {…}, "city": {…}, "seat_depots": [0,3,1,2],
 "names": {"players": […], "aliases": […], "policy_kinds": […], "colours": […]},
 "ticks_per_second": 24, "turn_ticks": 240, "tick_count": 4800,
 "plans": [ … 20 x 4 … ], "keyframes": [ … every 24 ticks … ],
 "vehicles_b64": "…", "events": [ … ], "results": { … }}
```

### Event vocabulary

| `type` | fields |
|---|---|
| `match_start` | `t`, `seed`, `city`, `fleets`, `vans_per_fleet`, `episode_ticks`, `signal` |
| `turn_start` | `t`, `turn`, `delivered`, `on_road`, `backlog`, `jam_index` |
| `plan` | `t`, `turn`, `seat`, `fleet`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, the eight plan fields |
| `fallback` | `t`, `turn`, `seat`, `attempt`, `cause`, `detail` |
| `budget_guard` | `t`, `turn`, `remaining_s` |
| `deliver` | `t`, `f`, `n`, `d`, `trip` |
| `jam` | `t`, `lane`, `from`, `to`, `class`, `q` |
| `jam_clear` | `t`, `lane`, `q`, `duration_ticks` |
| `gridlock` | `t`, `district`, `district_name`, `blocked_lanes`, `fleets_involved` |
| `heat` | `t`, `districts`, `jam_index`, `on_road` |
| `meter` | `t`, `turn`, `fleet`, `dispatch`, `held` |
| `end` | `t`, `reason`, `end_rule`, `delivered`, `scores`, `winner`, `total_delivered`, `jam_index_mean` |

## Runtime contract

`COGAME_CONFIG_URI` (required), `COGAME_RESULTS_URI`, `COGAME_SAVE_REPLAY_URI`,
`COGAME_LOAD_REPLAY_URI`, `COGAME_PLAYER_FAILURE_URI`, `COGAME_EVENTS_URI` and
`COGAME_METRICS_URI` (**`file://` only**, loudly rejected otherwise), `COGAME_HOST`, `COGAME_PORT`.

`COGAME_SAVE_TRAJECTORY_URI` is a private canonical event export. Runtime episode, registered
game identity, package version, source revision, and image digest are supplied by trusted runner metadata.

The game joins registered model owners before sealing. It writes the private trajectory first,
then successful results and replay, within one absolute five-second artifact cleanup deadline.
Private upload failure aborts later public writes. Signals seal private truncated evidence;
runtime failures seal private failed evidence. The owned game thread joins before server exit.
Successful completion retains up to 20 seconds of spectator grace, clipped to the episode budget.
