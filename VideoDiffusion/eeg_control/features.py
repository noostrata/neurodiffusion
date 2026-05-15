#!/usr/bin/env python3
"""
Small EEG feature extraction helpers for prompt-level video steering.

Inputs are expected in BrainFlow's usual units: microvolts, shaped as
channels x samples. The features are intentionally simple and explainable
because the first control target is stable state changes, not medical-grade
classification.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Mapping

import numpy as np


EPS = 1e-9

BANDS_HZ: dict[str, tuple[float, float]] = {
    "delta": (1.0, 4.0),
    "theta": (4.0, 8.0),
    "alpha": (8.0, 13.0),
    "beta": (13.0, 30.0),
    "gamma_low": (30.0, 45.0),
}


def _integrate(y: np.ndarray, x: np.ndarray) -> float:
    if hasattr(np, "trapezoid"):
        return float(np.trapezoid(y, x))
    if len(y) < 2:
        return 0.0
    dx = np.diff(x)
    return float(np.sum(0.5 * (y[:-1] + y[1:]) * dx))


@dataclass
class FeatureSnapshot:
    sampling_rate: float
    sample_count: int
    channel_count: int
    rms_uv: float
    peak_to_peak_uv: float
    delta: float
    theta: float
    alpha: float
    beta: float
    gamma_low: float
    alpha_beta_ratio: float
    beta_alpha_ratio: float
    engagement_ratio: float
    artifact_ratio: float

    def to_jsonable(self) -> dict[str, float | int]:
        return asdict(self)


def _validate_eeg(eeg_uv: np.ndarray, sampling_rate: float) -> np.ndarray:
    if sampling_rate <= 0:
        raise ValueError("sampling_rate must be positive")
    arr = np.asarray(eeg_uv, dtype=float)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)
    if arr.ndim != 2:
        raise ValueError("eeg_uv must be shaped channels x samples")
    if arr.shape[1] < 8:
        raise ValueError("at least 8 samples are required")
    return arr


def compute_features(eeg_uv: np.ndarray, sampling_rate: float) -> FeatureSnapshot:
    """Compute averaged band-power ratios and simple artifact features."""
    arr = _validate_eeg(eeg_uv, sampling_rate)
    channel_count, sample_count = arr.shape

    centered = arr - np.mean(arr, axis=1, keepdims=True)
    rms_uv = float(np.sqrt(np.mean(centered * centered)))
    peak_to_peak_uv = float(np.percentile(centered, 99.0) - np.percentile(centered, 1.0))

    window = np.hanning(sample_count)
    if not np.any(window):
        window = np.ones(sample_count)
    window_power = float(np.sum(window * window))
    freqs = np.fft.rfftfreq(sample_count, d=1.0 / float(sampling_rate))
    fft = np.fft.rfft(centered * window[None, :], axis=1)
    psd = (np.abs(fft) ** 2) / max(window_power * float(sampling_rate), EPS)

    band_values: dict[str, float] = {}
    for name, (lo_hz, hi_hz) in BANDS_HZ.items():
        mask = (freqs >= lo_hz) & (freqs < hi_hz)
        if not np.any(mask):
            band_values[name] = 0.0
            continue
        # Average channels first, then integrate over the frequency band.
        avg_psd = np.mean(psd[:, mask], axis=0)
        band_values[name] = _integrate(avg_psd, freqs[mask])

    alpha = band_values["alpha"]
    beta = band_values["beta"]
    theta = band_values["theta"]
    gamma_low = band_values["gamma_low"]

    return FeatureSnapshot(
        sampling_rate=float(sampling_rate),
        sample_count=int(sample_count),
        channel_count=int(channel_count),
        rms_uv=rms_uv,
        peak_to_peak_uv=peak_to_peak_uv,
        delta=band_values["delta"],
        theta=theta,
        alpha=alpha,
        beta=beta,
        gamma_low=gamma_low,
        alpha_beta_ratio=float(alpha / (beta + EPS)),
        beta_alpha_ratio=float(beta / (alpha + EPS)),
        engagement_ratio=float(beta / (alpha + theta + EPS)),
        artifact_ratio=float((gamma_low + beta) / (alpha + theta + EPS)),
    )


@dataclass
class Classification:
    state: str
    reason: str


DEFAULT_THRESHOLDS: dict[str, float] = {
    "calm_alpha_beta_min": 1.35,
    "active_beta_alpha_min": 1.25,
    "active_engagement_min": 0.90,
    "switch_peak_to_peak_uv_min": 125.0,
    "switch_rms_uv_min": 55.0,
    "artifact_ratio_max_for_calm": 2.75,
}


def merge_thresholds(*items: Mapping[str, float] | None) -> dict[str, float]:
    merged = dict(DEFAULT_THRESHOLDS)
    for item in items:
        if not item:
            continue
        for key, value in item.items():
            if key in merged:
                merged[key] = float(value)
    return merged


def classify_features(
    snapshot: FeatureSnapshot,
    thresholds: Mapping[str, float] | None = None,
) -> Classification:
    """Map a feature window to one coarse control state."""
    t = merge_thresholds(thresholds)

    if (
        snapshot.peak_to_peak_uv >= t["switch_peak_to_peak_uv_min"]
        and snapshot.rms_uv >= t["switch_rms_uv_min"]
    ):
        return Classification(
            state="switch_scene",
            reason=(
                "large transient "
                f"p2p={snapshot.peak_to_peak_uv:.1f}uv rms={snapshot.rms_uv:.1f}uv"
            ),
        )

    if (
        snapshot.beta_alpha_ratio >= t["active_beta_alpha_min"]
        or snapshot.engagement_ratio >= t["active_engagement_min"]
    ):
        return Classification(
            state="active",
            reason=(
                "beta/engagement high "
                f"beta_alpha={snapshot.beta_alpha_ratio:.2f} "
                f"engagement={snapshot.engagement_ratio:.2f}"
            ),
        )

    if (
        snapshot.alpha_beta_ratio >= t["calm_alpha_beta_min"]
        and snapshot.artifact_ratio <= t["artifact_ratio_max_for_calm"]
    ):
        return Classification(
            state="calm",
            reason=(
                "alpha/beta high "
                f"alpha_beta={snapshot.alpha_beta_ratio:.2f} "
                f"artifact={snapshot.artifact_ratio:.2f}"
            ),
        )

    return Classification(
        state="hold",
        reason=(
            "no stable threshold "
            f"alpha_beta={snapshot.alpha_beta_ratio:.2f} "
            f"beta_alpha={snapshot.beta_alpha_ratio:.2f}"
        ),
    )


class ExponentialFeatureSmoother:
    """Simple per-feature EMA for reducing prompt thrash."""

    def __init__(self, alpha: float):
        if not 0.0 < alpha <= 1.0:
            raise ValueError("alpha must be in (0, 1]")
        self.alpha = alpha
        self._current: FeatureSnapshot | None = None

    def update(self, snapshot: FeatureSnapshot) -> FeatureSnapshot:
        if self._current is None:
            self._current = snapshot
            return snapshot

        prev = self._current
        a = self.alpha
        smoothed = FeatureSnapshot(
            sampling_rate=snapshot.sampling_rate,
            sample_count=snapshot.sample_count,
            channel_count=snapshot.channel_count,
            rms_uv=(a * snapshot.rms_uv) + ((1.0 - a) * prev.rms_uv),
            peak_to_peak_uv=(a * snapshot.peak_to_peak_uv) + ((1.0 - a) * prev.peak_to_peak_uv),
            delta=(a * snapshot.delta) + ((1.0 - a) * prev.delta),
            theta=(a * snapshot.theta) + ((1.0 - a) * prev.theta),
            alpha=(a * snapshot.alpha) + ((1.0 - a) * prev.alpha),
            beta=(a * snapshot.beta) + ((1.0 - a) * prev.beta),
            gamma_low=(a * snapshot.gamma_low) + ((1.0 - a) * prev.gamma_low),
            alpha_beta_ratio=(a * snapshot.alpha_beta_ratio) + ((1.0 - a) * prev.alpha_beta_ratio),
            beta_alpha_ratio=(a * snapshot.beta_alpha_ratio) + ((1.0 - a) * prev.beta_alpha_ratio),
            engagement_ratio=(a * snapshot.engagement_ratio) + ((1.0 - a) * prev.engagement_ratio),
            artifact_ratio=(a * snapshot.artifact_ratio) + ((1.0 - a) * prev.artifact_ratio),
        )
        self._current = smoothed
        return smoothed
