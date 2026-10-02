"""Check complete Gridlock datasets and hosted prompt fidelity."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()
ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory() as directory:
    for variant, turns in (("default", 20), ("rush", 12)):
        output = Path(directory) / variant
        subprocess.run([str(BINARY), str(output), "10", variant, "source-test"], cwd=ROOT, check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert manifest["game"] == "gridlock" and manifest["variant"] == variant
        assert len(manifest["runs"]) == 10
        assert len(train) == manifest["train_examples"] == 8 * turns * 4
        assert len(validation) == manifest["validation_examples"] == 2 * turns * 4
        assert all(run["turns"] == turns and len(run["scores"]) == 4
                   for run in manifest["runs"])
        events = [json.loads(line) for line in (output / "trajectories.jsonl").read_text().splitlines()]
        episodes = [event for event in events if event["event_type"] == "episode"]
        assert len(episodes) == 10
        assert {event["seed_family"] for event in episodes} == {f"gridlock-{seed}" for seed in range(1, 11)}
        assert (output / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
        for row in train + validation:
            assert row["seed"] == "gridlock-" + row["episode_id"].rsplit("-", 1)[1]
            view = json.loads(row["prompt"][1]["content"])
            reply = json.loads(row["completion"][0]["content"])
            assert row["prompt"][0]["role"] == "system"
            assert row["game"] == "gridlock"
            assert "you" in view and "city" in view
            assert set(reply) >= {"congestion_weight", "patience", "dispatch", "spread", "priority"}
            assert "tokens" not in row["prompt"][1]["content"]
        print(variant, len(train), len(validation))
