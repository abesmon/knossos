#!/usr/bin/env python3
"""Runs the VRWeb Luau test scene against a real local HTTP redirect and SRI source."""

from __future__ import annotations

import http.server
import os
import pathlib
import socketserver
import subprocess
import tempfile
import threading


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = b'document.session.http = "ok"\n'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        if self.path == "/redirect.luau":
            self.send_response(302)
            self.send_header("Location", "/script.luau")
            self.end_headers()
            return
        if self.path == "/script.luau":
            self.send_response(200)
            self.send_header("Content-Type", "application/vrweb+luau")
            self.send_header("Content-Length", str(len(SOURCE)))
            self.end_headers()
            self.wfile.write(SOURCE)
            return
        self.send_error(404)

    def log_message(self, _format: str, *args: object) -> None:
        pass


def main() -> int:
    godot = os.environ.get("GODOT", "godot")
    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server, tempfile.TemporaryDirectory(
        prefix="vrweb-luau-http-home-"
    ) as home:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ.copy()
        env["HOME"] = home
        env["VRWEB_SCRIPT_TEST_BASE"] = f"http://127.0.0.1:{server.server_address[1]}"
        result = subprocess.run(
            [godot, "--headless", "--quiet", "--path", str(ROOT),
             "res://tests/test_vrweb_scripting.tscn"],
            cwd=ROOT,
            env=env,
            check=False,
        )
        server.shutdown()
        thread.join(timeout=2)
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
