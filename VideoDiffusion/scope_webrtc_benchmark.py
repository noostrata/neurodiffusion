#!/usr/bin/env python3
"""Receive Scope WebRTC video and report frame-rate metrics."""

from __future__ import annotations

import argparse
import asyncio
import json
import time
import urllib.request
from pathlib import Path
from typing import Any


def _json_get(url: str, timeout_s: float) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=timeout_s) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _json_post(url: str, payload: dict[str, Any], timeout_s: float) -> dict[str, Any]:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        return json.loads(resp.read().decode("utf-8"))


async def _wait_ice_complete(pc, timeout_s: float) -> None:
    if pc.iceGatheringState == "complete":
        return
    done = asyncio.Event()

    @pc.on("icegatheringstatechange")
    def _on_ice_state_change() -> None:
        if pc.iceGatheringState == "complete":
            done.set()

    try:
        await asyncio.wait_for(done.wait(), timeout=timeout_s)
    except asyncio.TimeoutError:
        return


async def _run(args: argparse.Namespace) -> dict[str, Any]:
    try:
        from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
    except ImportError as exc:
        raise SystemExit("[error] aiortc is required: python3 -m pip install aiortc") from exc

    base_url = args.base_url.rstrip("/")
    ice_payload = _json_get(f"{base_url}/api/v1/webrtc/ice-servers", args.http_timeout_s)
    ice_servers = [
        RTCIceServer(
            urls=item.get("urls") or item.get("url"),
            username=item.get("username"),
            credential=item.get("credential"),
        )
        for item in ice_payload.get("iceServers", [])
        if item.get("urls") or item.get("url")
    ]
    pc = RTCPeerConnection(RTCConfiguration(iceServers=ice_servers))

    metrics: dict[str, Any] = {
        "base_url": base_url,
        "duration_s": args.duration_s,
        "frame_count": 0,
        "saved_frames": [],
        "first_frame_latency_s": None,
        "fps": 0.0,
        "connection_states": [],
        "ice_connection_states": [],
        "data_channel_opened": False,
        "data_channel_messages": [],
    }
    started = time.monotonic()
    first_frame_at: float | None = None
    track_done = asyncio.Event()
    track_error: str | None = None
    frames_dir: Path | None = None
    video_container = None
    video_stream = None
    if args.frames_dir:
        frames_dir = Path(args.frames_dir).expanduser()
        frames_dir.mkdir(parents=True, exist_ok=True)
    output_video_path: Path | None = None
    if args.output_video:
        output_video_path = Path(args.output_video).expanduser()
        output_video_path.parent.mkdir(parents=True, exist_ok=True)

    channel = pc.createDataChannel("parameters", ordered=True)

    @channel.on("open")
    def _on_channel_open() -> None:
        metrics["data_channel_opened"] = True

    @channel.on("message")
    def _on_channel_message(message) -> None:
        if len(metrics["data_channel_messages"]) < args.max_data_messages:
            metrics["data_channel_messages"].append(str(message)[:500])

    @pc.on("connectionstatechange")
    def _on_connection_state_change() -> None:
        metrics["connection_states"].append({"ts": time.time(), "state": pc.connectionState})

    @pc.on("iceconnectionstatechange")
    def _on_ice_connection_state_change() -> None:
        metrics["ice_connection_states"].append({"ts": time.time(), "state": pc.iceConnectionState})

    @pc.on("track")
    def _on_track(track) -> None:
        async def receive() -> None:
            nonlocal first_frame_at, track_error, video_container, video_stream
            deadline = time.monotonic() + args.duration_s
            try:
                while time.monotonic() < deadline:
                    frame = await asyncio.wait_for(track.recv(), timeout=args.frame_timeout_s)
                    now = time.monotonic()
                    metrics["frame_count"] += 1
                    frame_index = int(metrics["frame_count"])
                    if first_frame_at is None:
                        first_frame_at = now
                        metrics["first_frame_latency_s"] = first_frame_at - started
                    if (
                        frames_dir is not None
                        and len(metrics["saved_frames"]) < args.max_saved_frames
                        and frame_index % args.save_every_n_frames == 0
                    ):
                        frame_path = frames_dir / f"frame_{frame_index:06d}.png"
                        frame.to_image().save(frame_path)
                        metrics["saved_frames"].append(str(frame_path))
                    if output_video_path is not None:
                        import av

                        arr = frame.to_ndarray(format="rgb24")
                        if video_container is None:
                            video_container = av.open(str(output_video_path), "w")
                            video_stream = video_container.add_stream("libx264", rate=args.output_video_fps)
                            video_stream.width = arr.shape[1] + (arr.shape[1] % 2)
                            video_stream.height = arr.shape[0] + (arr.shape[0] % 2)
                            video_stream.pix_fmt = "yuv420p"
                        if arr.shape[1] != video_stream.width or arr.shape[0] != video_stream.height:
                            import numpy as np

                            arr = np.pad(
                                arr,
                                ((0, video_stream.height - arr.shape[0]), (0, video_stream.width - arr.shape[1]), (0, 0)),
                                mode="edge",
                            )
                        out_frame = av.VideoFrame.from_ndarray(arr, format="rgb24")
                        for packet in video_stream.encode(out_frame):
                            video_container.mux(packet)
            except Exception as exc:  # aiortc raises MediaStreamError at stream end.
                track_error = repr(exc)
            finally:
                if video_container is not None and video_stream is not None:
                    for packet in video_stream.encode(None):
                        video_container.mux(packet)
                    video_container.close()
                    metrics["output_video"] = str(output_video_path)
                track_done.set()

        asyncio.create_task(receive())

    pc.addTransceiver("video", direction="recvonly")
    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    await _wait_ice_complete(pc, args.ice_timeout_s)

    initial_parameters = {
        "pipeline_ids": [args.pipeline_id],
        "prompts": [{"text": args.prompt, "weight": 1.0}],
        "denoising_step_list": [1000, 750, 500, 250],
        "manage_cache": True,
    }
    answer_payload = _json_post(
        f"{base_url}/api/v1/webrtc/offer",
        {
            "sdp": pc.localDescription.sdp,
            "type": pc.localDescription.type,
            "initialParameters": initial_parameters,
        },
        args.http_timeout_s,
    )
    metrics["session_id"] = answer_payload.get("sessionId")
    await pc.setRemoteDescription(RTCSessionDescription(sdp=answer_payload["sdp"], type=answer_payload["type"]))

    try:
        await asyncio.wait_for(track_done.wait(), timeout=args.duration_s + args.frame_timeout_s + 10.0)
    except asyncio.TimeoutError:
        track_error = "benchmark timed out waiting for video frames"
    finally:
        elapsed = max(0.001, time.monotonic() - started)
        frame_elapsed = max(0.001, time.monotonic() - (first_frame_at or started))
        metrics["elapsed_s"] = elapsed
        metrics["fps"] = float(metrics["frame_count"]) / frame_elapsed
        metrics["track_error"] = track_error
        await pc.close()
    return metrics


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Benchmark Scope WebRTC receive FPS.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--duration-s", type=float, default=60.0)
    parser.add_argument("--pipeline-id", default="longlive")
    parser.add_argument("--prompt", default="A luminous cyberpunk plaza breathing with slow neon fog and fluid camera motion.")
    parser.add_argument("--output-json", default="")
    parser.add_argument("--http-timeout-s", type=float, default=30.0)
    parser.add_argument("--ice-timeout-s", type=float, default=10.0)
    parser.add_argument("--frame-timeout-s", type=float, default=20.0)
    parser.add_argument("--max-data-messages", type=int, default=12)
    parser.add_argument("--frames-dir", default="", help="Optional directory for sampled PNG frames.")
    parser.add_argument("--save-every-n-frames", type=int, default=24)
    parser.add_argument("--max-saved-frames", type=int, default=12)
    parser.add_argument("--output-video", default="", help="Optional MP4 recording path for all received frames.")
    parser.add_argument("--output-video-fps", type=int, default=24)
    args = parser.parse_args(argv)
    if args.save_every_n_frames < 1:
        parser.error("--save-every-n-frames must be >= 1")
    if args.max_saved_frames < 0:
        parser.error("--max-saved-frames must be >= 0")

    metrics = asyncio.run(_run(args))
    raw = json.dumps(metrics, indent=2, sort_keys=True) + "\n"
    if args.output_json:
        out = Path(args.output_json).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(raw, encoding="utf-8")
    print(raw, end="")
    return 0 if metrics.get("frame_count", 0) > 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
