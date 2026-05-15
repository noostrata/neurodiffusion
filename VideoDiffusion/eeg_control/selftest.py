#!/usr/bin/env python3
"""No-cost selftests for the offline EEG control layer."""

from __future__ import annotations

import sys
import socket
import threading
import time
from pathlib import Path


if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


def main() -> int:
    try:
        from VideoDiffusion.eeg_control.fake_video_control_server import FakeVideoState, make_server
        from VideoDiffusion.eeg_control.fake_scope_server import FakeScopeState, make_http_server, run_osc_server
        from VideoDiffusion.eeg_control.features import compute_features
        from VideoDiffusion.eeg_control.policies import get_policy
        from VideoDiffusion.eeg_control.prompt_controller import PromptController
        from VideoDiffusion.eeg_control.readers import MockEegReader, ReaderContext
        from VideoDiffusion.eeg_control.scope_client import ScopeApiClient, ScopeOscClient, ScopePromptController
        from VideoDiffusion.eeg_control.state import NeuroStateEstimator
        from VideoDiffusion.eeg_control.video_client import VideoControlClient
    except ImportError as exc:
        print(f"[skip] EEG selftest optional dependency missing: {exc}")
        return 0

    reader = MockEegReader(scenario="calm", sampling_rate=250.0, channel_count=4)
    with ReaderContext(reader) as eeg:
        time.sleep(0.05)
        raw = eeg.get_window(500)
    assert raw is not None
    calm = compute_features(raw, 250.0)
    assert calm.alpha_beta_ratio > 1.0, calm
    calm_state = NeuroStateEstimator().estimate(calm)
    assert calm_state.state == "low_arousal", calm_state
    calm_command = get_policy("balancer").command_for(calm_state)
    assert calm_command.prompt and "Frantic" in calm_command.prompt

    prompt_map = {
        "states": {
            "calm": {"prompt": "calm prompt"},
            "active": {"prompt": "active prompt"},
            "switch_scene": {"prompt": "switch prompt", "momentary": True},
            "hold": {"prompt": ""},
        },
        "controller": {"cooldown_s": 0.0, "consecutive_windows": 1},
        "thresholds": {"calm_alpha_beta_min": 1.1},
    }
    controller = PromptController(prompt_map)
    decision = controller.update(calm, now=10.0)
    assert decision.should_send
    assert decision.prompt == "calm prompt"

    active_reader = MockEegReader(scenario="active", sampling_rate=250.0, channel_count=4)
    with ReaderContext(active_reader) as eeg:
        time.sleep(0.05)
        active_raw = eeg.get_window(500)
    assert active_raw is not None
    active_state = NeuroStateEstimator().estimate(compute_features(active_raw, 250.0))
    assert active_state.state == "high_arousal", active_state
    active_command = get_policy("balancer").command_for(active_state)
    assert active_command.prompt and "Relaxing" in active_command.prompt

    state = FakeVideoState("initial", chunk_seconds=0.05)
    server = make_server("127.0.0.1", 0, state, quiet=True)
    host, port = server.server_address
    clock = threading.Thread(target=state.run_clock, daemon=True)
    serve = threading.Thread(target=server.serve_forever, daemon=True)
    clock.start()
    serve.start()
    try:
        client = VideoControlClient(f"http://{host}:{port}", timeout_s=2.0)
        client.set_prompt("next prompt")
        deadline = time.monotonic() + 2.0
        applied = False
        while time.monotonic() < deadline:
            stats = client.get_stats()
            if stats.get("last_prompt") == "next prompt":
                applied = True
                break
            time.sleep(0.02)
        assert applied, "fake server did not apply prompt on chunk tick"
    finally:
        state.stop_event.set()
        server.shutdown()
        server.server_close()

    scope_state = FakeScopeState()
    scope_server = make_http_server("127.0.0.1", 0, scope_state, quiet=True)
    scope_host, scope_port = scope_server.server_address
    scope_osc = threading.Thread(target=run_osc_server, args=(scope_host, scope_port, scope_state), daemon=True)
    scope_serve = threading.Thread(target=scope_server.serve_forever, daemon=True)
    scope_osc.start()
    scope_serve.start()
    try:
        scope_api = ScopeApiClient(f"http://{scope_host}:{scope_port}", timeout_s=2.0)
        scope_api.load_pipeline(["longlive"], {"height": 320, "width": 576, "seed": 42, "vace_enabled": False})
        scope_status = scope_api.wait_for_pipeline_loaded(timeout_s=1.0, poll_s=0.01)
        assert scope_status["status"] == "loaded"
        assert scope_status["pipeline_id"] == "longlive"

        time.sleep(0.02)
        scope_controller = ScopePromptController(
            ScopeOscClient(scope_host, scope_port),
            transition_steps=3,
            send_noise_scale=True,
            manage_cache=True,
        )
        sent = scope_controller.send_command(active_command.to_jsonable())
        assert sent and sent[-1]["address"] == "/scope/prompt"

        deadline = time.monotonic() + 1.0
        saw_prompt = False
        while time.monotonic() < deadline:
            messages = scope_state.osc_status()["messages"]
            if any(item["address"] == "/scope/prompt" for item in messages):
                saw_prompt = True
                break
            time.sleep(0.02)
        assert saw_prompt, "fake Scope OSC server did not receive /scope/prompt"
    finally:
        scope_state.stop_event.set()
        scope_server.shutdown()
        scope_server.server_close()

    split_scope_state = FakeScopeState()
    split_scope_server = make_http_server("127.0.0.1", 0, split_scope_state, quiet=True)
    split_host, split_http_port = split_scope_server.server_address
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind((split_host, 0))
        split_osc_port = probe.getsockname()[1]
    split_scope_osc = threading.Thread(
        target=run_osc_server,
        args=(split_host, split_osc_port, split_scope_state),
        daemon=True,
    )
    split_scope_serve = threading.Thread(target=split_scope_server.serve_forever, daemon=True)
    split_scope_osc.start()
    split_scope_serve.start()
    try:
        split_api = ScopeApiClient(f"http://{split_host}:{split_http_port}", timeout_s=2.0)
        split_api.load_pipeline(["longlive"], {"height": 320})
        ScopePromptController(ScopeOscClient(split_host, split_osc_port), transition_steps=1).send_command(
            active_command.to_jsonable()
        )
        deadline = time.monotonic() + 1.0
        saw_prompt = False
        while time.monotonic() < deadline:
            messages = split_scope_state.osc_status()["messages"]
            if any(item["address"] == "/scope/prompt" for item in messages):
                saw_prompt = True
                break
            time.sleep(0.02)
        assert saw_prompt, "split-port fake Scope OSC server did not receive /scope/prompt"
    finally:
        split_scope_state.stop_event.set()
        split_scope_server.shutdown()
        split_scope_server.server_close()

    print("[ok] eeg_control selftest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
