#!/usr/bin/env python3
"""Continuous neurofeedback state estimation from EEG feature windows."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Mapping

from .features import FeatureSnapshot


DEFAULT_STATE_THRESHOLDS: dict[str, float] = {
    "low_arousal_alpha_beta_min": 1.35,
    "high_arousal_beta_alpha_min": 1.25,
    "high_arousal_engagement_min": 0.90,
    "transition_peak_to_peak_uv_min": 125.0,
    "transition_rms_uv_min": 55.0,
    "noisy_gamma_ratio_min": 2.5,
    "noisy_peak_to_peak_uv_min": 350.0,
}


@dataclass
class NeuroState:
    state: str
    arousal: float
    relaxation: float
    alpha_beta_ratio: float
    beta_alpha_ratio: float
    engagement_ratio: float
    artifact_ratio: float
    peak_to_peak_uv: float
    intensity: float
    confidence: float
    reason: str

    def to_jsonable(self) -> dict[str, float | str]:
        return asdict(self)


def _merge_state_thresholds(*items: Mapping[str, float] | None) -> dict[str, float]:
    merged = dict(DEFAULT_STATE_THRESHOLDS)
    for item in items:
        if not item:
            continue
        for key, value in item.items():
            if key in merged:
                merged[key] = float(value)
    return merged


def _clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


class NeuroStateEstimator:
    """Convert EEG band features into a small control vocabulary."""

    def __init__(self, thresholds: Mapping[str, float] | None = None):
        self.thresholds = _merge_state_thresholds(thresholds)

    def estimate(self, features: FeatureSnapshot) -> NeuroState:
        t = self.thresholds
        arousal = features.beta_alpha_ratio
        relaxation = features.alpha_beta_ratio
        gamma_ratio = features.gamma_low / max(features.alpha + features.beta + features.theta, 1e-9)
        noise_load = max(
            gamma_ratio / max(t["noisy_gamma_ratio_min"], 1e-9),
            features.peak_to_peak_uv / max(t["noisy_peak_to_peak_uv_min"], 1e-9),
        )
        confidence = _clamp01(1.0 - (0.65 * noise_load))

        if (
            gamma_ratio >= t["noisy_gamma_ratio_min"]
            or features.peak_to_peak_uv >= t["noisy_peak_to_peak_uv_min"]
        ):
            return NeuroState(
                state="noisy",
                arousal=arousal,
                relaxation=relaxation,
                alpha_beta_ratio=features.alpha_beta_ratio,
                beta_alpha_ratio=features.beta_alpha_ratio,
                engagement_ratio=features.engagement_ratio,
                artifact_ratio=features.artifact_ratio,
                peak_to_peak_uv=features.peak_to_peak_uv,
                intensity=0.0,
                confidence=confidence,
                reason=(
                    "signal quality low "
                    f"gamma_ratio={gamma_ratio:.2f} p2p={features.peak_to_peak_uv:.1f}uv"
                ),
            )

        if (
            features.peak_to_peak_uv >= t["transition_peak_to_peak_uv_min"]
            and features.rms_uv >= t["transition_rms_uv_min"]
        ):
            return NeuroState(
                state="transition",
                arousal=arousal,
                relaxation=relaxation,
                alpha_beta_ratio=features.alpha_beta_ratio,
                beta_alpha_ratio=features.beta_alpha_ratio,
                engagement_ratio=features.engagement_ratio,
                artifact_ratio=features.artifact_ratio,
                peak_to_peak_uv=features.peak_to_peak_uv,
                intensity=1.0,
                confidence=confidence,
                reason=f"large deliberate transient p2p={features.peak_to_peak_uv:.1f}uv",
            )

        if (
            features.beta_alpha_ratio >= t["high_arousal_beta_alpha_min"]
            or features.engagement_ratio >= t["high_arousal_engagement_min"]
        ):
            raw = max(
                features.beta_alpha_ratio / max(t["high_arousal_beta_alpha_min"], 1e-9),
                features.engagement_ratio / max(t["high_arousal_engagement_min"], 1e-9),
            )
            return NeuroState(
                state="high_arousal",
                arousal=arousal,
                relaxation=relaxation,
                alpha_beta_ratio=features.alpha_beta_ratio,
                beta_alpha_ratio=features.beta_alpha_ratio,
                engagement_ratio=features.engagement_ratio,
                artifact_ratio=features.artifact_ratio,
                peak_to_peak_uv=features.peak_to_peak_uv,
                intensity=_clamp01((raw - 1.0) / 2.0),
                confidence=confidence,
                reason=(
                    "beta/engagement dominant "
                    f"beta_alpha={features.beta_alpha_ratio:.2f} "
                    f"engagement={features.engagement_ratio:.2f}"
                ),
            )

        if features.alpha_beta_ratio >= t["low_arousal_alpha_beta_min"]:
            raw = features.alpha_beta_ratio / max(t["low_arousal_alpha_beta_min"], 1e-9)
            return NeuroState(
                state="low_arousal",
                arousal=arousal,
                relaxation=relaxation,
                alpha_beta_ratio=features.alpha_beta_ratio,
                beta_alpha_ratio=features.beta_alpha_ratio,
                engagement_ratio=features.engagement_ratio,
                artifact_ratio=features.artifact_ratio,
                peak_to_peak_uv=features.peak_to_peak_uv,
                intensity=_clamp01((raw - 1.0) / 2.0),
                confidence=confidence,
                reason=f"alpha dominant alpha_beta={features.alpha_beta_ratio:.2f}",
            )

        return NeuroState(
            state="balanced",
            arousal=arousal,
            relaxation=relaxation,
            alpha_beta_ratio=features.alpha_beta_ratio,
            beta_alpha_ratio=features.beta_alpha_ratio,
            engagement_ratio=features.engagement_ratio,
            artifact_ratio=features.artifact_ratio,
            peak_to_peak_uv=features.peak_to_peak_uv,
            intensity=0.2,
            confidence=confidence,
            reason=(
                "middle band state "
                f"alpha_beta={features.alpha_beta_ratio:.2f} beta_alpha={features.beta_alpha_ratio:.2f}"
            ),
        )
