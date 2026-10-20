# Gridlock post-training

Gridlock provides five training rule explanations (`canonical`, `plain`, `numbered`,
`questions`, `reordered`) and two evaluation-only explanations
(`heldout-briefing`, `heldout-reference`). `mixed` selects one training wording
using an explicit nonnegative `promptSeed`, independently of the simulation seed.
Selection stays fixed through all turns and retries. Canonical text and the
routing schema remain unchanged. The `gridlock-rules-v2` bank varies fleet control,
city capacity, signals, spillback, delivery scoring, and communication limits.

The host supplies selection to native players in private decision frames. Deploy
the game and player from the same revision: the player requires `prompt_config`.
Existing native trajectories retain actual requests, responses, retries, installed
plans and reader cleanup. Prompt selection never enters the public replay.

The bridge accepts `MANIFEST VARIANT --language [OPERATOR_PROMPT]`. Reset
commands accept `promptVariant`, `promptSeed`, and `split`. Held-out wordings
require an explicit `evaluation`, `validation`, or `test` split; omitted, training,
and unrecognized splits reject them. Rendered message hashes accompany each private observation.

The source exporter accepts `OUTPUT EPISODES VARIANT GAME_VERSION SOURCE_REVISION`
and optional `PROMPT_VARIANT PROMPT_SEED`. Supply the immutable reviewed source
revision, including for archived binaries. Mixed exports cycle the five training wordings between games. At least ten complete matches are
required. Outputs contain canonical private candidate trajectories, not automatic
training or validation labels. Independent review owns admission and splits.
Seed families group wording and mode replicas so they cannot leak across splits.
Both certified variants use the shipped dispatcher teacher and unchanged scores.

Inspect the imported manifest, including `prompt_wordings`, after target filtering
and splitting. Seeds 1–10 produced no validation targets in the shared importer.
A measured collection of 20 mixed games per variant, beginning at seed 1 with
prompt seed 0, retained all five training wordings and both splits: default
1,440 training/160 validation targets, rush 864/96. Other seed ranges and filters
need their own coverage check. Source export alone does not establish admission.

Run `python3 tools/test_prompt_games.py BRIDGE [ORIGINAL_BRIDGE]` for complete
published matches covering every wording and mixed seed. It compares private
views, installed actions, numeric encodings, terminal scores and canonical text.
These deterministic checks do not establish improved model play or prevention of
training collapse. Matched learning comparisons remain unrun.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes the same hosted observation at each turn
and 45 numeric values drawn only from the public view. Four actions select
the published `dispatcher` or `beeline` plan, or a dispatcher plan with 40%
or 60% dispatch. All four seats choose against one turn state before the
native simulator advances. Terminal scores are delivered parcels; each seat's
utility is `score / (score + 100)` to fit the RL contract's [0, 1] range
while preserving the game's non-constant-sum objective. The post-training
path above supports arbitrary routing-plan JSON.

```sh
nim c -d:release --path:src -o:/tmp/gridlock-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/gridlock-train-bridge
```

From a Metta checkout with the Coworld training stack installed, pass the
absolute bridge binary and manifest paths to `recipes.external.coworld.train`
for native PufferLib or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=4`; both `default` and `rush` variants are supported.

Both variants completed 512 Metta RL timesteps. At epoch ten, evaluation
mean return was 0.645 for default and 0.595 for rush. These pilots verify
the numeric observation and reward path; they do not establish stronger play.

Native PufferLib completed 4,096 CUDA timesteps per variant on metta1.
Checkpoint reload and held-out seeds 101 and 102 produced mean scores
180.5/184.0 for default and 171.2/178.2 for rush. Checkpoint SHA-256 values
were `b80a947f44ba19bfaa6ac4160f345a1b1e356ca676f7dbb7e86decf4e21a4a1c`
and `ea92171b5870908303e9acab9fdf29c50a34d2b4a37617cd5f74e6c12d58b69d`.

Episode IDs include requested selection, resolved wording, and prompt seed, so
matched explicit and mixed collections remain distinct. Scenario families and
shared importer ownership of review and splitting stay unchanged.
