"""Play both certified Gridlock variants through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


BINARY = Path(sys.argv[1]).resolve()
MANIFEST = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"


def play(variant: str, teacher: bool) -> None:
    process = subprocess.Popen(
        [str(BINARY), str(MANIFEST), variant], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, text=True, bufsize=1, cwd="/tmp",
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(13)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"gridlock-{variant}-{teacher}",
                               "players": 4})
        decisions = 0
        widths = set()
        while observation["kind"] == "decision":
            assert observation["game"] == "gridlock"
            assert observation["decision_id"] == decisions
            view = observation["semantic_view"]
            assert view == {"system": observation["messages"][0]["content"],
                            "user": observation["messages"][1]["content"]}
            assert "local-seat" not in json.dumps(view)
            encoding = request({"kind": "encode"})
            assert encoding["decision_id"] == decisions
            widths.add(len(encoding["values"]))
            assert encoding["actions"] == [{"choice": i} for i in range(4)]
            choice = (json.loads(request({"kind": "teacher"})["response"])
                      if teacher else rng.choice(encoding["actions"]))
            result = request({"kind": "step", "decision_id": decisions,
                              "response": json.dumps(choice)})
            assert result["kind"] == "accepted" and result["action"] == choice
            observation = result["observation"]
            decisions += 1
            assert decisions <= (80 if variant == "default" else 48)
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1", "2", "3"}
        assert set(observation["utilities"]) == set(observation["scores"])
        assert all(abs(observation["utilities"][seat] -
                       observation["scores"][seat] /
                       (observation["scores"][seat] + 100)) < 1e-9
                   for seat in observation["scores"])
        assert widths == {45}
        assert decisions == (80 if variant == "default" else 48)
        print(variant, "teacher" if teacher else "random", decisions,
              observation["scores"])
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    for name in ("default", "rush"):
        for use_teacher in (True, False):
            play(name, use_teacher)
