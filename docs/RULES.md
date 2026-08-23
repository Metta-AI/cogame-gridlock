# Gridlock — rules

Four parcel fleets share one city. A fleet scores one point per parcel **its own** vans deliver.
Nobody controls the traffic lights.

## The city

- **81 intersections** on a 9 × 9 grid, `(ix, iy)` with `ix, iy ∈ 0..8`, origin top-left.
  Node `(ix, iy)` sits at pixel `(64 + 112·ix, 64 + 112·iy)`, so the board is 1024 × 1024.
- **144 road segments** join horizontally and vertically adjacent nodes; each carries **two directed
  lanes**, one per direction, for **288 lanes** numbered `0 … 287` in a fixed order (horizontal
  segments first, row-major, → then ←; then vertical segments, column-major, ↓ then ↑).
- A lane is a chain of **14 cells** of 8 px. Cell 0 is just downstream of the lane's tail
  intersection; **cell 13 is the stop line**. **A cell holds at most one vehicle** — that single rule
  is what produces spillback.
- A segment is an **arterial** if it lies on `ix ∈ {2,4,6}` or `iy ∈ {2,4,6}`. Arterials are cheaper
  to plan over and discharge twice as fast. They are also where everyone's greedy plan goes.
- The node grid is partitioned into a **3 × 3 district grid**, `NW N NE / W CENTRE E / SW S SE`.
  A district is how a policy names a place and how the view reports congestion.
- **Four depots**, one per quadrant, on the mirror orbit of `(1,1)`:
  `D0 (1,1) Copper`, `D1 (7,1) Cobalt`, `D2 (1,7) Verde`, `D3 (7,7) Saffron`.
  Alias and colour belong to the **depot**, never to the seat; the seat → depot permutation is drawn
  from the episode seed and re-drawn every episode.
- **Signals** are fixed-time and identical everywhere: a 96-tick (4.0 s) cycle, north–south green for
  the first 48 ticks, east–west for the rest, with a per-node offset `((ix+iy) mod 4) × 24` so
  diagonal green waves exist for a router to ride. `phase(n,t) = ((t + offset(n)) mod 96) < 48`.

## Vehicles and parcels

Each seat owns **50 identical vans**. A van is `docked` (0), `loaded` (1, carrying a parcel),
`empty` (2, returning), or `stalled` (3, on the road and not advanced for 24 ticks). Vans never
crash, never break down, and never interact except by occupying cells.

Every 24 ticks (1.0 s) each fleet receives exactly one new order into a backlog capped at **80**.
Demand is identical up to symmetry: one canonical destination sequence is drawn over the non-depot
nodes and the fleet at depot `Dj` receives `mirror_j` of it, so all four fleets face the same
pattern reflected onto their own quadrant — and all four pull through CENTRE equally.

## Routing

Every van plans over the directed lane graph with **Dijkstra** (integer costs, ties by ascending
lane id):

```
cost(lane) = ((laneBase + jamTerm + avoidTerm) * corridorFactor) div 100 + tieNoise
laneBase   = 48 arterial / 64 local
jamTerm    = (congestion_weight * q(lane) * 24) div 100      q = vans now in the lane, 0..14
avoidTerm  = 240 when the lane's HEAD node is in the avoided district
corridorFactor = 60 when BOTH endpoints are in the preferred district, else 100
```

With `congestion_weight = 100` a full lane carries `jamTerm = 336` against a base of 48–64: the road
is effectively closed. With `congestion_weight = 0` the router is pure greedy shortest path.

A van is pushed onto the pending-replan FIFO when it has no route, when its target changed, when it
was served into a node whose next lane already holds `replanQueue = 3 + patience·10/100` vans, or at
the start of a turn. At most **24 Dijkstra runs execute per tick**; a van still waiting keeps
driving its old route.

## The tick, in order, with no exceptions

1. **Turn clock.** Every 240 ticks: install the four routing plans, enqueue every on-road van for a
   replan (ascending global van index), roll the per-turn counters, emit `turn_start`, one `plan` per
   seat and one `meter` per seat.
2. **Signals.** A pure function of the tick and the node offset.
3. **Orders.** Every 24 ticks, one parcel per fleet, skipping any fleet at the backlog cap.
4. **Loading.** Every docked van without a parcel and with a non-empty backlog begins loading. It
   takes the order chosen by `priority`: `near` = smallest Manhattan distance from the depot (ties →
   oldest), `far` = largest (ties → oldest), `fifo` = oldest. Loading takes 12 ticks.
5. **Dispatch (fleet metering).** Every 12 ticks, per fleet:
   `activeCap = (dispatch·50 + 50) div 100`, `releasePerStep = 1 + (100 − spread)·5 div 100`
   (spread 0 → six per step, 100 → one). While the fleet is under its cap, under its per-step
   allowance, has a loaded-and-waiting van, and cell 0 of that van's first lane is empty, release it.
   **This is the only place a fleet can hold itself back, and it is the commons lever.**
6. **Movement.** Every 3 ticks, per lane in lane order, walk the vans **downstream-first**
   (cell 12 → cell 0); a van advances one cell if that cell is empty. A van at the stop line does not
   move here — it is the intersection's business.
7. **Intersection capacity and signal service.** Every 6 ticks, per node in node order, for each
   **green** approach in the fixed order N, E, S, W: discharge up to **2 (arterial) or 1 (local)**
   vans from the stop line, oldest first. A discharge is legal only if the receiving cell is empty.
   An illegal discharge is simply not made.
8. **Spillback.** There is no step for it, and that is the point: a blocked van stays at the stop
   line, movement cannot enter an occupied cell, so a full receiving lane freezes its feeding
   approach, which fills, which freezes the approaches feeding *that*.
9. **Pickup and delivery**, resolved inside the discharge:
   - `loaded` van crossing into its parcel's destination → `delivered += 1`, a `deliver` event with
     the trip time, target becomes the depot, and it enters cell 0 of the first lane of its return
     route. If that cell is occupied it stays at the stop line — a delivery bay that blocks the road.
   - `empty` van crossing into **its own** depot → absorbed into the dock, which never blocks.
   - Crossing any **other** fleet's depot does nothing: you cannot deliver to, load at, or steal from
     a rival depot.
10. **Replans.** Pop up to 24 vans from the FIFO and run Dijkstra with the fleet's current plan and
    the current occupancies.
11. **Statistics.** Per-lane occupancy and per-van stall ticks accumulate. Every 48 ticks the 3 × 3
    district digits and the city `jam_index` are recomputed and a `heat` event is emitted. A lane
    crossing 11 vans emits `jam`; falling back below 6 emits `jam_clear`. Four or more fully blocked
    lanes whose head nodes lie in one district emit one `gridlock` for that district (at most one per
    district per 240 ticks).
12. **Keyframe.** Every 24 ticks: the tick, all 200 vans' `(lane, cell, state)`, the four delivered
    counters, the four on-road counts, the four backlog sizes, the city jam index, and the u32 state
    digest.
13. **Seek snapshot.** Every 240 ticks the runtime keeps a full state snapshot in memory so a
    backward seek in the viewer replays at most one turn. Snapshots are never written to the replay.
14. **End check.**

## Scoring and endings

```
score[s] = float(delivered[s])       # raw count, NOT normalised. Higher is better.
win[s]   = delivered[s] == max(delivered) and that maximum is unique
```

`winner` is that slot index, or `null` on a tie.

| `reason` | `end_rule` | when |
|---|---|---|
| `complete` | `full_time` | all 4800 ticks simulated — the normal ending |
| `deadline` | `wall_clock` | the 660 s engine budget elapsed first; the counters are scored as they stand and the replay is complete and self-consistent up to the stop tick |
| `fault` | `sim_fault` | an invariant guard tripped: two vans in one cell, a van off-graph, a delivered counter that decreased, a backlog over the cap. All scores 0, `winner: null` |
| `fault` | `host_error` | an unexpected server-side exception, same treatment |

No other value may appear. A seat that never connects does **not** end the episode: its fleet is
driven by the `dispatcher` baseline for the whole match, the no-show is reported to
`COGAME_PLAYER_FAILURE_URI`, and the match plays to full time.

## Determinism

Same seed + same resolved plan stream ⇒ the same digest at every keyframe, in the native build *and*
in the emscripten build. The whole step is integer: no `sin`, `cos`, `tan`, `exp`, `ln`, `pow`,
`sqrt`, `hypot`, `fmod` or float arithmetic appears in the step path, and `-ffast-math` is banned.
A source-grep test enforces both.
