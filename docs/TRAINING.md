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
