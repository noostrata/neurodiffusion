#!/usr/bin/env python3
"""Daydream Scope REST and OSC clients with no third-party dependencies."""

from __future__ import annotations

import json
import socket
import struct
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


class ScopeControlError(RuntimeError):
    pass


def _json_request(method: str, url: str, payload: dict | None, timeout_s: float) -> dict:
    body = None
    headers = {}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url=url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        raise ScopeControlError(f"HTTP {exc.code} {method} {url}: {err}") from exc
    except urllib.error.URLError as exc:
        raise ScopeControlError(f"Request failed {method} {url}: {exc}") from exc

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ScopeControlError(f"Non-JSON response from {url}: {raw[:200]}") from exc


class ScopeApiClient:
    """Small client for Scope's documented `/api/v1/pipeline/*` endpoints."""

    def __init__(self, base_url: str = "http://127.0.0.1:8000", timeout_s: float = 5.0):
        self.base_url = base_url.rstrip("/")
        self.timeout_s = timeout_s

    def load_pipeline(self, pipeline_ids: list[str], load_params: dict | None = None) -> dict:
        payload: dict[str, Any] = {"pipeline_ids": pipeline_ids}
        if load_params:
            payload["load_params"] = load_params
        return _json_request("POST", f"{self.base_url}/api/v1/pipeline/load", payload, self.timeout_s)

    def get_pipeline_status(self) -> dict:
        return _json_request("GET", f"{self.base_url}/api/v1/pipeline/status", None, self.timeout_s)

    def wait_for_pipeline_loaded(self, *, timeout_s: float = 300.0, poll_s: float = 1.0) -> dict:
        deadline = time.monotonic() + timeout_s
        last_status: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            status = self.get_pipeline_status()
            last_status = status
            state = str(status.get("status") or "")
            if state == "loaded":
                return status
            if state == "error":
                raise ScopeControlError(f"Scope pipeline load failed: {status.get('error')}")
            time.sleep(poll_s)
        raise ScopeControlError(f"Timed out waiting for Scope pipeline load; last_status={last_status}")


def endpoint_from_base_url(base_url: str, default_port: int = 8000) -> tuple[str, int]:
    parsed = urllib.parse.urlparse(base_url)
    if not parsed.hostname:
        raise ValueError(f"Could not parse host from Scope URL: {base_url!r}")
    return parsed.hostname, parsed.port or default_port


def _osc_pad(raw: bytes) -> bytes:
    return raw + (b"\x00" * ((4 - (len(raw) % 4)) % 4))


def _osc_string(value: str) -> bytes:
    return _osc_pad(value.encode("utf-8") + b"\x00")


def build_osc_message(address: str, *values: str | int | float | bool) -> bytes:
    if not address.startswith("/"):
        raise ValueError(f"OSC address must start with '/', got {address!r}")
    tags = ","
    payload = bytearray()
    for value in values:
        if isinstance(value, bool):
            tags += "T" if value else "F"
        elif isinstance(value, int):
            tags += "i"
            payload.extend(struct.pack(">i", value))
        elif isinstance(value, float):
            tags += "f"
            payload.extend(struct.pack(">f", value))
        else:
            tags += "s"
            payload.extend(_osc_string(str(value)))
    return _osc_string(address) + _osc_string(tags) + bytes(payload)


def _read_osc_string(packet: bytes, offset: int) -> tuple[str, int]:
    end = packet.index(b"\x00", offset)
    value = packet[offset:end].decode("utf-8", errors="replace")
    offset = end + 1
    while offset % 4:
        offset += 1
    return value, offset


def parse_osc_message(packet: bytes) -> tuple[str, list[str | int | float | bool]]:
    address, offset = _read_osc_string(packet, 0)
    tags, offset = _read_osc_string(packet, offset)
    if not tags.startswith(","):
        raise ValueError(f"invalid OSC type tag string: {tags!r}")
    values: list[str | int | float | bool] = []
    for tag in tags[1:]:
        if tag == "i":
            values.append(struct.unpack(">i", packet[offset : offset + 4])[0])
            offset += 4
        elif tag == "f":
            values.append(struct.unpack(">f", packet[offset : offset + 4])[0])
            offset += 4
        elif tag == "s":
            value, offset = _read_osc_string(packet, offset)
            values.append(value)
        elif tag == "T":
            values.append(True)
        elif tag == "F":
            values.append(False)
        else:
            raise ValueError(f"unsupported OSC type tag {tag!r}")
    return address, values


@dataclass
class ScopeOscClient:
    host: str = "127.0.0.1"
    port: int = 8000
    timeout_s: float = 1.0

    def send(self, address: str, *values: str | int | float | bool) -> dict:
        packet = build_osc_message(address, *values)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(self.timeout_s)
            sent = sock.sendto(packet, (self.host, self.port))
        return {"address": address, "values": list(values), "bytes": sent, "host": self.host, "port": self.port}


class ScopePromptController:
    """Translate art commands into Scope OSC parameter updates."""

    def __init__(
        self,
        osc: ScopeOscClient,
        *,
        transition_steps: int = 6,
        interpolation_method: str = "linear",
        send_noise_scale: bool = True,
        noise_min: float = 0.35,
        noise_max: float = 0.85,
        reset_cache_on_transition: bool = True,
        manage_cache: bool = True,
    ):
        self.osc = osc
        self.transition_steps = max(0, int(transition_steps))
        self.interpolation_method = interpolation_method
        self.send_noise_scale = send_noise_scale
        self.noise_min = float(noise_min)
        self.noise_max = float(noise_max)
        self.reset_cache_on_transition = reset_cache_on_transition
        self.manage_cache = manage_cache
        self._sent_cache_policy = False

    def _noise_for_command(self, command: dict) -> float:
        intensity = max(0.0, min(1.0, float(command.get("intensity") or 0.0)))
        motion = str(command.get("motion") or "")
        high_motion = motion in {"frantic", "fast", "contradictory", "cut"}
        if high_motion:
            return self.noise_min + ((self.noise_max - self.noise_min) * max(0.45, intensity))
        return self.noise_min + ((self.noise_max - self.noise_min) * min(0.35, intensity))

    def send_command(self, command: dict) -> list[dict]:
        prompt = str(command.get("prompt") or "").strip()
        if not prompt:
            return []

        sent: list[dict] = []
        if self.manage_cache and not self._sent_cache_policy:
            sent.append(self.osc.send("/scope/manage_cache", True))
            self._sent_cache_policy = True
        if self.send_noise_scale:
            sent.append(self.osc.send("/scope/noise_scale", self._noise_for_command(command)))
        if self.transition_steps > 0:
            sent.append(self.osc.send("/scope/transition_steps", self.transition_steps))
            sent.append(self.osc.send("/scope/interpolation_method", self.interpolation_method))
        if self.reset_cache_on_transition and command.get("state") == "transition":
            sent.append(self.osc.send("/scope/reset_cache", True))
        sent.append(self.osc.send("/scope/prompt", prompt))
        return sent
