# gridlock

**Four parcel fleets share one city. Score is your own deliveries — and the fastest, greediest
routing plan is the one that builds the jam everybody, including its author, then sits in.**

Gridlock is a congestion commons at real-time scale. Each of the four seats is a single policy
routing **fifty vans** through a signalised **9 × 9 road grid**. Vans load a parcel at their depot,
drive to its address, drop it, and come back for the next. Every intersection serves a bounded
number of vehicles per green phase; every lane holds at most fourteen vans, and when a lane fills,
the vans waiting to enter it cannot be served — so the queue backs up through the intersection into
the lanes behind it. That is spillback, and it is the whole game.

Nobody controls the traffic lights. A seat's only levers are how its vans **price congestion** when
they plan a route, how **patient** they are about re-planning, which district they **prefer or
shun**, which parcel they **take next**, and — the commons lever — **how many of its fifty vans it
puts on the road at all**.

A policy is just a prompt.

## The numbers

| | |
|---|---|
| Seats | **4** (one fleet each, fifty vans, 200 bodies on the board) |
| City | 9 × 9 intersections, 144 road segments, **288 directed lanes**, 14 cells per lane |
| Signals | fixed-time, 4.0 s cycle, 2.0 s NS then 2.0 s EW, offset `((ix+iy) mod 4) × 1.0 s` |
| Arterials | grid lines 2, 4 and 6 — cheaper to plan over, and twice the discharge rate |
| Episode | 4800 ticks at 24 Hz = **200 s of city time**, twenty routing turns of 10 s |
| Score | **parcels your own vans delivered** — a raw count, higher is better |

Score is deliberately **not** a share and **not** constant-sum: four greedy fleets can hold each
other to 300 parcels between them while four metered fleets clear 700. The results document carries
`total_delivered` and `jam_index_mean` so that collapse is visible in the numbers.

## The routing plan

Once every ten seconds a seat sets six numbers and two short strings:

```json
{"congestion_weight": 65, "patience": 40, "dispatch": 80, "spread": 60,
 "corridor": [0, 1], "avoid": [1, 1], "priority": "near",
 "note": "centre is at 9 and my stalled_pct is over the city index; metering to 80",
 "say": "hold at 80, skip centre"}
```

A deterministic Dijkstra router applies that plan to all fifty vans at 24 Hz:

```
cost(lane) = ((laneBase + jamTerm + avoidTerm) * corridorFactor) div 100
laneBase   = 48 arterial, 64 local
jamTerm    = (congestion_weight * vans_in_lane * 24) div 100
avoidTerm  = 240 when the lane's head node is in the avoided district
corridorFactor = 60 when both endpoints are in the preferred district, else 100
```

`congestion_weight 0` is pure shortest path — fast when the city is empty, and the fastest way to
build a jam when it is not.

## Policies

One image, two entrypoints, and the seat kind is chosen by env on the **player** container:

| env | seat |
|---|---|
| `PLAYER_PROMPT=<strategy text>` | an LLM seat; the game server sends this text plus the seat's view to Claude once per turn |
| `PLAYER_SCRIPTED=dispatcher` | congestion-aware shortest path with jam-triggered metering (the strong baseline, and the certification player) |
| `PLAYER_SCRIPTED=beeline` | pure greedy shortest path at full throttle (the weak baseline, and the villain of the idea) |

Neither set ⇒ `dispatcher`. All four decision paths live in the **game server**, so the recorded
plan stream is reproducible with no network in the loop, and an episode with no credentials at all
still completes — on the scripted layer, in seconds.

## Watching it

The replay is a **static wasm bundle**, never a pod. It re-runs the integer sim from the recorded
plan stream in the browser, so every lane's occupancy is re-derived rather than transported: the
288 lanes are drawn as bars coloured by occupancy and a jam is literally a stain crawling backwards
out of an intersection. Four delivery counters race in the corners over their own depots, the plan
chips show each fleet's current `reprice / dispatch` **before** the roads change, and the endcard
prices the commons: total delivered, mean and peak jam, gridlock count, and each fleet's stalled
van-minutes.

## Anonymity

Fleet aliases (`Copper`, `Cobalt`, `Verde`, `Saffron`) are properties of the **depot corner**, never
of the seat, and the seat → depot permutation is drawn from the episode seed and re-drawn every
episode. No prompt, view or event body ever contains a real player name. Ganging up to jam a rival
is in-game politics and is allowed; targeting a specific author is not possible.

## Build and test

CI is the harness (`.github/workflows/ci.yml`): every `tests/*.nim` twice (debug and `-d:release`),
a raw-Docker one-episode smoke from the certification fixture, and the wasm bundle opened in
headless chromium against the replay that smoke just produced.

```bash
nimby --global sync nimby.lock
nim r --path:src tests/test_traffic.nim
docker build -t coworld-gridlock:ci .
./tools/ci/docker_smoke.sh coworld-gridlock:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

Rules in [docs/RULES.md](docs/RULES.md); the wire protocol in
[docs/PROTOCOL.md](docs/PROTOCOL.md); the design note in
[docs/plans/2026-08-23-gridlock-design.md](docs/plans/2026-08-23-gridlock-design.md).
