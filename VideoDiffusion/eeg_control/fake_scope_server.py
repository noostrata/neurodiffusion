#!/usr/bin/env python3
"""Local fake Daydream Scope API/OSC receiver for no-GPU tests."""

from __future__ import annotations

import argparse
import json
import signal
import socket
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from VideoDiffusion.eeg_control.scope_client import parse_osc_message
else:
    from .scope_client import parse_osc_message


class FakeScopeState:
    def __init__(self):
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.status = "not_loaded"
        self.pipeline_id: str | None = None
        self.load_params: dict = {}
        self.error: str | None = None
        self.osc_messages: list[dict] = []

    def load_pipeline(self, payload: dict) -> dict:
        pipeline_ids = payload.get("pipeline_ids") or []
        if not pipeline_ids:
            return {"error": "pipeline_ids missing"}
        with self.lock:
            self.status = "loaded"
            self.pipeline_id = str(pipeline_ids[-1])
            self.load_params = dict(payload.get("load_params") or {})
            self.error = None
        return {"status": self.status, "pipeline_id": self.pipeline_id, "load_params": self.load_params, "error": None}

    def pipeline_status(self) -> dict:
        with self.lock:
            return {
                "status": self.status,
                "pipeline_id": self.pipeline_id,
                "load_params": dict(self.load_params),
                "loaded_lora_adapters": [],
                "error": self.error,
            }

    def append_osc(self, address: str, values: list) -> None:
        with self.lock:
            self.osc_messages.append({"address": address, "values": values, "ts": time.time()})

    def osc_status(self) -> dict:
        with self.lock:
            return {"messages": list(self.osc_messages), "count": len(self.osc_messages)}


def make_http_server(host: str, port: int, state: FakeScopeState, *, quiet: bool = False) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        server_version = "FakeScope/1.0"

        def log_message(self, fmt: str, *args) -> None:
            if not quiet:
                super().log_message(fmt, *args)

        def _send_json(self, status: HTTPStatus, payload: dict) -> None:
            raw = json.dumps(payload, sort_keys=True).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path == "/api/v1/pipeline/status":
                self._send_json(HTTPStatus.OK, state.pipeline_status())
                return
            if path == "/api/v1/osc/messages":
                self._send_json(HTTPStatus.OK, state.osc_status())
                return
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_POST(self) -> None:
            path = urlparse(self.path).path
            if path != "/api/v1/pipeline/load":
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            raw = self.rfile.read(int(self.headers.get("Content-Length") or "0"))
            payload = json.loads(raw.decode("utf-8")) if raw else {}
            result = state.load_pipeline(payload)
            if result.get("error"):
                self._send_json(HTTPStatus.BAD_REQUEST, result)
            else:
                self._send_json(HTTPStatus.OK, result)

    return ThreadingHTTPServer((host, port), Handler)


def run_osc_server(host: str, port: int, state: FakeScopeState) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((host, port))
        sock.settimeout(0.1)
        while not state.stop_event.is_set():
            try:
                packet, _addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            try:
                address, values = parse_osc_message(packet)
                state.append_osc(address, values)
            except Exception as exc:
                state.append_osc("/error", [str(exc)])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run a fake Scope API/OSC server for local tests.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000, help="Default port for both HTTP and OSC")
    parser.add_argument("--http-port", type=int, help="HTTP API port; defaults to --port")
    parser.add_argument("--osc-port", type=int, help="OSC UDP port; defaults to --port")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    http_port = args.http_port if args.http_port is not None else args.port
    osc_port = args.osc_port if args.osc_port is not None else args.port
    state = FakeScopeState()
    http_server = make_http_server(args.host, http_port, state, quiet=args.quiet)
    osc_thread = threading.Thread(target=run_osc_server, args=(args.host, osc_port, state), daemon=True)
    osc_thread.start()

    def stop(_signum=None, _frame=None) -> None:
        state.stop_event.set()
        threading.Thread(target=http_server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"[fake-scope] HTTP listening on {args.host}:{http_port}; OSC listening on {args.host}:{osc_port}")
    try:
        http_server.serve_forever()
    finally:
        state.stop_event.set()
        http_server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
