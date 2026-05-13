#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DEFAULT_LISTEN_HOST = "0.0.0.0"
DEFAULT_TARGET_URL = "http://127.0.0.1:19514/health"
RUNNING_BODY = b'{"status":"running"}\n'
UNAVAILABLE_BODY = b'{"status":"unavailable"}\n'
NOT_FOUND_BODY = b'{"status":"not_found"}\n'


def health_status_from_target(target_url: str, timeout_seconds: float) -> tuple[int, bytes]:
    request = urllib.request.Request(target_url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return 503, UNAVAILABLE_BODY

    if isinstance(payload, dict) and payload.get("status") == "running":
        return 200, RUNNING_BODY

    return 503, UNAVAILABLE_BODY


class HealthProxyHandler(BaseHTTPRequestHandler):
    target_url: str = DEFAULT_TARGET_URL
    timeout_seconds: float = 2.0

    def do_GET(self) -> None:
        if self.path != "/health":
            self._send_json_response(404, NOT_FOUND_BODY)
            return

        status_code, body = health_status_from_target(
            self.target_url,
            self.timeout_seconds,
        )
        self._send_json_response(status_code, body)

    def log_message(self, format: str, *args: object) -> None:
        return

    def _send_json_response(self, status_code: int, body: bytes) -> None:
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="HTTP health proxy")
    parser.add_argument("--listen-host", default=DEFAULT_LISTEN_HOST)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--target-url", default=DEFAULT_TARGET_URL)
    parser.add_argument("--timeout-seconds", default=2.0, type=float)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    HealthProxyHandler.target_url = args.target_url
    HealthProxyHandler.timeout_seconds = args.timeout_seconds

    server = ThreadingHTTPServer((args.listen_host, args.port), HealthProxyHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 130
    finally:
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
