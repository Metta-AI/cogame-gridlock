# Gridlock post-training

The exporter records complete production Gridlock matches against the shipped
`dispatcher` teacher. Every routing turn captures the hosted system prompt,
the acting seat's public view, and a teacher plan accepted by the game's
reply parser. Four plans resolve simultaneously through the native simulator.
Both certified variants are supported.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/gridlock-posttrain tools/export_posttrain.nim
/tmp/gridlock-posttrain /tmp/gridlock-default-dataset 10 default
/tmp/gridlock-posttrain /tmp/gridlock-rush-dataset 10 rush
python3 tools/test_export_posttrain.py /tmp/gridlock-posttrain
```

`train.jsonl` and `validation.jsonl` split complete games by seed. The
manifest records source revision, variant, final production scores, and row
counts. The exporter requires ten matches and refuses to overwrite an output
directory. Ten default matches yield 640 train and 160 validation decisions;
ten rush matches yield 384 and 96.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/gridlock-default-dataset \
  --output /tmp/gridlock-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

These examples distill the scripted teacher. The game's delivered-parcel
score is not constant-sum; no shared normalization is applied.

All 800 default and 480 rush examples fit 4,096 tokens with the local
WordLevel smoke tokenizer. One CPU optimizer step reduced four-example
validation loss from 1.71899 to 1.71315 for each variant. This verifies the
post-training path, not improved league play.

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
