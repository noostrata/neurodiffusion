#!/usr/bin/env python3
"""Tiny stdlib HTTP client for MAGI-compatible video-control endpoints."""

from __future__ import annotations

import json
import urllib.error
import urllib.request


class VideoControlError(RuntimeError):
    pass


class VideoControlClient:
    def __init__(self, base_url: str, timeout_s: float = 5.0):
        self.base_url = base_url.rstrip("/")
        self.timeout_s = timeout_s

    def _json(self, method: str, path: str, payload: dict | None = None) -> dict:
        body = None
        headers = {}
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            url=self.base_url + path,
            data=body,
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout_s) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as exc:
            err = exc.read().decode("utf-8", errors="replace")
            raise VideoControlError(f"HTTP {exc.code} {method} {path}: {err}") from exc
        except urllib.error.URLError as exc:
            raise VideoControlError(f"Request failed {method} {path}: {exc}") from exc

        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise VideoControlError(f"Non-JSON response from {path}: {raw[:200]}") from exc

    def get_stats(self) -> dict:
        return self._json("GET", "/stats")

    def set_prompt(self, prompt: str) -> dict:
        return self._json("POST", "/prompt", {"prompt": prompt})
