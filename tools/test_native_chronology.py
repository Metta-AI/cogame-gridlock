"""Actual native reference players, HTTP fixture, and authoritative whole engine. Zero receipt authority."""

import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid
import base64
from websockets.sync.client import connect
from websockets.sync.server import serve
from pathlib import Path

mode = sys.argv[4]
assert mode in ("finished_start", "request_rewrite", "finished_bytes_rewrite")
root = Path(sys.argv[1]).resolve()
server_binary, player_binary = (Path(value).resolve() for value in sys.argv[2:4])
root.mkdir(mode=0o700)
requests = []


class Messages(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["content-length"]))
        request = json.loads(body)
        seat = int(self.headers["X-Coworld-Player-Slot"])
        requests.append((seat, request))
        text = json.dumps({"dispatch": 70, "patience": 50})
        payload = {
            "model": request["model"],
            "content": [{"type": "text", "text": text}],
            "usage": {"input_tokens": 32768, "output_tokens": 2},
            "stop_reason": "end_turn",
            "sampling_evidence": {
                "prompt_token_ids": list(range(32768)),
                "completion_token_ids": [42, 2],
                "behavior_log_probs": [-0.5, -0.2],
                "stop_reason": "eos",
            },
        }
        raw = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *args):
        pass


http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Messages)
thread = threading.Thread(target=http.serve_forever)
config = {
    "seed": 1,
    "episodeTicks": 240,
    "turnTicks": 240,
    "minTurnSpacingSeconds": 0,
    "wallClockBudgetSeconds": 120,
    "episodeTimeoutSeconds": 300,
    "playerConnectTimeoutSeconds": 5,
    "players": [{"name": f"p{i}"} for i in range(4)],
    "tokens": [f"token-{i}" for i in range(4)],
}
(root / "config.json").write_text(json.dumps(config))
port_socket = socket.socket()
port_socket.bind(("127.0.0.1", 0))
port = port_socket.getsockname()[1]
port_socket.close()
injected = []


def proxy_handler(client):
    with connect(
        f"ws://127.0.0.1:{port}/player" + client.request.path.removeprefix("/"),
        max_size=16 * 1024 * 1024,
    ) as backend:

        def relay():
            for frame in backend:
                client.send(frame)
                if json.loads(frame)["type"] == "evidence_received":
                    break

        reader = threading.Thread(target=relay)
        reader.start()
        try:
            for raw in client:
                frame = json.loads(raw)
                if frame["type"] == "attempt_started" and mode == "finished_start":
                    invalid = json.loads(raw)
                    invalid["training_attempt"]["latency_ms"] = 1
                    invalid["training_attempt"]["response"] = (
                        "PRIVATE_FORGED_START_SENTINEL"
                    )
                    backend.send(json.dumps(invalid))
                    injected.append(mode)
                backend.send(raw)
                if frame["type"] == "attempt_started" and mode == "request_rewrite":
                    invalid = json.loads(raw)
                    invalid["training_attempt"]["request"]["temperature"] = 0.5
                    invalid["training_attempt"]["decoder"]["temperature"] = 0.5
                    backend.send(json.dumps(invalid))
                    injected.append(mode)
                if frame["type"] == "action" and mode == "finished_bytes_rewrite":
                    invalid = {
                        "type": "attempt_started",
                        "decision_id": frame["decision_id"],
                        "training_attempt": frame["training_attempt"],
                    }
                    body = base64.b64decode(
                        invalid["training_attempt"]["response_body_b64"]
                    )
                    changed = body + b" "
                    invalid["training_attempt"]["response_body_b64"] = base64.b64encode(
                        changed
                    ).decode()
                    invalid["training_attempt"]["raw_response"] = changed.decode()
                    backend.send(json.dumps(invalid))
                    injected.append(mode)
                if frame["type"] == "stopped":
                    reader.join(timeout=5)
                    assert not reader.is_alive()
                    break
        finally:
            backend.close()
            reader.join()


proxy = serve(proxy_handler, "127.0.0.1", 0, max_size=16 * 1024 * 1024)
proxy_port = proxy.socket.getsockname()[1]
proxy_thread = threading.Thread(target=proxy.serve_forever)
env = os.environ.copy()
env.update(
    COGAME_CONFIG_URI=(root / "config.json").as_uri(),
    COGAME_HOST="127.0.0.1",
    COGAME_PORT=str(port),
    COGAME_SAVE_TRAJECTORY_URI=(root / "trajectory.jsonl").as_uri(),
    COGAME_RESULTS_URI=(root / "results.json").as_uri(),
    COGAME_SAVE_REPLAY_URI=(root / "replay.json").as_uri(),
    COWORLD_EPISODE_ID="fixture-whole",
    COWORLD_GAME_VERSION="fixture-diagnostic",
    COWORLD_SOURCE_REVISION="a" * 40,
)
players = []
with (root / "server.log").open("w") as server_log:
    server = subprocess.Popen(
        [str(server_binary)], env=env, stdout=server_log, stderr=subprocess.STDOUT
    )
    try:
        thread.start()
        proxy_thread.start()
        end = time.monotonic() + 5
        while time.monotonic() < end:
            probe = socket.socket()
            result = probe.connect_ex(("127.0.0.1", port))
            probe.close()
            if result == 0:
                break
            assert server.poll() is None
            time.sleep(0.02)
        assert result == 0
        for seat in range(4):
            pe = env.copy()
            pe.update(
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{proxy_port}/?slot={seat}&token=token-{seat}",
                COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{http.server_port}",
                COWORLD_LLM_MODEL="fixture/native",
                COWORLD_LLM_TEMPERATURE="1",
                PLAYER_PROMPT="Private fixture policy.",
                PLAYER_POLICY_LABEL="fixture-native",
                COWORLD_TIMEOUT_SECONDS="35",
            )
            log = (root / f"player-{seat}.log").open("w")
            players.append(
                (
                    subprocess.Popen(
                        [str(player_binary)],
                        env=pe,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    ),
                    log,
                )
            )
        for player, log in players:
            assert player.wait(timeout=35) == 0
            log.close()
        assert server.wait(timeout=30) == 0
    finally:
        for player, log in players:
            if player.poll() is None:
                player.terminate()
            player.wait(timeout=5)
            log.close()
        if server.poll() is None:
            server.terminate()
        server.wait(timeout=10)
        proxy.shutdown()
        proxy_thread.join()
        http.shutdown()
        thread.join()
        http.server_close()
(root / "requests.json").write_text(json.dumps(requests))
events = [
    json.loads(line) for line in (root / "trajectory.jsonl").read_text().splitlines()
]
decisions = [e for e in events if e["event_type"] == "decision"]
assert len(decisions) == 4 and len(requests) == 4
for decision in decisions:
    assert decision["action_status"] == "accepted", decision["action_status"]
    attempt = decision["attempts"][0]
    assert attempt["accepted"] and attempt["response_reader_joined"] is True
    assert len(attempt["prompt_token_ids"]) == 32768
    assert attempt["parsed_action"] == decision["executed_action"]
    assert attempt["request"]["system"] == attempt["prompt"][0]["content"]
assert events[-1]["status"] == "completed"
assert all(v == "joined" for v in events[-1]["outcome"]["player_cleanup"].values())
assert (root / "results.json").exists() and (root / "replay.json").exists()
assert len(injected) == 4
assert "PRIVATE_FORGED_START_SENTINEL" not in (root / "server.log").read_text()
assert (root / "server.log").read_text().count("ignoring bad private player frame") == 4
print(
    f"PASS {mode}:four malicious private frames rejected without altering4 genuine accepted native decisions,all4 readers joined; zero receipt authority"
)
