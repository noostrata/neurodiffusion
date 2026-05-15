# OpenBCI EEG Video Control

This is the no-pay development path for controlling the video stream with OpenBCI EEG. It does not require Vast, model weights, R2, or a GPU.

## Current OpenBCI Contracts

This implementation follows the current OpenBCI software guidance:

- OpenBCI recommends starting with the GUI for signal checks, using the BrainFlow Streamer for proof-of-concept, then integrating directly through BrainFlow bindings once the project path is stable.
- BrainFlow is the primary board abstraction for Python integration.
- GUI/LSL remains useful as a debugging bridge because it lets the OpenBCI GUI keep visualizing the stream while our code reads the signal.
- Cyton/Cyton+Daisy serial mode needs a serial port; on macOS, use `/dev/cu.*`.
- Cyton WiFi / Cyton+Daisy WiFi / Ganglion WiFi need `--ip-port`; `--ip-address` is optional when discovery works.
- Cyton defaults to `250 Hz`; BrainFlow returns already-scaled units for Cyton users.
- The GUI signal widget should be used for impedance/live signal quality before trusting any neurofeedback mapping.

## Control Contract

MAGI accepts prompt changes through:

```bash
POST /prompt {"prompt": "..."}
GET /stats
```

MAGI applies prompt changes at chunk boundaries, not per frame. Design EEG control as stable state changes every few seconds, not direct sample-to-frame steering.

Daydream Scope accepts live control through OSC while Scope/WebRTC owns video display.
The current Scope sink sends:

- `/scope/prompt`
- `/scope/noise_scale`
- `/scope/manage_cache`
- `/scope/reset_cache`
- `/scope/transition_steps`
- `/scope/interpolation_method`

This is the preferred path for LongLive realtime EEG control.

For local testing, use the fake server:

```bash
cd /Users/xenochain/Code/neurodiffusion
python3 VideoDiffusion/eeg_control/fake_video_control_server.py \
  --host 127.0.0.1 \
  --port 8765 \
  --chunk-seconds 1.0
```

Then run the controller against mock EEG:

```bash
cd /Users/xenochain/Code/neurodiffusion
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board mock \
  --mock-scenario alternating \
  --url http://127.0.0.1:8765 \
  --duration-s 30
```

The controller logs JSONL to `VideoDiffusion/.tmp/eeg_prompt_control.jsonl`.

## Systematic Session Runner

Use `run_neurofeedback_session.py` for the newer state -> policy -> sink architecture:

```bash
cd /Users/xenochain/Code/neurodiffusion
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink jsonl \
  --duration-s 60
```

Policies:

- `reward`: alpha/low-arousal is rewarded with calmer, more coherent visuals; beta/high-arousal increases pressure.
- `balancer`: alpha/low-arousal produces more frantic visuals; beta/high-arousal produces relaxing visuals.
- `mirror`: the visuals mirror the estimated arousal state.
- `inversion`: the visuals deliberately contradict the estimated state in a more surreal way.

Sinks:

- `stdout`: print session decisions.
- `jsonl`: write every state and command to `VideoDiffusion/.tmp/neurofeedback_session.jsonl`.
- `http`: send emitted prompts to MAGI or the fake server.
- `scope`: send emitted prompts and runtime parameters to Daydream Scope over OSC.
- `schedule`: write a chunk schedule CSV for later replay through `run_prompt_schedule.py`.

Example against the fake server:

```bash
python3 VideoDiffusion/eeg_control/fake_video_control_server.py --port 8765

python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink http \
  --sink schedule \
  --url http://127.0.0.1:8765 \
  --duration-s 120
```

Example against the fake Scope server:

```bash
python3 VideoDiffusion/eeg_control/fake_scope_server.py --port 8000

python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board mock \
  --mock-scenario alternating \
  --policy balancer \
  --sink stdout \
  --sink scope \
  --scope-osc-host 127.0.0.1 \
  --scope-osc-port 8000 \
  --duration-s 60
```

The fake Scope server also accepts `--http-port` and `--osc-port` for split REST/OSC tests.

## Install Optional EEG Dependencies

The mock path needs only the repo's local Python plus `numpy`. OpenBCI hardware and LSL need optional packages:

```bash
python3 -m pip install -r VideoDiffusion/requirements-eeg.txt
```

Use a virtualenv if you do not want to install into your active Python.

## Input Modes

### Mock Input

Use this first. It generates deterministic synthetic windows for `calm`, `active`, `switch`, or `alternating` scenarios.

```bash
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board mock \
  --mock-scenario calm \
  --dry-run \
  --duration-s 10
```

### BrainFlow Synthetic Board

Use this after installing `brainflow`:

```bash
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board synthetic \
  --dry-run \
  --duration-s 10
```

### OpenBCI Cyton

On macOS, BrainFlow expects the `/dev/cu...` serial port.

```bash
ls /dev/cu.*

python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --url http://127.0.0.1:8765
```

For Cyton+Daisy, use `--board cyton-daisy`.

### OpenBCI WiFi Boards

BrainFlow supports OpenBCI WiFi variants through an IP port and optional IP address:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board cyton-wifi \
  --ip-port 6987 \
  --ip-address 192.168.4.1 \
  --policy balancer \
  --sink stdout \
  --duration-s 30
```

Supported aliases:

- `cyton-wifi`
- `cyton-daisy-wifi`
- `ganglion-wifi`

For discovery-based WiFi setup, omit `--ip-address` and keep `--ip-port` set to a free local port.

### BrainFlow Streamer To GUI

If the Python process should own the hardware connection while the GUI visualizes the stream, pass a BrainFlow streamer string:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --streamer-params streaming_board://224.0.0.1:6677 \
  --policy balancer \
  --sink stdout
```

Then set the OpenBCI GUI to receive from an external/streaming board on the same network address and port.

### OpenBCI GUI Over LSL

If you want the OpenBCI GUI visible while developing, enable the GUI Networking widget with LSL output, then read it locally:

```bash
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board lsl \
  --lsl-type EEG \
  --url http://127.0.0.1:8765
```

## Calibration

Run calibration before relying on real headset thresholds:

```bash
python3 VideoDiffusion/eeg_control/calibrate_eeg.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --duration-s 30 \
  --label eyes_open_baseline \
  --output VideoDiffusion/.tmp/eeg_calibration.json
```

Then pass the calibration file to the controller:

```bash
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --calibration VideoDiffusion/.tmp/eeg_calibration.json \
  --url http://127.0.0.1:8765
```

## Feature Mapping

The legacy direct prompt controller uses `VideoDiffusion/eeg_control/prompt_map.example.json`:

- `calm`: high alpha/beta ratio, low artifact score.
- `active`: high beta/alpha or engagement ratio.
- `switch_scene`: large transient, useful for blink or jaw-clench style controls.
- `hold`: no prompt update.

The controller requires consecutive matching windows and a cooldown before sending a prompt. This prevents noisy EEG windows from thrashing the video model.

The systematic runner estimates:

- `low_arousal`: alpha/beta dominant.
- `high_arousal`: beta/alpha or engagement dominant.
- `balanced`: no strong state.
- `transition`: deliberate large transient such as blink or jaw clench.
- `noisy`: likely bad signal or unusable artifact.

Then the selected policy decides what that state means artistically.

## Live MAGI Use

Once mock and real-headset dry runs behave, point `--url` at the real MAGI server:

```bash
QUEUE_LEN=96 DROP_OLD_ON_PROMPT=1 python VideoDiffusion/realtime_magi_stream.py
python3 VideoDiffusion/eeg_control/openbci_to_video_prompt.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --url http://127.0.0.1:8000
```

## Live Scope / LongLive Use

Once mock Scope control works and a GPU host is authorized:

```bash
VIDEO_MODEL=scope bash VideoDiffusion/setup_video_runtime.sh
bash VideoDiffusion/download_scope_models.sh
VIDEO_MODEL=scope bash VideoDiffusion/run_video_stream.sh
bash VideoDiffusion/load_scope_longlive.sh
```

Then run neurofeedback control against Scope's OSC port:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --policy balancer \
  --sink stdout \
  --sink jsonl \
  --sink scope \
  --scope-osc-host 127.0.0.1 \
  --scope-osc-port 8000
```

The video should be viewed through the Scope UI/WebRTC output.
The EEG process controls prompts and runtime parameters; it does not receive or render the video stream itself.

Or with the systematic runner:

```bash
python3 VideoDiffusion/eeg_control/run_neurofeedback_session.py \
  --board cyton \
  --serial-port /dev/cu.usbserial-XXXX \
  --policy balancer \
  --sink stdout \
  --sink http \
  --url http://127.0.0.1:8000
```

For lowest visible prompt latency, keep:

- `MAGI_WINDOW_SIZE=1`
- `QUEUE_LEN` small, for example `96`
- `DROP_OLD_ON_PROMPT=1`
- EEG `--cooldown-s` at least one or two expected chunk times

## Guardrails

- Treat EEG features as noisy control signals, not semantic mind reading.
- Prefer deliberate blinks, jaw clenches, or broad calm/active states for first demos.
- Avoid rapid prompt changes; MAGI cannot apply them mid-chunk.
- Do not run paid Vast experiments until the fake server and real OpenBCI dry-run logs show stable state transitions.
- Keep calibration and logs under `VideoDiffusion/.tmp/` so they stay out of git.

## Reference Links

- OpenBCI software development guidance: https://docs.openbci.com/ForDevelopers/SoftwareDevelopment/
- BrainFlow supported OpenBCI boards: https://brainflow.readthedocs.io/en/stable/SupportedBoards.html
- BrainFlow API: https://brainflow.readthedocs.io/en/stable/UserAPI.html
- OpenBCI GUI BrainFlow streaming: https://docs.openbci.com/Software/OpenBCISoftware/GUIDocs/
- OpenBCI GUI networking and signal widgets: https://docs.openbci.com/Software/OpenBCISoftware/GUIWidgets/
- OpenBCI LSL guide: https://docs.openbci.com/Software/CompatibleThirdPartySoftware/LSL/
- Cyton data format and sample-rate notes: https://docs.openbci.com/Cyton/CytonDataFormat/
