# Agent operating guide — cogame-gridlock

Orientation for coding agents working in this repo. The rules live in
[docs/RULES.md](docs/RULES.md), the wire protocol in
[docs/PROTOCOL.md](docs/PROTOCOL.md), and the design note this repo was built
from in [docs/plans/2026-08-23-gridlock-design.md](docs/plans/2026-08-23-gridlock-design.md).
Forked from `Metta-AI/coworld-ctf` (paintbot); every convention there holds
here unless the design note says otherwise.

## Layout

- `src/gridlock.nim` — entrypoint. **Seed randomisation happens HERE, before
  `config.update`**, so every seed-derived draw (the seat→depot permutation
  and the canonical destination schedule) follows the FINAL seed.
- `src/gridlock_player.nim` — the thin player: one `register` frame, then it
  only receives. It decides nothing.
- `src/gridlock/`
  - `types.nim` — consts, `GameVersion` (the replay-compatibility gate), every
    record the step loop touches (including `Sim`), PCG32, and the rune-safe
    truncation helpers. Everything lives here so the rule modules import ONE
    module and the dependency graph stays a DAG.
  - `city.nim` — loads and validates `data/gridcity.cityspec.json` and keeps
    the raw JSON for pinning into replays.
  - `graph.nim` — nodes, the 288 directed lanes, districts, arterials, the
    signal plan, the cost model and Dijkstra.
  - `traffic.nim` — cell occupancy, movement, the pending-replan FIFO.
  - `parcels.nim` — the canonical destination schedule and priority selection.
  - `rules.nim` — turn bookkeeping, congestion statistics, the invariant
    guards, the score and the results document.
  - `plan.nim` — the routing-plan schema, tolerant parsing, repair, and the
    derived router coefficients.
  - `baselines.nim` — `dispatcher` and `beeline`.
  - `view.nim` — the per-seat observation. What is hidden is a rule, not an
    optimisation; `tests/test_view.nim` enforces it.
  - `llm.nim` — the batch client. Gridlock is a SIMULTANEOUS-decision game:
    all four seats go out as ONE `curly.makeRequests` batch per turn.
  - `sim.nim` — the step loop and the re-exports; `import gridlock/sim` sees
    everything.
  - `replay.nim`, `render.nim`, `server.nim`, `roster.nim`, `state.nim`,
    `config.nim`, `events.nim`, `startup.nim`, `wire_constants.nim`.
- `tests/` — one standalone program per file (ci.yml runs each twice, debug
  and `-d:release`). Shared helpers live in `tests/support/` so the
  `tests/*.nim` glob never executes a helper as a test.

## Three properties that are not negotiable

1. **The step path is integer.** No `sin`/`cos`/`exp`/`sqrt`/float anywhere in
   `graph.nim`, `traffic.nim`, `parcels.nim` or `stepTick`, and no
   `-ffast-math`. It is what makes the native build and the emscripten build
   agree bit for bit, and `tests/test_traffic.nim` greps for it.
2. **Every recorded string is truncated on RUNE boundaries.** A byte-truncated
   multi-byte character renders in a browser and fails a strict UTF-8 JSON
   parser — which is how a replay silently stops being loadable.
   `clipRunes` / `cleanLine` in `types.nim`, and nothing else.
3. **The viewer pairing is a matched pair.** `replay-viewer/config.nims`
   carries NEITHER `MODULARIZE` nor `EXPORT_NAME`, and
   `static_replay_worker.js` waits for `Module.onRuntimeInitialized` and pulls
   the module in with `importScripts`. Mixing the two lineages throws nothing,
   logs nothing, and hangs the viewer on "Loading replay…" forever.
   `tests/test_viewer.nim` asserts both halves.

   And **nothing may call into the wasm module before `main()` has run**:
   emscripten fires `onRuntimeInitialized` BEFORE `callMain()`, while Nim
   initialises its module globals (the 288-lane road table among them) inside
   main. An export called first reads an EMPTY graph — no route resolves, no
   van is dispatched, and the viewer replays a frozen city that fails the
   first keyframe digest. Both drivers defer by one macrotask.

## Changing the rules

`GameVersion` in `src/gridlock/types.nim` gates replay compatibility. Bump it
on any rule change, prepend a `GVnn (short rule name): HEADLINE` line to the
changelog comment above it, and **re-record `tests/fixtures/golden_digests.json`**
— delete the file, run `nim r --path:src tests/test_determinism.nim`, and
commit what it writes. A stale golden fixture is a rule change nobody reviewed.

If you touch the results document, edit `coworld_manifest_template.json`'s
`results_schema` in the same commit: `tests/test_manifest.nim` asserts the two
key sets are equal.

If you touch `README.md`, `docs/RULES.md` or `docs/PROTOCOL.md`, regenerate the
manifest (`python3 scripts/make_manifest.py`): the manifest inlines all three
as `game.docs` and the test asserts they match byte for byte.

## Building and testing

CI is the harness (`.github/workflows/ci.yml`): every `tests/*.nim` twice, a
raw-Docker one-episode smoke from the certification fixture, and the wasm
bundle opened in headless chromium against the replay that smoke produced.

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
nim r --path:src tests/test_traffic.nim
docker build -t coworld-gridlock:ci . && ./tools/ci/docker_smoke.sh coworld-gridlock:ci
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
node tools/wasm_replay_smoke.cjs dist/static-replay-viewer dist/smoke/replay.json
node tools/ci/viewer_smoke.mjs --bundle dist/static-replay-viewer \
  --replay dist/smoke/replay.json --timeout 90
```

`tools/ci/viewer_smoke.mjs` is copied VERBATIM from coworld-builder's
templates and takes no substitutions. Do not edit it here.
