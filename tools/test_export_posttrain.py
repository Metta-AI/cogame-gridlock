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
        subprocess.run(
            [str(BINARY), str(output), "10", variant, "source-test", "a" * 40],
            cwd=ROOT,
            check=True,
        )
        manifest = json.loads((output / "manifest.json").read_text())
        assert manifest["game"] == "gridlock" and manifest["variant"] == variant
        assert len(manifest["runs"]) == 10
        assert manifest["decisions"] == 10 * turns * 4
        assert not (output / "train.jsonl").exists()
        assert not (output / "validation.jsonl").exists()
        assert all(
            run["turns"] == turns and len(run["scores"]) == 4
            for run in manifest["runs"]
        )
        events = [
            json.loads(line)
            for line in (output / "trajectories.jsonl").read_text().splitlines()
        ]
        episodes = [event for event in events if event["event_type"] == "episode"]
        assert len(episodes) == 10
        assert {event["seed_family"] for event in episodes} == {
            f"gridlock-{seed}" for seed in range(1, 11)
        }
        assert (output / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
        decisions = [event for event in events if event["event_type"] == "decision"]
        assert len(decisions) == manifest["decisions"]
        assert all(event["status"] == "completed" for event in episodes)
        for row in decisions:
            (attempt,) = row["attempts"]
            assert attempt["origin"] == "teacher"
            assert attempt["policy"] == "dispatcher-view"
            assert attempt["accepted"]
            assert row["selected_attempt_id"] == attempt["attempt_id"]
            assert attempt["parsed_action"] == row["executed_action"]
            view = json.loads(attempt["prompt"][1]["content"])
            reply = json.loads(attempt["response"])
            assert attempt["prompt"][0]["role"] == "system"
            assert row["source_revision"] == "a" * 40
            assert "you" in view and "city" in view
            assert set(reply) >= {
                "congestion_weight",
                "patience",
                "dispatch",
                "spread",
                "priority",
            }
            assert "tokens" not in attempt["prompt"][1]["content"]
            for field in (
                "platform_call_id",
                "request",
                "model",
                "decoder",
                "raw_response",
                "response_headers",
                "provider_request_id",
                "response_body_b64",
                "response_headers_b64",
                "response_complete",
                "http_status",
                "response_reader_joined",
                "prompt_token_ids",
                "sampled_token_ids",
                "behavior_logprobs",
                "latency_ms",
            ):
                assert attempt[field] is None, field
        print(
            variant,
            len(episodes),
            len(decisions),
            "canonical model-free teacher decisions",
        )
