#!/usr/bin/env python3
"""Realtime SD-Turbo stream server with prompt hot-swap.

Run this on the VAST.ai instance:
    python3 /workspace/realtime_stream.py

Exposes:
    GET  /stream   – multipart MJPEG at target_fps
    POST /prompt   – JSON {"prompt": "new text"}
"""
import io, time, threading, datetime
from flask import Flask, Response, request, jsonify
from flask_cors import CORS
import torch
from diffusers import AutoPipelineForText2Image

# ───────────────────────────────────────────────────────────────
#  Config
# ───────────────────────────────────────────────────────────────
TARGET_FPS = 30
INITIAL_PROMPT = "cat" # Default prompt for first generation
MODEL_ID = "stabilityai/sd-turbo"
SERVER_PORT = 8000 # Port the Flask server will run on

# ───────────────────────────────────────────────────────────────
#  Model Setup
# ───────────────────────────────────────────────────────────────
print("[init] loading", MODEL_ID)
pipe = AutoPipelineForText2Image.from_pretrained(
    MODEL_ID,
    torch_dtype=torch.float16,
).to("cuda")
pipe.enable_xformers_memory_efficient_attention()
pipe.unet = torch.compile(pipe.unet, mode="max-autotune")
print("[init] model loaded and compiled")

# ───────────────────────────────────────────────────────────────
#  Shared state for prompt & latest JPEG
# ───────────────────────────────────────────────────────────────
# Simplify back to just prompt state
class PromptState:
    def __init__(self, initial_prompt):
        from threading import Lock
        self._lock = Lock()
        self._p = initial_prompt

    def get(self):
        with self._lock:
            return str(self._p)

    def set(self, new):
        with self._lock:
            self._p = new
            print(f"[PromptState] Prompt updated to: {self._p}")
            return self._p

# Initialize state
PROMPT_STATE = PromptState(INITIAL_PROMPT)
latest_jpeg: bytes = b''

# ───────────────────────────────────────────────────────────────
#  Generator Thread – produces frames at TARGET_FPS
# ───────────────────────────────────────────────────────────────

def _gen_loop():
    global latest_jpeg
    interval = 1.0 / TARGET_FPS
    print(f"[gen] starting loop at {TARGET_FPS} FPS with initial prompt: '{PROMPT_STATE.get()}'")
    while True:
        t_start_loop = time.time()
        # --- Get prompt --- START
        try:
            prompt_gen = PROMPT_STATE.get()
        except Exception as e:
             print(f"[gen] Error getting prompt: {e}")
             time.sleep(0.5)
             continue
        # --- Get prompt --- END

        t_got_params = time.time()
        try:
            # --- Generate the image using hardcoded params --- START
            image = pipe(
                prompt=prompt_gen,
                num_inference_steps=1,      # Hardcoded
                guidance_scale=0.0,     # Hardcoded
                generator=None              # Hardcoded (random)
            ).images[0]
            # --- Generate the image using hardcoded params --- END
            t_pipe_done = time.time()

            buf = io.BytesIO()
            image.save(buf, format="JPEG", quality=85)
            latest_jpeg = buf.getvalue()
            t_jpeg_done = time.time()

        except Exception as e:
            print(f"[gen] Error during image generation: {e}")
            time.sleep(0.5)

        # --- Pacing --- START
        t_end_loop = time.time()
        dt = t_end_loop - t_start_loop
        sleep_duration = interval - dt
        if sleep_duration > 0:
            time.sleep(sleep_duration)
        # --- Pacing --- END

threading.Thread(target=_gen_loop, daemon=True).start()

# ───────────────────────────────────────────────────────────────
#  Flask App
# ───────────────────────────────────────────────────────────────
app = Flask(__name__)
CORS(app)

@app.route('/stream')
def stream():
    def _mjpeg():
        boundary = b'--frame'
        print("[stream] Client connected.") # Add log
        try:
            while True:
                frame = latest_jpeg
                if frame:
                    # Yield frame immediately when available
                    yield (boundary + b"\r\n"
                           b"Content-Type: image/jpeg\r\n"
                           + f"Content-Length: {len(frame)}\r\n\r\n".encode()
                           + frame + b"\r\n")
                # Minimal sleep to prevent CPU hogging if loop runs too fast
                time.sleep(0.01) 
        except GeneratorExit:
             print("[stream] Client disconnected.") # Log disconnection
        except Exception as e:
             print(f"[stream] Error in stream loop: {e}") # Log errors in loop
    return Response(_mjpeg(), mimetype='multipart/x-mixed-replace; boundary=frame')

@app.route('/prompt', methods=['POST'])
def set_prompt():
    print("[prompt] Request received")
    data = request.get_json(force=True, silent=True) or {}
    new_prompt = data.get('prompt')
    if not new_prompt:
        return jsonify({'error': 'prompt missing'}), 400
    # Use simplified state
    actual_prompt = PROMPT_STATE.set(new_prompt)
    print(f"[prompt] => Set to: {actual_prompt}")
    return jsonify({'status': 'ok', 'prompt': actual_prompt})

@app.route('/')
def index():
    # No initial state needed other than the placeholder text
    return f'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Schizofusion</title>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=Special+Elite&family=Share+Tech+Mono&display=swap');

    :root {{
      --bg-color: #1a1a1a;
      --text-color: #e0e0e0;
      --primary-color: #ff00ff; /* Bright magenta */
      --secondary-color: #00ffff; /* Cyan */
      --border-color: #444;
      --input-bg: #333;
      --button-bg: var(--primary-color);
      --button-text: var(--bg-color);
      --button-hover-bg: var(--secondary-color);
      --font-main: 'Share Tech Mono', monospace;
      --font-title: 'Special Elite', cursive;
      --label-color: #aaa;
    }}

    body {{
      background-color: var(--bg-color);
      color: var(--text-color);
      font-family: var(--font-main);
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      padding: 1rem;
      overflow-x: hidden; /* Prevent horizontal scroll */
    }}

    .container {{
      max-width: 90vw; /* Max width relative to viewport */
      width: 600px; /* Fixed width for larger screens */
      display: flex;
      flex-direction: column;
      align-items: center;
    }}

    h1 {{
      font-family: var(--font-title);
      color: var(--primary-color);
      font-size: 2.5rem; /* Larger title */
      margin-bottom: 1rem;
      text-shadow: 0 0 5px var(--primary-color), 0 0 10px var(--secondary-color);
      animation: flicker 1.5s infinite alternate;
    }}

    #stream {{
      border: 3px solid var(--border-color);
      max-width: 100%; /* Ensure image fits container */
      height: auto;
      margin-bottom: 1rem;
      box-shadow: 0 0 15px rgba(0, 255, 255, 0.5);
      transition: box-shadow 0.3s ease-in-out;
      cursor: crosshair; /* Fun cursor */
    }}
    #stream:hover {{
        box-shadow: 0 0 25px rgba(255, 0, 255, 0.8);
    }}

    .controls {{
        display: flex;
        flex-wrap: wrap; /* Allow wrapping on small screens */
        justify-content: center;
        width: 100%;
        margin-top: 1rem;
    }}

    #promptBox {{
      flex-grow: 1; /* Take available space */
      min-width: 200px; /* Minimum width before wrapping */
      font-size: 1rem;
      padding: 0.75rem 1rem;
      margin: 0.5rem;
      border: 1px solid var(--primary-color);
      background-color: var(--input-bg);
      color: var(--text-color);
      font-family: var(--font-main);
      outline: none;
      transition: border-color 0.3s ease, box-shadow 0.3s ease;
    }}
    #promptBox:focus {{
        border-color: var(--secondary-color);
        box-shadow: 0 0 10px var(--secondary-color);
    }}

    button {{
      font-size: 1rem;
      padding: 0.75rem 1.5rem;
      margin: 0.5rem;
      border: none;
      background-color: var(--button-bg);
      color: var(--button-text);
      font-family: var(--font-main);
      cursor: pointer;
      transition: background-color 0.3s ease, color 0.3s ease, transform 0.1s ease;
      text-transform: uppercase;
      font-weight: bold;
    }}
    button:hover {{
        background-color: var(--button-hover-bg);
        color: var(--bg-color);
        transform: scale(1.05);
    }}
    button:active {{
        transform: scale(0.98);
    }}

    /* Flicker animation for title */
    @keyframes flicker {{
      0%, 18%, 22%, 25%, 53%, 57%, 100% {{
        text-shadow:
          0 0 4px var(--primary-color),
          0 0 11px var(--primary-color),
          0 0 19px var(--secondary-color),
          0 0 40px var(--secondary-color);
      }}
      20%, 24%, 55% {{
        text-shadow: none;
      }}
    }}

  </style>
</head>
<body>
  <div class="container">
    <h1>Schizofusion</h1>
    <img id="stream" src="/stream" alt="Stream" />
    <div class="controls">
      <input id="promptBox" type="text" placeholder="Enter prompt..." />
      <button onclick="updatePrompt()">Set</button>
    </div>
    <!-- Removed parameter controls section -->
  </div>
  <script>
    // Removed paramUpdateTimeout, updateSliderLabel, updateParamsDebounced, updateParams functions

    async function updatePrompt() {{
      const promptInput = document.getElementById('promptBox');
      const p = promptInput.value;
      const button = document.querySelector('button');
      button.disabled = true;
      button.textContent = 'Setting...';

      try {{
        const res = await fetch('/prompt', {{
          method: 'POST',
          headers: {{ 'Content-Type': 'application/json' }},
          body: JSON.stringify({{ prompt: p }})
        }});
        if (!res.ok) {{
            const errorData = await res.json();
            throw new Error(errorData.error || `HTTP error! status: ${{'{'}res.status{'}'}}`);
        }}
        // Optional: Clear input on success
        // promptInput.value = ''; 
      }} catch (e) {{
        alert('Failed to set prompt: ' + e.message);
      }} finally {{
          button.disabled = false;
          button.textContent = 'Set';
      }}
    }}

    // Allow pressing Enter in the input box
    document.getElementById('promptBox').addEventListener('keypress', function (e) {{
        if (e.key === 'Enter') {{
            updatePrompt();
        }}
    }});

    // Removed DOMContentLoaded listener for sliders
  </script>
</body>
</html>'''

if __name__ == '__main__':
    print(f"[flask] running on 0.0.0.0:{SERVER_PORT}")
    app.run(host='0.0.0.0', port=SERVER_PORT, threaded=True) 