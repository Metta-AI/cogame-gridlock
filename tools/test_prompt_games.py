"""Complete published Gridlock games through the actual numeric and text bridges."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRAIN = ["canonical", "plain", "numbered", "questions", "reordered"]
WORDINGS = TRAIN + ["heldout-briefing", "heldout-reference"]


def play(binary, variant, wording, seed, language, prompt_seed=0, original=False):
    process = subprocess.Popen(
        [
            str(binary),
            str(ROOT / "coworld_manifest_template.json"),
            variant,
            *(["--language", "Private operator strategy."] if language else []),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )

    def request(payload):
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        assert line, process.poll()
        return json.loads(line)

    rows = []
    systems = set()
    try:
        obs = request(
            {
                "kind": "reset",
                "players": 4,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "evaluation",
            }
        )
        while obs["kind"] == "decision":
            system, user = (message["content"] for message in obs["messages"])
            systems.add(system)
            if not original:
                meta = obs["semantic_view"]["prompt_template"]
                assert meta["bank"] == "gridlock-rules-v1"
                assert meta["variant"] == (
                    TRAIN[prompt_seed % 5] if wording == "mixed" else wording
                )
                assert (
                    meta["system_sha256"] == hashlib.sha256(system.encode()).hexdigest()
                )
                assert meta["user_sha256"] == hashlib.sha256(user.encode()).hexdigest()
            view = json.loads(user.split("\n\n", 1)[1] if language else user)
            encoding = request({"kind": "encode"})
            assert len(encoding["values"]) == 45
            action = request({"kind": "teacher"})["response"]
            result = request(
                {"kind": "step", "decision_id": obs["decision_id"], "response": action}
            )
            assert result["kind"] == "accepted"
            rows.append((view, encoding, result["action"]))
            obs = result["observation"]
        assert len(rows) == (80 if variant == "default" else 48)
        assert len(systems) == 1
        assert obs["kind"] == "terminal"
        return rows, obs, systems.pop()
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=10) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    count = 0
    for variant in ("default", "rush"):
        for language in (False, True):
            for seed in ("wording-1", "wording-2"):
                canonical = play(binary, variant, "canonical", seed, language)
                count += 1
                if len(sys.argv) == 3:
                    assert canonical == play(
                        Path(sys.argv[2]).resolve(),
                        variant,
                        "canonical",
                        seed,
                        language,
                        original=True,
                    )
                for wording in WORDINGS[1:]:
                    actual = play(binary, variant, wording, seed, language)
                    assert actual[:2] == canonical[:2]
                    assert actual[2] != canonical[2]
                    count += 1
                for prompt_seed in range(5):
                    actual = play(binary, variant, "mixed", seed, language, prompt_seed)
                    assert actual[:2] == canonical[:2]
                    count += 1
    print(
        count,
        "complete published games preserve actions, private views, encodings and scores",
    )
