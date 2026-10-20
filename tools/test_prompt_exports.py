"""Qualify complete production candidate matches and replay reconstruction."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY, REPLAY = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
OUTPUT = Path(sys.argv[3]).resolve()
REVISION = sys.argv[4]
OUTPUT.mkdir(parents=True, exist_ok=False)
families = set()
identities = set()
for variant, turns in (("default", 20), ("rush", 12)):
    for wording in ("mixed",):
        target = OUTPUT / f"{variant}-{wording}"
        subprocess.run(
            [
                BINARY,
                str(target),
                "10",
                variant,
                "source-validation",
                REVISION,
                wording,
                "0",
            ],
            cwd=ROOT,
            check=True,
        )
        manifest = json.loads((target / "manifest.json").read_text())
        assert manifest["review_required"]
        events = [json.loads(line) for line in (target / "trajectories.jsonl").read_text().splitlines()]
        decisions = {}
        episodes = []
        for event in events:
            if event["event_type"] == "decision":
                decisions.setdefault(event["episode_id"], []).append(event)
            else:
                assert event["event_type"] == "episode"
                episodes.append(event)
        assert len(episodes) == 10
        for episode in episodes:
            identity = episode["episode_id"]
            family = episode["seed_family"]
            assert identity not in identities
            identities.add(identity)
            families.add(family)
            assert episode["status"] == "completed"
            rows = decisions[identity]
            assert len(rows) == turns * 4
            for row in rows:
                (attempt,) = row["attempts"]
                assert attempt["accepted"] and attempt["origin"] == "teacher"
                assert row["executed_action"] == attempt["parsed_action"] == json.loads(attempt["response"])
                view = row["observation"]
                assert (
                    view.pop("prompt_selection")["variant"]
                    == ("canonical", "plain", "numbered", "questions", "reordered")[
                        (int(family.removeprefix("gridlock-")) - 1) % 5
                    ]
                )
                (evidence,) = view.pop("prompt_attempts")
                assert evidence["attempt_id"] == attempt["attempt_id"]
                metadata = evidence["prompt_template"]
                for message in attempt["prompt"]:
                    assert (
                        metadata[message["role"] + "_sha256"] == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            outcome = episode["outcome"]
            assert (
                outcome.pop("prompt_selection")["variant"]
                == ("canonical", "plain", "numbered", "questions", "reordered")[
                    (int(family.removeprefix("gridlock-")) - 1) % 5
                ]
            )
            subprocess.run(
                [REPLAY, str(target / f"{identity}.replay.json")],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        print(
            variant,
            wording,
            "ten complete games, exact actions and replay PASS",
            flush=True,
        )
assert len(identities) == 20 and len(families) == 10
