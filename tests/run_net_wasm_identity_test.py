#!/usr/bin/env python3
"""Run compatible and hash-mismatched WASM module identities over a real WebRTC mesh."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
SCENE = "res://tests/net_wasm_identity_test.tscn"


def wait_port(port: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--exported-binary")
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--scenarios", default="compatible,mismatch,navigation,navigation-race,authority")
    args = parser.parse_args()
    if wait_port(8090, 0.2):
        print("port 8090 is already occupied", file=sys.stderr)
        return 2
    server_env = os.environ.copy()
    server_env.update({"HOST": "127.0.0.1", "PORT": "8090"})
    server = subprocess.Popen(
        [sys.executable, str(ROOT / "signaling/server.py")], cwd=ROOT, env=server_env,
        stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    clients: list[subprocess.Popen] = []
    try:
        if not wait_port(8090):
            print("signaling server did not start", file=sys.stderr)
            return 2
        output_dir = Path(tempfile.mkdtemp(prefix="knossos-wasm-net-e2e-"))
        failed = False
        if args.rounds < 1:
            print("--rounds must be positive", file=sys.stderr)
            return 2
        scenarios = tuple(item.strip() for item in args.scenarios.split(",") if item.strip())
        allowed = {"compatible", "mismatch", "navigation", "navigation-race", "authority"}
        if not scenarios or any(item not in allowed for item in scenarios):
            print("--scenarios contains an unsupported scenario", file=sys.stderr)
            return 2
        for round_index in range(args.rounds):
            for scenario in scenarios:
                running = []
                handles = []
                for role, delay in (("leader", 0.0), ("follower", 0.8)):
                    time.sleep(delay)
                    path = output_dir / f"{round_index}-{scenario}-{role}.log"
                    handle = path.open("w", encoding="utf-8")
                    handles.append(handle)
                    env = os.environ.copy()
                    env["HOME"] = "/tmp/knossos-godot-wasm-net-e2e"
                    env["VRWEB_SANDBOX"] = f"WASM-NET-{scenario}-{role}"
                    command = ([args.exported_binary, "--headless", "--",
                                "--vrweb-wasm-net-test", scenario, role, str(round_index)]
                               if args.exported_binary else
                               [args.godot, "--headless", "--path", str(ROOT), SCENE, "--",
                                scenario, role, str(round_index)])
                    process = subprocess.Popen(
                        command,
                        cwd=ROOT, env=env, stdout=handle, stderr=subprocess.STDOUT, text=True)
                    clients.append(process)
                    running.append((role, process, path))
                for role, process, _path in running:
                    try:
                        code = process.wait(timeout=40)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        code = 124
                    failed = failed or code != 0
                    print(f"round={round_index} {scenario}/{role}: exit={code}")
                for handle in handles:
                    handle.close()
                for role, _process, path in running:
                    lines = [line for line in path.read_text(encoding="utf-8").splitlines()
                             if "WASM-NET-E2E" in line or "SCRIPT ERROR" in line or "ERROR:" in line]
                    print(f"--- round={round_index} {scenario}/{role} ---")
                    print("\n".join(lines[-40:]))
        return 1 if failed else 0
    finally:
        for process in clients:
            if process.poll() is None:
                process.terminate()
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()


if __name__ == "__main__":
    raise SystemExit(main())
