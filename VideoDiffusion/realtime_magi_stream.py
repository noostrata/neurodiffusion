#!/usr/bin/env python3
"""
Realtime MAGI-1 stream server with chunk-wise prompt hot-swap.

This server implements prompt changes at **chunk boundaries** (each chunk is 24 frames).
It does not change the prompt mid-chunk.

Setup (on the pod):

    cd VideoDiffusion
    bash setup.sh
    bash download_weights.sh

Run (single GPU):

    export CUDA_VISIBLE_DEVICES=0
    export MAGI_INITIAL_PROMPT="Slow dolly shot through a busy cyberpunk alley at night, neon signs flickering, light rain, passing cars and pedestrians moving"
    export QUEUE_LEN=96
    export DROP_OLD_ON_PROMPT=1
    export JPEG_QUALITY=75
    python realtime_magi_stream.py

Then open:

    http://<host>:8000
"""

import io, time, threading, queue, os, sys, json, traceback
from pathlib import Path

import numpy as np
from flask import Flask, Response, request, jsonify
from flask_cors import CORS
from PIL import Image

# Add MAGI-1 directory to sys.path to allow import without a pip install.
MAGI_DIR = Path(__file__).parent / "MAGI-1"
if not MAGI_DIR.is_dir():
    print(f"Error: MAGI-1 directory not found at {MAGI_DIR}")
    print("Please run setup.sh first.")
    sys.exit(1)
sys.path.insert(0, str(MAGI_DIR))

# MAGI-1 loads some assets via a relative path by default. Make it robust no matter the cwd.
os.environ.setdefault("SPECIAL_TOKEN_PATH", str(MAGI_DIR / "example/assets/special_tokens.npz"))

# ───────────────────────────────────────────── Config ──
# Assumes MAGI-1 repo is cloned in the same directory as this script.
# Override with MAGI_CONFIG_FILE if you want to point to a different config.
CONFIG_FILE = os.getenv(
    "MAGI_CONFIG_FILE",
    str(MAGI_DIR / "example/4.5B/4.5B_distill_quant_config.json"),
)
SERVER_PORT = int(os.getenv("SERVER_PORT", "8000"))
QUEUE_LEN   = int(os.getenv("QUEUE_LEN", "600"))  # holds ~20 s at 30 fps
JPEG_QUALITY = int(os.getenv("JPEG_QUALITY", "85"))
DROP_OLD_ON_PROMPT = os.getenv("DROP_OLD_ON_PROMPT", "1").strip().lower() in {"1", "true", "yes", "on"}
INITIAL_PROMPT = os.getenv("MAGI_INITIAL_PROMPT", "sunset over baltic sea")

# ─────────────────────────────────────── Prompt state ──
class PromptState:
    def __init__(self, initial: str):
        from threading import Lock
        self._lock = Lock()
        self._p = initial
    def get(self):
        with self._lock:
            return self._p
    def set(self, new):
        with self._lock:
            self._p = new
            print(f"[Prompt] Set to: {self._p}")
            return self._p

PROMPT_STATE = PromptState(INITIAL_PROMPT)

# ─────────────────────────────────────── Stats state ──
class StatsState:
    def __init__(self):
        from threading import Lock
        self._lock = Lock()
        self._d = {
            "chunk_idx": -1,
            "last_gen_time_s": None,
            "last_chunk_fps": None,
            "last_prompt": None,
            "last_error": None,
        }

    def get(self):
        with self._lock:
            return dict(self._d)

    def update(self, **kwargs):
        with self._lock:
            self._d.update(kwargs)
            return dict(self._d)


STATS_STATE = StatsState()

def _parse_bool_env(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    raw = raw.strip().lower()
    if raw in {"1", "true", "yes", "on"}:
        return True
    if raw in {"0", "false", "no", "off"}:
        return False
    return default


def _safe_int_env(name: str, default: int | None) -> int | None:
    raw = os.getenv(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw)
    except Exception:
        return default


def _ensure_dist_env_defaults():
    # MAGI-1's dist_init() uses env://. Provide safe defaults so `python realtime_magi_stream.py`
    # works without requiring torchrun for the single-process case.
    os.environ.setdefault("MASTER_ADDR", "127.0.0.1")
    os.environ.setdefault("MASTER_PORT", os.getenv("MASTER_PORT", "29500"))
    os.environ.setdefault("RANK", os.getenv("RANK", "0"))
    os.environ.setdefault("WORLD_SIZE", os.getenv("WORLD_SIZE", "1"))
    os.environ.setdefault("LOCAL_RANK", os.getenv("LOCAL_RANK", os.environ.get("RANK", "0")))


def _patch_config_file(src_path: str) -> str:
    """Create a patched config JSON with absolute weight paths and env overrides."""
    if not Path(src_path).is_file():
        raise FileNotFoundError(f"Config file not found: {src_path}")

    with open(src_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    runtime = cfg.get("runtime_config", {}) or {}
    for key in ("load", "t5_pretrained", "vae_pretrained"):
        raw = runtime.get(key)
        if isinstance(raw, str) and raw.startswith("./"):
            runtime[key] = str(MAGI_DIR / raw[2:])

    t5_device = os.environ.get("MAGI_T5_DEVICE", os.environ.get("VIDEO_MAGE_T5_DEVICE"))
    if t5_device:
        runtime["t5_device"] = t5_device.strip()

    # Throughput knobs (testing): override without editing vendor files.
    for env_key, cfg_key in (
        ("MAGI_NUM_STEPS", "num_steps"),
        ("MAGI_NUM_FRAMES", "num_frames"),
        ("MAGI_VIDEO_SIZE_H", "video_size_h"),
        ("MAGI_VIDEO_SIZE_W", "video_size_w"),
        ("MAGI_WINDOW_SIZE", "window_size"),
    ):
        v = _safe_int_env(env_key, None)
        if v is not None:
            runtime[cfg_key] = v

    cfg["runtime_config"] = runtime

    engine = cfg.get("engine_config", {}) or {}

    # fp8_quant: allow VIDEO_MAGE_FP8/MAGI_FP8 overrides (same semantics as test_single_chunk.sh).
    fp8_override = os.environ.get("MAGI_FP8", os.environ.get("VIDEO_MAGE_FP8", "auto")).strip().lower()
    if fp8_override in {"0", "false", "off", "no"}:
        engine["fp8_quant"] = False
    elif fp8_override in {"1", "true", "on", "yes"}:
        engine["fp8_quant"] = True
    elif fp8_override in {"auto", ""}:
        # Match test_single_chunk.sh behavior:
        # enable fp8 only on Hopper-class GPUs (sm90+) when detectable.
        try:
            import torch

            if torch.cuda.is_available() and torch.cuda.device_count() > 0:
                caps = [torch.cuda.get_device_capability(i) for i in range(torch.cuda.device_count())]
                has_sm90 = any((major >= 9) for major, _minor in caps)
                engine["fp8_quant"] = bool(has_sm90)
            else:
                engine["fp8_quant"] = cfg.get("engine_config", {}).get("fp8_quant", True)
        except Exception:
            engine["fp8_quant"] = cfg.get("engine_config", {}).get("fp8_quant", True)
    else:
        raise SystemExit(f"Unsupported MAGI_FP8/VIDEO_MAGE_FP8='{fp8_override}'. Use 0/1/true/false/auto.")

    # Optional explicit parallelism overrides.
    cp = _safe_int_env("MAGI_CP_SIZE", None)
    pp = _safe_int_env("MAGI_PP_SIZE", None)
    if cp is not None:
        engine["cp_size"] = cp
    if pp is not None:
        engine["pp_size"] = pp

    # Optional auto-parallel: keep the run unblocked when torchrun world size differs.
    auto_parallel = _parse_bool_env("MAGI_AUTO_PARALLEL", True)
    try:
        world_size = int(os.environ.get("WORLD_SIZE", "1"))
    except Exception:
        world_size = 1
    cur_cp = int(engine.get("cp_size", 1) or 1)
    cur_pp = int(engine.get("pp_size", 1) or 1)
    if auto_parallel and world_size > 1 and cur_cp * cur_pp != world_size:
        engine["cp_size"] = world_size
        engine["pp_size"] = 1

    cfg["engine_config"] = engine

    tmp_dir = Path(__file__).parent / ".tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    rank = os.environ.get("RANK", "0")
    dst_path = tmp_dir / f"magi_stream_cfg_pid{os.getpid()}_rank{rank}.json"
    with open(dst_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=4)
    return str(dst_path)


def _dist_available_and_initialized() -> bool:
    try:
        import torch.distributed as dist

        return dist.is_available() and dist.is_initialized()
    except Exception:
        return False


def _broadcast_prompt_text(text: str) -> str:
    if not _dist_available_and_initialized():
        return text
    import torch.distributed as dist

    obj = [text]
    dist.broadcast_object_list(obj, src=0)
    return obj[0]


def _init_magi():
    _ensure_dist_env_defaults()
    patched_cfg_path = _patch_config_file(CONFIG_FILE)

    import torch
    from inference.common import MagiConfig, print_rank_0, set_random_seed
    from inference.infra.distributed import dist_init
    from inference.model.dit import get_dit

    cfg = MagiConfig.from_json(patched_cfg_path)
    set_random_seed(cfg.runtime_config.seed)

    print_rank_0(f"[init] config_file={patched_cfg_path}")
    dist_init(cfg)

    model = get_dit(cfg)

    chunk_frames = int(cfg.runtime_config.chunk_width) * int(cfg.runtime_config.temporal_downsample_factor)
    rank = int(os.environ.get("RANK", "0"))
    world_size = int(os.environ.get("WORLD_SIZE", "1"))

    print_rank_0(
        f"[init] rank={rank} world_size={world_size} chunk_frames={chunk_frames} "
        f"steps={cfg.runtime_config.num_steps} window_size={cfg.runtime_config.window_size} "
        f"size={cfg.runtime_config.video_size_w}x{cfg.runtime_config.video_size_h} frames={cfg.runtime_config.num_frames}"
    )

    return cfg, model, chunk_frames, rank, world_size

# ───────────────────────────── Frame producer thread ──
jpeg_queue: "queue.Queue[bytes]" = queue.Queue(maxsize=QUEUE_LEN)
producer_stop_event = threading.Event()
producer_thread: threading.Thread | None = None

def drain_queue(q: "queue.Queue[bytes]") -> int:
    dropped = 0
    try:
        while True:
            q.get_nowait()
            dropped += 1
    except queue.Empty:
        pass
    return dropped

def encode_frames(frames: np.ndarray) -> list[bytes]:
    """frames: uint8 ndarray (T,H,W,3) -> list of JPEG bytes."""
    out = []
    start_time = time.time()
    for i, f in enumerate(frames):
        buf = io.BytesIO()
        Image.fromarray(f).save(buf, format="JPEG", quality=JPEG_QUALITY)
        out.append(buf.getvalue())
    end_time = time.time()
    # print(f"[encode] Encoded {len(frames)} frames in {end_time - start_time:.3f}s")
    return out

def producer_loop():
    # Heavy imports happen here so importing this module stays cheap.
    import torch
    from inference.pipeline.prompt_process import get_special_token_keys, get_txt_embeddings, pad_special_token
    from inference.pipeline.video_generate import SampleTransport, extract_feature_for_inference
    from inference.pipeline.video_process import post_chunk_process

    cfg, model, chunk_frames, rank, _world_size = _init_magi()

    applied_prompt = None
    global_chunk_idx = 0
    print(f"[producer] Starting generation loop (rank={rank})...")
    while not producer_stop_event.is_set():
        try:
            # Start a new sequence each time we finish num_frames (keeps server "always on").
            # Prompt hot-swap is handled chunk-by-chunk inside the loop.
            p0 = PROMPT_STATE.get() if rank == 0 else ""
            p0 = _broadcast_prompt_text(p0)
            applied_prompt = p0

            caption_embs, emb_masks = get_txt_embeddings(p0, cfg)
            transport_input = extract_feature_for_inference(model, prefix_video=None, caption_embs=caption_embs, emb_masks=emb_masks)
            sample_transport = SampleTransport(model=model, transport_inputs=[transport_input], device=f"cuda:{torch.cuda.current_device()}")
            walker = sample_transport.walk()

            # Compute a reusable per-chunk conditioned embedding for a prompt.
            def _compute_one_chunk_caption(prompt_text: str):
                cap, mask = get_txt_embeddings(prompt_text, cfg)  # cap: (1,1,L,D), mask: (1,L)
                mask = mask.unsqueeze(1)  # (1,1,L)
                cap, mask = pad_special_token(get_special_token_keys(), cap, mask)
                return cap, mask

            # Apply the prompt to all future chunks starting at `start_chunk_idx`.
            def _apply_prompt_from(start_chunk_idx: int, prompt_text: str):
                nonlocal applied_prompt
                if start_chunk_idx >= transport_input.chunk_num:
                    return
                cap1, mask1 = _compute_one_chunk_caption(prompt_text)
                remaining = transport_input.chunk_num - start_chunk_idx
                # y layout: [cond, uncond] x [chunk] x [token] x [dim]
                with torch.inference_mode():
                    transport_input.y[0:1, start_chunk_idx:].copy_(cap1.expand(1, remaining, -1, -1))
                    transport_input.emb_masks[0:1, start_chunk_idx:].copy_(mask1.expand(1, remaining, -1))
                applied_prompt = prompt_text

            while not producer_stop_event.is_set():
                step_start = time.time()
                try:
                    _infer_idx, chunk_idx, latent_chunk = next(walker)  # blocks until a clean chunk is ready
                except StopIteration:
                    if rank == 0:
                        print("[producer] Sequence complete; restarting new sample transport.")
                    break
                model_time = time.time() - step_start

                decode_start = time.time()
                frames_tchw = post_chunk_process(latent_chunk, cfg)  # uint8 tensor, (T,C,H,W)
                decode_time = time.time() - decode_start

                rgb = frames_tchw.permute(0, 2, 3, 1).contiguous().cpu().numpy()  # (T,H,W,3) uint8

                total_time = model_time + decode_time
                fps = (chunk_frames / total_time) if total_time > 0 else float("inf")

                if rank == 0:
                    print(
                        f"[producer] Chunk {global_chunk_idx} (local={chunk_idx}) "
                        f"model={model_time:.3f}s decode={decode_time:.3f}s total={total_time:.3f}s ({fps:.2f} fps)"
                    )
                    STATS_STATE.update(
                        chunk_idx=global_chunk_idx,
                        last_gen_time_s=total_time,
                        last_chunk_fps=fps,
                        last_prompt=applied_prompt,
                        last_error=None,
                    )

                # Only rank 0 serves MJPEG frames; other ranks just participate in distributed compute.
                if rank == 0:
                    start_encode_time = time.time()
                    jpegs = encode_frames(rgb)
                    encode_time = time.time() - start_encode_time

                    dropped = 0
                    for i, jpeg in enumerate(jpegs):
                        try:
                            jpeg_queue.put(jpeg, timeout=1)
                        except queue.Full:
                            dropped += 1
                            try:
                                jpeg_queue.get_nowait()
                            except queue.Empty:
                                pass
                            try:
                                jpeg_queue.put_nowait(jpeg)
                            except queue.Full:
                                pass

                    if dropped:
                        print(
                            f"[producer] Dropped {dropped} buffered frame(s) (queue full). "
                            f"Consider lowering QUEUE_LEN for tighter prompt latency."
                        )

                    # Keep some visibility into encode cost on slow CPUs.
                    if encode_time > 0.5:
                        print(f"[producer] Warning: JPEG encode took {encode_time:.3f}s for {len(jpegs)} frames.")

                global_chunk_idx += 1

                # Apply prompt changes for the *next* chunk before the generator resumes.
                next_prompt = PROMPT_STATE.get() if rank == 0 else ""
                next_prompt = _broadcast_prompt_text(next_prompt)
                if next_prompt != applied_prompt:
                    # Update from next chunk onward.
                    _apply_prompt_from(start_chunk_idx=int(chunk_idx) + 1, prompt_text=next_prompt)

        except Exception as e:
            print(f"[producer] Error in generation loop: {e!r}")
            traceback.print_exc()
            STATS_STATE.update(last_error=str(e))
            # Decide how to handle errors, e.g., retry, log, exit?
            time.sleep(1) # Avoid rapid failure loops

    print("[producer] Exited generation loop.")

# ───────────────────────────────────────── Flask app ──
app = Flask(__name__)
CORS(app)

@app.route('/stream')
def stream():
    boundary = b'--frame'
    def gen():
        print("[stream] Client connected.")
        last_yield_time = time.time()
        frames_yielded = 0
        try:
            while True:
                try:
                    frame = jpeg_queue.get(timeout=5) # Wait up to 5s for a frame
                    yield (boundary + b"\r\n"
                           b"Content-Type: image/jpeg\r\n\r\n" +
                           frame + b"\r\n")
                    now = time.time()
                    # print(f"[stream] Yielded frame {frames_yielded}, time since last: {now - last_yield_time:.3f}s")
                    last_yield_time = now
                    frames_yielded += 1
                except queue.Empty:
                    # print("[stream] Timeout waiting for frame. Checking producer status.")
                    if producer_thread is not None and (not producer_thread.is_alive()):
                        print("[stream] Producer thread seems to have stopped. Ending stream.")
                        break
                    # If producer is alive, generation is still in progress.
                    # Keep waiting without emitting non-JPEG multipart payloads.
                    time.sleep(0.1)
        except GeneratorExit:
            print("[stream] Client disconnected.")
        except Exception as e:
            print(f"[stream] Error in streaming generator: {e}")
        finally:
            print("[stream] Stream generator finished.")

    return Response(gen(),
                    mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/prompt', methods=['POST'])
def set_prompt():
    data = request.get_json(force=True) or {}
    text = data.get("prompt")
    if not text:
        return jsonify({"error": "prompt missing"}), 400
    new = PROMPT_STATE.set(text)
    dropped = 0
    if DROP_OLD_ON_PROMPT:
        dropped = drain_queue(jpeg_queue)
        if dropped:
            print(f"[prompt] Dropped {dropped} queued frame(s) after prompt change to reduce latency.")
    return jsonify({"status": "ok", "prompt": new, "dropped_frames": dropped})

@app.route('/stats')
def stats():
    d = STATS_STATE.get()
    try:
        d["queue_size"] = jpeg_queue.qsize()
        d["queue_max"] = QUEUE_LEN
    except Exception:
        pass
    return jsonify(d)

@app.route('/')
def index():
    # Simple HTML page with MJPEG display and prompt input
    return """<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MAGI-1 Realtime Stream</title>
    <style>
        body { font-family: sans-serif; margin: 2em; background-color: #f4f4f4; }
        img { display: block; margin-bottom: 1em; max-width: 100%; height: auto; border: 1px solid #ccc; }
        #controls { display: flex; gap: 0.5em; align-items: center; }
        #prompt-input { flex-grow: 1; padding: 0.5em; border: 1px solid #ccc; border-radius: 4px; }
        button { padding: 0.5em 1em; background-color: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background-color: #0056b3; }
        #status { margin-top: 1em; font-style: italic; color: #555; }
    </style>
</head>
<body>
    <h1>MAGI-1 Realtime Stream</h1>
    <img id="video-stream" src="/stream" alt="MJPEG stream" />
    <div id="controls">
        <input id="prompt-input" type="text" placeholder="Enter new prompt...">
        <button onclick="setNewPrompt()">Set Prompt</button>
    </div>
    <div id="status"></div>

    <script>
        async function setNewPrompt() {
            const input = document.getElementById('prompt-input');
            const statusDiv = document.getElementById('status');
            const promptText = input.value.trim();
            if (!promptText) {
                statusDiv.textContent = 'Error: Prompt cannot be empty.';
                return;
            }
            statusDiv.textContent = 'Sending prompt...';
            try {
                const response = await fetch('/prompt', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ prompt: promptText })
                });
                const result = await response.json();
                if (response.ok) {
                    statusDiv.textContent = `Prompt set to: ${result.prompt}`;
                    // input.value = ''; // Optionally clear input after success
                } else {
                    statusDiv.textContent = `Error: ${result.error || 'Unknown error'}`;
                }
            } catch (error) {
                statusDiv.textContent = `Error sending prompt: ${error}`;
            }
        }
        // Add Enter key listener to input
        document.getElementById('prompt-input').addEventListener('keypress', function(event) {
            if (event.key === 'Enter') {
                event.preventDefault(); // Prevent default form submission if any
                setNewPrompt();
            }
        });
        // Basic error handling for the MJPEG stream
        const imgElement = document.getElementById('video-stream');
        imgElement.onerror = () => {
            document.getElementById('status').textContent = 'Error loading video stream. Is the server running?';
        };
    </script>
</body>
</html>
"""

if __name__ == '__main__':
    producer_thread = threading.Thread(target=producer_loop, daemon=True)
    producer_thread.start()

    # Only rank 0 serves HTTP. Other ranks must stay alive to participate in distributed compute.
    rank = int(os.environ.get("RANK", "0"))
    if rank != 0:
        print(f"[server] rank={rank}: not starting HTTP server; waiting for stop.")
        try:
            while producer_thread.is_alive():
                time.sleep(1)
        except KeyboardInterrupt:
            producer_stop_event.set()
        sys.exit(0)

    print(f"[server] Starting Flask server on port {SERVER_PORT} (rank=0)...")
    try:
        # Use werkzeug server which is better than Flask's default for development
        # Set threaded=True to handle multiple requests concurrently (e.g., stream + prompt posts)
        app.run(host='0.0.0.0', port=SERVER_PORT, threaded=True, debug=False)
    except KeyboardInterrupt:
        print("\n[server] KeyboardInterrupt received. Shutting down...")
        producer_stop_event.set()
        producer_thread.join(timeout=5) # Wait for producer to finish current chunk
    finally:
        print("[server] Flask server stopped.") 
