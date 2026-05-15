#!/usr/bin/env python3
"""State gating and prompt mapping for EEG video control."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .features import FeatureSnapshot, classify_features, merge_thresholds


@dataclass
class PromptDecision:
    state: str
    prompt: str | None
    reason: str
    should_send: bool
    candidate_count: int


def load_json_file(path: str | Path) -> dict[str, Any]:
    with Path(path).expanduser().open("r", encoding="utf-8") as f:
        return json.load(f)


class PromptController:
    def __init__(
        self,
        prompt_map: Mapping[str, Any],
        *,
        calibration: Mapping[str, Any] | None = None,
        cooldown_s: float | None = None,
        consecutive_windows: int | None = None,
    ):
        self.prompt_map = dict(prompt_map)
        self.states = dict(self.prompt_map.get("states") or {})
        if not self.states:
            raise ValueError("prompt map must define at least one state")

        controller_cfg = dict(self.prompt_map.get("controller") or {})
        self.cooldown_s = float(
            cooldown_s if cooldown_s is not None else controller_cfg.get("cooldown_s", 3.0)
        )
        self.consecutive_windows = int(
            consecutive_windows
            if consecutive_windows is not None
            else controller_cfg.get("consecutive_windows", 2)
        )
        if self.consecutive_windows < 1:
            raise ValueError("consecutive_windows must be >= 1")

        calibration_thresholds = {}
        if calibration:
            calibration_thresholds = dict(calibration.get("thresholds") or {})
        self.thresholds = merge_thresholds(self.prompt_map.get("thresholds"), calibration_thresholds)

        self._candidate_state: str | None = None
        self._candidate_count = 0
        self._last_sent_state: str | None = None
        self._last_sent_at = 0.0

    def update(self, snapshot: FeatureSnapshot, now: float | None = None) -> PromptDecision:
        now = time.monotonic() if now is None else now
        classification = classify_features(snapshot, self.thresholds)
        state = classification.state

        if state != self._candidate_state:
            self._candidate_state = state
            self._candidate_count = 1
        else:
            self._candidate_count += 1

        state_cfg = dict(self.states.get(state) or {})
        prompt = state_cfg.get("prompt")
        momentary = bool(state_cfg.get("momentary", False))

        if state == "hold" or not prompt:
            return PromptDecision(
                state=state,
                prompt=None,
                reason=classification.reason,
                should_send=False,
                candidate_count=self._candidate_count,
            )

        stable = self._candidate_count >= self.consecutive_windows
        cooled_down = (now - self._last_sent_at) >= self.cooldown_s
        changed = state != self._last_sent_state
        should_send = stable and cooled_down and (changed or momentary)

        if should_send:
            self._last_sent_state = state
            self._last_sent_at = now

        return PromptDecision(
            state=state,
            prompt=str(prompt),
            reason=classification.reason,
            should_send=should_send,
            candidate_count=self._candidate_count,
        )
