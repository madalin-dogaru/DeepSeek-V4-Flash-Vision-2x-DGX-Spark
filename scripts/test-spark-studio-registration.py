#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).with_name("register-spark-studio.sh")


class FakeStudioHandler(BaseHTTPRequestHandler):
    registrations: list[dict[str, str]] = []

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_json(self, status: int, payload: object) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/v1/models":
            self.send_json(200, {"data": [{"id": "deepseek-v4-flash-vision-exp"}]})
            return
        if self.path == "/api/runs":
            runs = [
                {
                    "id": "external123",
                    "engine": item["engine"],
                    "label": item["name"],
                    "url": item["url"],
                    "status": "running",
                }
                for item in self.registrations
            ]
            self.send_json(200, runs)
            return
        self.send_json(404, {"detail": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/external":
            self.send_json(404, {"detail": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(length))
        self.registrations.append(payload)
        self.send_json(
            200,
            {
                "id": "external123",
                "engine": payload["engine"],
                "label": payload["name"],
                "url": payload["url"],
                "status": "running",
            },
        )


class SparkStudioRegistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeStudioHandler.registrations = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeStudioHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address
        self.url = f"http://{host}:{port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def run_helper(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(SCRIPT),
                "--studio-url",
                self.url,
                "--endpoint-url",
                f"{self.url}/v1",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_registers_once_and_normalizes_v1_suffix(self) -> None:
        first = self.run_helper()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("Registered with Spark Studio", first.stdout)
        self.assertEqual(
            FakeStudioHandler.registrations,
            [
                {
                    "engine": "vllm",
                    "name": "deepseek-v4-flash-vision-exp",
                    "url": self.url,
                }
            ],
        )

        second = self.run_helper()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("Already registered", second.stdout)
        self.assertEqual(len(FakeStudioHandler.registrations), 1)


if __name__ == "__main__":
    unittest.main()
