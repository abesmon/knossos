#!/usr/bin/env python3
"""Поднимает signaling и два Godot-процесса для late join grabbable E2E."""

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
SCENE = "res://tests/net_grabbable_test.tscn"


def wait_port(port: int, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def start_client(godot: str, role: str, output, sandbox: str | None = None) -> subprocess.Popen:
    env = os.environ.copy()
    env["HOME"] = "/tmp/knossos-godot-grab-e2e"
    env["VRWEB_SANDBOX"] = sandbox or f"GRAB-{role}"
    return subprocess.Popen(
        [godot, "--headless", "--path", str(ROOT), SCENE, "--", role],
        cwd=ROOT,
        env=env,
        stdout=output,
        stderr=subprocess.STDOUT,
        text=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    args = parser.parse_args()

    if wait_port(8090, 0.2):
        print("порт 8090 уже занят; остановите другой signaling server", file=sys.stderr)
        return 2

    server_env = os.environ.copy()
    server_env["HOST"] = "127.0.0.1"
    server_env["PORT"] = "8090"
    server = subprocess.Popen(
        [sys.executable, str(ROOT / "signaling/server.py")],
        cwd=ROOT,
        env=server_env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    clients: list[tuple[str, subprocess.Popen, Path]] = []
    handles = []
    try:
        if not wait_port(8090):
            print("signaling server не запустился (проверьте dependency websockets)", file=sys.stderr)
            return 2

        temp_dir = Path(tempfile.mkdtemp(prefix="knossos-grab-e2e-"))
        # delay относительно предыдущего запуска: late входит до ухода leader.
        for role, delay in (("holder", 0.0), ("late", 4.0)):
            time.sleep(delay)
            path = temp_dir / f"{role}.log"
            handle = path.open("w", encoding="utf-8")
            handles.append(handle)
            clients.append((role, start_client(args.godot, role, handle), path))

        failed = False
        deadline = time.monotonic() + 40.0
        for role, process, _path in clients:
            remaining = max(0.1, deadline - time.monotonic())
            try:
                code = process.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                process.terminate()
                code = 124
            failed = failed or code != 0
            print(f"{role}: exit={code}")

        for handle in handles:
            handle.close()
        handles.clear()
        for role, _process, path in clients:
            print(f"\n--- {role} ---")
            lines = [line for line in path.read_text(encoding="utf-8").splitlines()
                     if "GRAB-E2E" in line or "SCRIPT ERROR" in line or "ERROR:" in line]
            print("\n".join(lines[-80:]))
        return 1 if failed else 0

    finally:
        for _role, process, _path in clients:
            if process.poll() is None:
                process.terminate()
        for handle in handles:
            handle.close()
        server.terminate()
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()


if __name__ == "__main__":
    raise SystemExit(main())
