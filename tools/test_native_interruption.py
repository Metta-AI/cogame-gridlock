"""Actual native reference players, HTTP fixture, and authoritative whole engine. Zero receipt authority."""

import http.server
import json
import os
import socket
import signal
import base64
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

mode = sys.argv[4]
assert mode in ("term", "int")
root = Path(sys.argv[1]).resolve()
server_binary, player_binary = (Path(value).resolve() for value in sys.argv[2:4])
root.mkdir(mode=0o700)
requests = []
responded = []
release = threading.Event()


class Messages(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["content-length"]))
        request = json.loads(body)
        seat = int(self.headers["X-Coworld-Player-Slot"])
        requests.append((seat, request))
        raw = b"\xffPRIVATE_PARTIAL_NATIVE_SENTINEL"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw) + 200))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()
        responded.append(seat)
        release.wait(8)

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
                COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=token-{seat}",
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
        entered_deadline = time.monotonic() + 8
        while len(responded) < 4 and time.monotonic() < entered_deadline:
            time.sleep(0.02)
        assert len(responded) == 4
        interrupted_at = time.monotonic()
        server.send_signal(signal.SIGTERM if mode == "term" else signal.SIGINT)
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
        release.set()
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
    assert decision["action_status"] == "missing"
    assert (
        decision["executed_action"] is None and decision["selected_attempt_id"] is None
    )
    attempt = decision["attempts"][0]
    assert not attempt["accepted"] and attempt["response_reader_joined"] is True
    assert attempt["response_complete"] is False
    assert (
        base64.b64decode(attempt["response_body_b64"])
        == b"\xffPRIVATE_PARTIAL_NATIVE_SENTINEL"
    )
    assert attempt["http_status"] == 200 and attempt["raw_response"] is None
assert events[-1]["status"] == "truncated"
assert all(v == "joined" for v in events[-1]["outcome"]["player_cleanup"].values())
assert events[-1]["participant_outcomes"] is None
assert not (root / "results.json").exists() and not (root / "replay.json").exists()
for path in root.glob("*.log"):
    assert "PRIVATE_PARTIAL_NATIVE_SENTINEL" not in path.read_text()
print(
    f"PASS {mode}:4 genuine started partial native calls retained,4 readers joined,private Truncated,no public artifacts/targets; total {time.monotonic() - interrupted_at:.3f}s"
)
