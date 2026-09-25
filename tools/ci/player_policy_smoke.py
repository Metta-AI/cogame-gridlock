#!/usr/bin/env python3
"""Run mixed Gridlock players against local Jev and Claude-shaped model stubs."""

import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class ModelHandler(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(data)
        if self.path == "/v1/systemone":
            answers = {}
            for name, question in request["questions"].items():
                choices = list(question["criteria"])
                chosen = "30" if name == "dispatch" else choices[0]
                answers[name] = {
                    "type": "choice",
                    "probabilities": {
                        choice: float(choice == chosen) for choice in choices
                    },
                }
            body = {"answers": answers}
            self.calls.append(
                ("jev", self.headers.get("x-coworld-player-slot"), request)
            )
        elif self.path.startswith("/model/") and self.path.endswith("/invoke"):
            body = {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(
                            {
                                "congestion_weight": 80,
                                "patience": 20,
                                "dispatch": 20,
                                "spread": 90,
                                "corridor": None,
                                "avoid": [1, 1],
                                "priority": "far",
                                "note": "Stub prompt plan",
                                "say": "route around jams",
                            }
                        ),
                    }
                ]
            }
            self.calls.append(("prompt", None, request))
        else:
            self.send_error(404)
            return
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def main(game_bin, player_bin):
    model_port = free_port()
    game_port = free_port()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", model_port), ModelHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix="gridlock-player-smoke-") as work:
        directory = Path(work)
        config = {
            "tokens": [f"token-{slot}" for slot in range(4)],
            "players": [{"name": f"P{slot + 1}"} for slot in range(4)],
            "num_agents": 4,
            "seed": 42,
            "episodeTicks": 480,
            "turnTicks": 240,
            "minTurnSpacingSeconds": 0,
            "playerConnectTimeoutSeconds": 5,
            "wallClockBudgetSeconds": 90,
            "episodeTimeoutSeconds": 180,
            "cityPath": "gridcity",
        }
        (directory / "config.json").write_text(json.dumps(config))
        env = os.environ.copy()
        for name in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "TYPESAFE_API_KEY",
            "METTA_CAPTURE_URL",
            "METTA_CAPTURE_KEY",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "AWS_BEARER_TOKEN_BEDROCK",
        ):
            env.pop(name, None)
        game_env = env | {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(game_port),
            "COGAME_CONFIG_URI": f"file://{directory / 'config.json'}",
            "COGAME_RESULTS_URI": f"file://{directory / 'results.json'}",
            "COGAME_SAVE_REPLAY_URI": f"file://{directory / 'replay.json'}",
        }
        processes = [
            subprocess.Popen(
                [game_bin],
                env=game_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        ]
        try:
            for slot in range(4):
                player_env = env | {
                    "COWORLD_PLAYER_WS_URL": (
                        f"ws://127.0.0.1:{game_port}/player?slot={slot}&token=token-{slot}"
                    )
                }
                if slot == 0:
                    player_env["PLAYER_POLICY_KIND"] = "jev"
                    player_env["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"] = (
                        f"http://127.0.0.1:{model_port}"
                    )
                elif slot == 1:
                    player_env["PLAYER_PROMPT"] = "Route around traffic and meter vans."
                    player_env["AWS_ENDPOINT_URL_BEDROCK_RUNTIME"] = (
                        f"http://127.0.0.1:{model_port}"
                    )
                else:
                    player_env["PLAYER_SCRIPTED"] = "dispatcher"
                processes.append(
                    subprocess.Popen(
                        [player_bin],
                        env=player_env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                    )
                )
            outputs = []
            for process in processes:
                output, _ = process.communicate(timeout=75)
                outputs.append(output.decode(errors="replace"))
                assert process.returncode == 0, output.decode(errors="replace")
            results = json.loads((directory / "results.json").read_text())
            replay = json.loads((directory / "replay.json").read_text())
            assert results["reason"] == "complete", results
            assert results["turns_llm"][:2] == [2, 2], results["turns_llm"]
            assert results["fallback_turns"] == [0, 0, 0, 0], results["fallback_turns"]
            assert results["policy_kinds"] == ["llm", "llm", "scripted", "scripted"]
            assert replay["results"]["turns_llm"][:2] == [2, 2]
            jev_calls = [call for call in ModelHandler.calls if call[0] == "jev"]
            prompt_calls = [call for call in ModelHandler.calls if call[0] == "prompt"]
            assert len(jev_calls) == 2, len(jev_calls)
            assert len(prompt_calls) == 2, len(prompt_calls)
            assert all(call[1] == "0" for call in jev_calls)
            assert all(len(call[2]["questions"]) == 9 for call in jev_calls)
            print(
                "Gridlock mixed native episode: 2 Jev and 2 prompt plans accepted; zero fallback"
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            server.shutdown()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
