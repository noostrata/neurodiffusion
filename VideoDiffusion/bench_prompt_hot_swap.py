#!/usr/bin/env python3
"""
Benchmark prompt hot-swap latency for VideoDiffusion/realtime_magi_stream.py.

This measures *chunk-boundary* responsiveness:
- POST /prompt
- Poll GET /stats until the server reports a chunk generated with `last_prompt == prompt`

By default, the benchmark waits for a chunk boundary before sending each prompt, which
produces stable measurements close to steady-state TPOC.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass


def _now() -> float:
    return time.monotonic()


def _join(base: str, path: str) -> str:
    return base.rstrip("/") + path


def _http_json(method: str, url: str, payload: dict | None, timeout_s: float) -> dict:
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url=url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
        raise RuntimeError(f"HTTP {e.code} {method} {url}: {body}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"Request failed {method} {url}: {e}") from e

    try:
        return json.loads(body)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"Non-JSON response from {url}: {body[:200]}") from e


def get_stats(base_url: str, timeout_s: float) -> dict:
    return _http_json("GET", _join(base_url, "/stats"), payload=None, timeout_s=timeout_s)


def set_prompt(base_url: str, prompt: str, timeout_s: float) -> dict:
    return _http_json("POST", _join(base_url, "/prompt"), payload={"prompt": prompt}, timeout_s=timeout_s)


def _as_int(v, default: int) -> int:
    try:
        return int(v)
    except Exception:
        return default


def wait_for_server(base_url: str, timeout_s: float, poll_s: float) -> dict:
    deadline = _now() + timeout_s
    last_err = None
    while _now() < deadline:
        try:
            return get_stats(base_url, timeout_s=5)
        except Exception as e:
            last_err = e
            time.sleep(poll_s)
    raise TimeoutError(f"Server not ready at {base_url} after {timeout_s:.0f}s: {last_err}")


def wait_for_chunk_advance(base_url: str, prev_chunk_idx: int, timeout_s: float, poll_s: float) -> dict:
    deadline = _now() + timeout_s
    while _now() < deadline:
        s = get_stats(base_url, timeout_s=10)
        chunk_idx = _as_int(s.get("chunk_idx"), -1)
        if chunk_idx > prev_chunk_idx:
            return s
        time.sleep(poll_s)
    raise TimeoutError(f"Chunk did not advance beyond {prev_chunk_idx} within {timeout_s:.0f}s")


def wait_for_prompt_applied(
    base_url: str,
    prompt: str,
    start_chunk_idx: int,
    timeout_s: float,
    poll_s: float,
) -> dict:
    deadline = _now() + timeout_s
    while _now() < deadline:
        s = get_stats(base_url, timeout_s=10)
        chunk_idx = _as_int(s.get("chunk_idx"), -1)
        last_prompt = s.get("last_prompt")
        if chunk_idx > start_chunk_idx and last_prompt == prompt:
            return s
        time.sleep(poll_s)
    raise TimeoutError(
        f"Prompt not applied within {timeout_s:.0f}s (start_chunk_idx={start_chunk_idx}, prompt={prompt!r})"
    )


def _pctl(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    if p <= 0:
        return min(xs)
    if p >= 1:
        return max(xs)
    ys = sorted(xs)
    k = (len(ys) - 1) * p
    f = int(k)
    c = min(f + 1, len(ys) - 1)
    if f == c:
        return ys[f]
    return ys[f] * (c - k) + ys[c] * (k - f)


@dataclass
class Result:
    prompt: str
    dt_s: float
    chunks_waited: int
    chunk_idx: int
    last_gen_time_s: float | None
    last_chunk_fps: float | None
    queue_size: int | None
    queue_max: int | None


def load_prompts(path: str | None) -> list[str]:
    if not path:
        return [
            "Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving",
            "Drone flyover of snowy mountains at sunrise, drifting fog, long shadows, cinematic",
            "Macro shot of bioluminescent plants in a dark rainforest, glowing spores floating, shallow depth of field",
        ]
    out: list[str] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.append(s)
    if not out:
        raise SystemExit(f"No prompts found in {path}")
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://localhost:8000", help="Base URL for realtime_magi_stream.py")
    ap.add_argument("--prompts-file", default=None, help="Text file with one prompt per line")
    ap.add_argument("--rounds", type=int, default=2, help="Number of cycles through prompts")
    ap.add_argument("--poll", type=float, default=0.25, help="Polling interval seconds")
    ap.add_argument("--server-timeout", type=float, default=120.0, help="Seconds to wait for server /stats")
    ap.add_argument("--prompt-timeout", type=float, default=120.0, help="Seconds to wait for prompt to be applied")
    ap.add_argument(
        "--asap",
        action="store_true",
        help="Send prompts immediately (do not wait for a chunk boundary). Noisier but closer to worst-case latency.",
    )
    args = ap.parse_args(argv)

    base_url = args.url.rstrip("/")
    prompts = load_prompts(args.prompts_file)

    print(f"[bench] url={base_url}")
    print(f"[bench] prompts={len(prompts)} rounds={args.rounds} asap={args.asap}")
    print("[bench] waiting for /stats ...")
    s0 = wait_for_server(base_url, timeout_s=args.server_timeout, poll_s=args.poll)
    prev_chunk = _as_int(s0.get("chunk_idx"), -1)
    print(f"[bench] initial chunk_idx={prev_chunk} queue={s0.get('queue_size')}/{s0.get('queue_max')}")

    results: list[Result] = []
    seq = 0
    for r in range(args.rounds):
        for prompt in prompts:
            seq += 1
            if not args.asap:
                # Align the request to a chunk boundary so we measure stable TPOC-ish latency.
                s_boundary = wait_for_chunk_advance(base_url, prev_chunk_idx=prev_chunk, timeout_s=args.prompt_timeout, poll_s=args.poll)
                prev_chunk = _as_int(s_boundary.get("chunk_idx"), prev_chunk)

            start_chunk = prev_chunk
            t0 = _now()
            _ = set_prompt(base_url, prompt=prompt, timeout_s=10)
            s_applied = wait_for_prompt_applied(
                base_url,
                prompt=prompt,
                start_chunk_idx=start_chunk,
                timeout_s=args.prompt_timeout,
                poll_s=args.poll,
            )
            t1 = _now()
            chunk_idx = _as_int(s_applied.get("chunk_idx"), -1)
            prev_chunk = max(prev_chunk, chunk_idx)

            res = Result(
                prompt=prompt,
                dt_s=t1 - t0,
                chunks_waited=chunk_idx - start_chunk,
                chunk_idx=chunk_idx,
                last_gen_time_s=s_applied.get("last_gen_time_s"),
                last_chunk_fps=s_applied.get("last_chunk_fps"),
                queue_size=s_applied.get("queue_size"),
                queue_max=s_applied.get("queue_max"),
            )
            results.append(res)

            short = (prompt[:72] + "...") if len(prompt) > 75 else prompt
            print(
                f"[{seq:03d}] dt={res.dt_s:6.2f}s chunks={res.chunks_waited:2d} "
                f"gen={res.last_gen_time_s} fps={res.last_chunk_fps} q={res.queue_size}/{res.queue_max} | {short}"
            )

    dts = [r.dt_s for r in results]
    if dts:
        print()
        print("[summary] prompt->chunk-applied latency (seconds)")
        print(f"  n     : {len(dts)}")
        print(f"  mean  : {statistics.mean(dts):.2f}")
        print(f"  p50   : {_pctl(dts, 0.50):.2f}")
        print(f"  p90   : {_pctl(dts, 0.90):.2f}")
        print(f"  p95   : {_pctl(dts, 0.95):.2f}")
        print(f"  max   : {max(dts):.2f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

