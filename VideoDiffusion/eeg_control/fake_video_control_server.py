#!/usr/bin/env python3
"""
Local MAGI-compatible control server for no-GPU EEG integration tests.

It implements the subset used by realtime_magi_stream.py:
- GET /stats
- POST /prompt {"prompt": "..."}
- GET /stream as a minimal MJPEG stream

Prompt changes are applied on the next fake chunk tick, matching MAGI's
chunk-boundary control model closely enough for local controller testing.
"""

from __future__ import annotations

import argparse
import json
import signal
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010101006000600000ffdb004300030202030202030303"
    "0304030304050805050404050a070706080c0a0c0c0b0a0b0b0d0e12100d0e110e"
    "0b0b1016101113141515150c0f171816141812141514ffdb00430103040405040509"
    "050509140d0b0d141414141414141414141414141414141414141414141414141414"
    "14141414141414141414141414141414141414141414141414141414ffc000110800"
    "01000103012200021101031101ffc400140001000000000000000000000000000000"
    "0000ffc4001410010000000000000000000000000000000000ffda000c03010002"
    "110311003f00d2cf20ffd9"
)


class FakeVideoState:
    def __init__(self, initial_prompt: str, chunk_seconds: float):
        self.initial_prompt = initial_prompt
        self.chunk_seconds = chunk_seconds
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.chunk_idx = -1
        self.last_prompt: str | None = None
        self.pending_prompt: str | None = initial_prompt
        self.last_applied_at: float | None = None
        self.last_error: str | None = None

    def run_clock(self) -> None:
        while not self.stop_event.wait(self.chunk_seconds):
            with self.lock:
                self.chunk_idx += 1
                if self.pending_prompt is not None:
                    self.last_prompt = self.pending_prompt
                    self.pending_prompt = None
                    self.last_applied_at = time.time()

    def set_prompt(self, prompt: str) -> dict:
        with self.lock:
            self.pending_prompt = prompt
            return {
                "status": "ok",
                "prompt": prompt,
                "pending_prompt": prompt,
                "dropped_frames": 0,
            }

    def stats(self) -> dict:
        with self.lock:
            fps = 24.0 / self.chunk_seconds if self.chunk_seconds > 0 else None
            return {
                "chunk_idx": self.chunk_idx,
                "last_gen_time_s": self.chunk_seconds,
                "last_chunk_fps": fps,
                "last_prompt": self.last_prompt,
                "pending_prompt": self.pending_prompt,
                "last_applied_at": self.last_applied_at,
                "last_error": self.last_error,
                "queue_size": 0,
                "queue_max": 0,
            }


def make_server(host: str, port: int, state: FakeVideoState, *, quiet: bool = False) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        server_version = "FakeVideoControl/1.0"

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
            if path == "/stats":
                self._send_json(HTTPStatus.OK, state.stats())
                return
            if path == "/stream":
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
                self.end_headers()
                while not state.stop_event.is_set():
                    try:
                        self.wfile.write(b"--frame\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n\r\n")
                        self.wfile.write(TINY_JPEG)
                        self.wfile.write(b"\r\n")
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        break
                    time.sleep(1.0 / 24.0)
                return
            if path == "/":
                body = (
                    "<!doctype html><title>Fake Video Control</title>"
                    "<h1>Fake Video Control</h1>"
                    "<img src='/stream' alt='fake stream'>"
                ).encode("utf-8")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_POST(self) -> None:
            path = urlparse(self.path).path
            if path != "/prompt":
                self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            try:
                content_length = int(self.headers.get("Content-Length") or "0")
                raw = self.rfile.read(content_length)
                payload = json.loads(raw.decode("utf-8")) if raw else {}
                prompt = str(payload.get("prompt") or "").strip()
                if not prompt:
                    self._send_json(HTTPStatus.BAD_REQUEST, {"error": "prompt missing"})
                    return
                self._send_json(HTTPStatus.OK, state.set_prompt(prompt))
            except Exception as exc:
                state.last_error = str(exc)
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})

    return ThreadingHTTPServer((host, port), Handler)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run a local fake MAGI-compatible video-control server.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--chunk-seconds", type=float, default=1.0)
    parser.add_argument("--initial-prompt", default="neutral local test pattern")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    state = FakeVideoState(args.initial_prompt, args.chunk_seconds)
    server = make_server(args.host, args.port, state, quiet=args.quiet)
    clock = threading.Thread(target=state.run_clock, name="fake-video-clock", daemon=True)
    clock.start()

    def stop(_signum=None, _frame=None) -> None:
        state.stop_event.set()
        threading.Thread(target=server.shutdown, name="fake-video-shutdown", daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(f"[fake-video] listening on http://{args.host}:{args.port}")
    print("[fake-video] endpoints: GET /stats, POST /prompt, GET /stream")
    try:
        server.serve_forever()
    finally:
        state.stop_event.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
