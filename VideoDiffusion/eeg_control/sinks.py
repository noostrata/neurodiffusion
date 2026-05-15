#!/usr/bin/env python3
"""Output sinks for neurofeedback session records."""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Protocol

from .scope_client import ScopeOscClient, ScopePromptController
from .video_client import VideoControlClient


class Sink(Protocol):
    def handle(self, record: dict) -> None:
        ...

    def close(self) -> None:
        ...


class StdoutSink:
    def handle(self, record: dict) -> None:
        command = record["command"]
        neuro_state = record["neuro_state"]
        emit = "SEND" if record.get("emit") else "hold"
        print(
            f"[{record['seq']:05d}] {emit:5s} "
            f"policy={command['policy']} state={command['state']} "
            f"intensity={command['intensity']:.2f} confidence={neuro_state['confidence']:.2f} "
            f"| {command['reason']}"
        )

    def close(self) -> None:
        pass


class JsonlSink:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self.path.open("a", encoding="utf-8")

    def handle(self, record: dict) -> None:
        self._file.write(json.dumps(record, sort_keys=True) + "\n")
        self._file.flush()

    def close(self) -> None:
        self._file.close()


class PromptHttpSink:
    def __init__(self, base_url: str, timeout_s: float = 5.0):
        self.client = VideoControlClient(base_url, timeout_s=timeout_s)

    def handle(self, record: dict) -> None:
        if not record.get("emit"):
            return
        prompt = record["command"].get("prompt")
        if not prompt:
            return
        sent = self.client.set_prompt(prompt)
        record["http_sent"] = sent
        try:
            record["http_stats_after"] = self.client.get_stats()
        except Exception as exc:
            record["http_stats_error"] = str(exc)

    def close(self) -> None:
        pass


class ScopeOscSink:
    def __init__(
        self,
        host: str = "127.0.0.1",
        port: int = 8000,
        timeout_s: float = 1.0,
        transition_steps: int = 6,
        interpolation_method: str = "linear",
        send_noise_scale: bool = True,
        noise_min: float = 0.35,
        noise_max: float = 0.85,
        reset_cache_on_transition: bool = True,
        manage_cache: bool = True,
    ):
        osc = ScopeOscClient(host=host, port=port, timeout_s=timeout_s)
        self.controller = ScopePromptController(
            osc,
            transition_steps=transition_steps,
            interpolation_method=interpolation_method,
            send_noise_scale=send_noise_scale,
            noise_min=noise_min,
            noise_max=noise_max,
            reset_cache_on_transition=reset_cache_on_transition,
            manage_cache=manage_cache,
        )

    def handle(self, record: dict) -> None:
        if not record.get("emit"):
            return
        sent = self.controller.send_command(record["command"])
        record["scope_osc_sent"] = sent

    def close(self) -> None:
        pass


class ScheduleCsvSink:
    def __init__(self, path: str | Path, hold_chunks: int = 4):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.hold_chunks = int(hold_chunks)
        self._file = self.path.open("w", encoding="utf-8", newline="")
        self._writer = csv.DictWriter(
            self._file,
            fieldnames=("cue_id", "start_chunk", "end_chunk", "prompt"),
        )
        self._writer.writeheader()
        self._cue_idx = 0

    def handle(self, record: dict) -> None:
        if not record.get("emit"):
            return
        prompt = record["command"].get("prompt")
        if not prompt:
            return
        stats = record.get("http_stats_after") or record.get("stats") or {}
        chunk_idx = int(stats.get("chunk_idx", self._cue_idx * self.hold_chunks))
        self._writer.writerow(
            {
                "cue_id": f"eeg_{self._cue_idx:04d}_{record['command']['state']}",
                "start_chunk": max(0, chunk_idx + 1),
                "end_chunk": max(0, chunk_idx + self.hold_chunks),
                "prompt": prompt,
            }
        )
        self._file.flush()
        self._cue_idx += 1

    def close(self) -> None:
        self._file.close()


class CompositeSink:
    def __init__(self, sinks: list[Sink]):
        self.sinks = sinks

    def handle(self, record: dict) -> None:
        for sink in self.sinks:
            sink.handle(record)

    def close(self) -> None:
        for sink in reversed(self.sinks):
            sink.close()
