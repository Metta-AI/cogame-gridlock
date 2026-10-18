"""Full published games with four real native players and unavailable inference."""

import hashlib
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER, REPLAY = (str(Path(arg).resolve()) for arg in sys.argv[1:4])
OUTPUT = Path(sys.argv[4]).resolve()
REVISION = sys.argv[5]
OUTPUT.mkdir(parents=True, exist_ok=False)
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
cases = [(variant, "canonical") for variant in variants]
if "--smoke" not in sys.argv:
    cases += [
        ("default", wording)
        for wording in (
            "plain",
            "numbered",
            "questions",
            "reordered",
            "heldout-briefing",
            "heldout-reference",
            "mixed",
        )
    ]
for variant, wording in cases:
    output = OUTPUT / f"{variant}-{wording}"
    output.mkdir(mode=0o700)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    # This socket is bound but never listens: native HTTP receives connection refusal.
    with socket.socket() as unavailable:
        unavailable.bind(("127.0.0.1", 0))
        config = {
            **variants[variant],
            "seed": 7,
            "promptVariant": wording,
            "promptSeed": 3,
            "tokens": [f"t{i}" for i in range(4)],
            "players": [{"name": f"native-{i}"} for i in range(4)],
        }
        (output / "config.json").write_text(json.dumps(config))
        env = {
            **os.environ,
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(port),
            "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
            "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
            "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
            "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
            "COWORLD_EPISODE_ID": f"gridlock-{variant}-{wording}",
            "COWORLD_GAME_VERSION": "source-validation",
            "COWORLD_SOURCE_REVISION": REVISION,
            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{unavailable.getsockname()[1]}",
            "COWORLD_LLM_MODEL": "unavailable/validation",
            "PLAYER_PROMPT": "Private routing strategy.",
            "PLAYER_SCRIPTED": "",
        }
        processes, logs = [], []
        try:
            log = (output / "game.log").open("w")
            logs.append(log)
            processes.append(
                subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
            )
            for _ in range(400):
                assert processes[0].poll() is None, (output / "game.log").read_text()
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game did not start")
            for seat in range(4):
                log = (output / f"player-{seat}.log").open("w")
                logs.append(log)
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                }
                processes.append(
                    subprocess.Popen(
                        [PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            for process in processes:
                assert process.wait(timeout=800) == 0
            events = [
                json.loads(line)
                for line in (output / "trajectory.jsonl").read_text().splitlines()
            ]
            decisions, episode = events[:-1], events[-1]
            assert episode["status"] == "completed"
            assert episode["outcome"]["final_tick"] == config["episodeTicks"]
            assert set(episode["outcome"]["player_cleanup"].values()) == {"joined"}
            turns = config["episodeTicks"] // config["turnTicks"]
            assert len(decisions) == turns * 4
            assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            replay = json.loads((output / "replay.json").read_text())
            systems = set()
            attempts = 0
            for decision in decisions:
                view = decision["observation"]
                assert (
                    view["turn_end_tick"] - view["turn_start_tick"]
                    == config["turnTicks"]
                )
                assert view["prompt_selection"]["variant"] == (
                    "questions" if wording == "mixed" else wording
                )
                plan = next(
                    p
                    for p in replay["plans"]
                    if p["seat"] == int(decision["seat"]) and p["turn"] == view["turn"]
                )
                assert decision["executed_action"] == {
                    k: v
                    for k, v in plan.items()
                    if k not in {"turn", "seat", "source", "latency_ms"}
                }
                assert decision["action_status"] == "fallback"
                assert len(decision["attempts"]) == 2
                evidence = {
                    item["attempt_id"]: item["prompt_template"]
                    for item in view["prompt_attempts"]
                }
                for index, attempt in enumerate(decision["attempts"]):
                    assert attempt["origin"] == "model" and not attempt["accepted"]
                    metadata = evidence[attempt["attempt_id"]]
                    system, user = (message["content"] for message in attempt["prompt"])
                    systems.add(system)
                    assert attempt["request"]["system"] == system
                    assert attempt["request"]["messages"][0]["content"] == user
                    assert ("previous reply was invalid" in user) == (index == 1)
                    assert (
                        metadata["system_sha256"]
                        == hashlib.sha256(system.encode()).hexdigest()
                    )
                    assert (
                        metadata["user_sha256"]
                        == hashlib.sha256(user.encode()).hexdigest()
                    )
                    assert attempt["response_reader_joined"] is True
                    attempts += 1
            assert len(systems) == 1
            assert (
                "Private routing strategy." not in (output / "replay.json").read_text()
            )
            subprocess.run(
                [REPLAY, str(output / "replay.json")],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            print(
                variant,
                wording,
                len(decisions),
                "decisions",
                attempts,
                "actual native attempts and replay PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
