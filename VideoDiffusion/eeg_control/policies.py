#!/usr/bin/env python3
"""Art policies that translate neurofeedback state into visual commands."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Mapping

from .state import NeuroState


@dataclass
class ArtCommand:
    policy: str
    state: str
    prompt: str | None
    intensity: float
    motion: str
    palette: str
    valence: str
    reason: str
    metadata: dict[str, str | float] = field(default_factory=dict)

    def to_jsonable(self) -> dict:
        return asdict(self)


PROMPT_GRAMMARS: dict[str, dict[str, dict[str, str]]] = {
    "reward": {
        "low_arousal": {
            "motion": "slow",
            "palette": "soft neon",
            "valence": "reward",
            "prompt": "Slow floating camera through a rain-soft cyberpunk garden, coherent luminous architecture, gentle neon reflections, calm breathing rhythm, beautiful stable composition",
        },
        "high_arousal": {
            "motion": "frantic",
            "palette": "hot contrast",
            "valence": "pressure",
            "prompt": "Tense cyberpunk street, fast cuts, crowded motion, sharp contrast, noisy holograms, restless camera, visual pressure increasing",
        },
    },
    "balancer": {
        "low_arousal": {
            "motion": "frantic",
            "palette": "electric contrast",
            "valence": "stimulate",
            "prompt": "Frantic cyberpunk market, rapid tracking camera, dense passing traffic, flickering signs, high contrast neon, aggressive parallax, accelerating crowd motion",
        },
        "high_arousal": {
            "motion": "slow",
            "palette": "cool rain",
            "valence": "downregulate",
            "prompt": "Relaxing cyberpunk night rain, slow gliding camera, soft reflections, spacious street, drifting steam, gentle light pulses, calm visual rhythm",
        },
    },
    "mirror": {
        "low_arousal": {
            "motion": "slow",
            "palette": "wide blue",
            "valence": "mirror",
            "prompt": "Quiet wide cyberpunk skyline, slow camera drift, open space, minimal movement, soft blue neon, distant rain",
        },
        "high_arousal": {
            "motion": "fast",
            "palette": "dense magenta",
            "valence": "mirror",
            "prompt": "Dense cyberpunk tunnel, fast handheld camera, pulsing signs, crowded foreground motion, sharp reflections, energetic visual rhythm",
        },
    },
    "inversion": {
        "low_arousal": {
            "motion": "contradictory",
            "palette": "overexposed neon",
            "valence": "inversion",
            "prompt": "A calm brain state fractures into impossible neon turbulence, serene faces inside chaotic traffic, violent camera acceleration with dreamlike stillness underneath",
        },
        "high_arousal": {
            "motion": "suspended",
            "palette": "pale silver",
            "valence": "inversion",
            "prompt": "A high arousal state collapses into suspended slow motion, silent rain, pale silver lights, empty boulevard, all motion softened into a lucid pause",
        },
    },
}

COMMON_STATES: dict[str, dict[str, str]] = {
    "balanced": {
        "motion": "steady",
        "palette": "balanced neon",
        "valence": "hold",
        "prompt": "",
    },
    "transition": {
        "motion": "cut",
        "palette": "hard shift",
        "valence": "event",
        "prompt": "Hard scene transition to a new cyberpunk angle, strong parallax, sudden light shift, passing bikes, animated holograms, wet pavement reflections",
    },
    "noisy": {
        "motion": "pause",
        "palette": "dim",
        "valence": "hold",
        "prompt": "",
    },
}


class NeurofeedbackPolicy:
    def __init__(self, name: str, grammar: Mapping[str, Mapping[str, str]]):
        self.name = name
        self.grammar = {key: dict(value) for key, value in grammar.items()}

    def command_for(self, state: NeuroState) -> ArtCommand:
        entry = dict(COMMON_STATES.get(state.state) or {})
        entry.update(self.grammar.get(state.state) or {})
        prompt = (entry.get("prompt") or "").strip() or None
        return ArtCommand(
            policy=self.name,
            state=state.state,
            prompt=prompt,
            intensity=state.intensity,
            motion=entry.get("motion", "steady"),
            palette=entry.get("palette", "neutral"),
            valence=entry.get("valence", "hold"),
            reason=state.reason,
            metadata={
                "arousal": state.arousal,
                "relaxation": state.relaxation,
                "confidence": state.confidence,
            },
        )


def available_policies() -> tuple[str, ...]:
    return tuple(sorted(PROMPT_GRAMMARS.keys()))


def get_policy(name: str) -> NeurofeedbackPolicy:
    if name not in PROMPT_GRAMMARS:
        raise ValueError(f"Unknown policy {name!r}; choose one of: {', '.join(available_policies())}")
    return NeurofeedbackPolicy(name=name, grammar=PROMPT_GRAMMARS[name])
