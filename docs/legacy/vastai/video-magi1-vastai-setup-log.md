# (LEGACY) Guide: Setting Up MAGI-1 (24B Distill FP8) on Vast.ai

This document is kept for historical reference. The repo is now structured around Prime Intellect pods.
# Target: Real-time Video Streaming (>25fps) on 4x RTX 4090
# Base Image: vastai/pytorch:2.6.0-cuda-12.4.1
# Last Updated: 2025-04-29 (Approx)

## 1. Introduction & Goal

This guide details the steps to set up the MAGI-1 24B distilled FP8 quantized model for efficient video generation on a Vast.ai instance equipped with 4x RTX 4090 GPUs. The goal is to achieve real-time streaming performance (>25 fps) by navigating the specific challenges encountered during setup.

Key challenges addressed in this guide include:
- Adapting original setup scripts (designed for Conda) to a base Python environment.
- Resolving complex Python dependency installation issues (`flash-attn`, `flashinfer-python`, `MagiAttention`).
- Correctly downloading model weights (including handling LFS and non-LFS files).
- Configuring model paths.
- Fixing runtime errors encountered during initial testing.

## 2. Vast.ai Instance Setup

1.  **Rent Instance:** Manually rent a 4x RTX 4090 instance via the Vast.ai UI.
    *   **GPU:** 4 x RTX 4090
    *   **Image:** Select `vastai/pytorch:2.6.0-cuda-12.4.1`. This image provides PyTorch >= 2.4, CUDA >= 12.4, and Python 3.10, but importantly, **does not include Conda**.
    *   **Ports:** Ensure port 8000 (or your desired port for the streaming server) is mapped/opened during instance creation.
2.  **Get SSH Details:** Once the instance is running, obtain the direct SSH connection details.
    *   Run locally: `vastai ssh-url <YOUR_INSTANCE_ID>` (Replace `<YOUR_INSTANCE_ID>` with your actual instance ID).
    *   Example output: `ssh://root@<INSTANCE_IP_ADDRESS>:<SSH_PORT>`
    *   **Note:** Using the direct SSH URL (like the example above) is recommended over `vastai ssh` or proxy connections for stability and easier file transfers with `scp`.
3.  **Connect:** Use the retrieved details (e.g., `ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS>`) to connect to your instance via SSH.

## 3. Prepare Local Project Files & Upload

Before running any setup on the remote instance, prepare and upload your project files.

1.  **Prepare Local Files:**
    *   Ensure your local `VideoDiffusion` directory contains the necessary scripts (`setup.sh`, `download_weights.sh`, `test_single_chunk.sh`, `realtime_magi_stream.py`), the `MAGI-1` subdirectory (with `requirements.txt`, `inference/`, `example/`), configuration (`prompts.json`), etc.
    *   **Crucially, modify scripts (`setup.sh`, etc.) to remove any Conda commands** (`conda activate`, `conda run`). They must use the base Python environment.
2.  **Upload to Instance:** Copy the entire prepared `VideoDiffusion` directory to `/root/` on the remote instance using `scp`.
    *   **Command (run locally):**
        ```bash
        # Replace <SSH_PORT>, <INSTANCE_IP_ADDRESS>, and /path/to/your/local/... with your details
        scp -P <SSH_PORT> -r /path/to/your/local/VideoDiffusion root@<INSTANCE_IP_ADDRESS>:/root/
        ```
    *   **Verify:** SSH in and check `/root/VideoDiffusion` exists and contains your files:
        ```bash
        ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'ls -l /root/VideoDiffusion'
        ```

## 4. Pre-Patch `MagiAttention` Setup Script

**CRITICAL PRE-REQUISITE:** Before running the main `setup.sh` script, you must manually patch the `setup.py` file within the `MagiAttention` codebase that will be cloned.

*   **Problem:** The default `MagiAttention/setup.py` attempts to download its own `nvcc` (CUDA compiler) if the system CUDA version isn't exactly 12.8. This mechanism fails in the Vast.ai environment.
*   **Solution:** Force the build to use the system `nvcc` by disabling the download logic:
    1.  **Run Initial Setup Steps (Partial):** Execute the beginning of your `setup.sh` script on the remote instance *only up to the point where it clones the `MagiAttention` repository*. Alternatively, manually clone it: `ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'cd /root/VideoDiffusion && git clone https://github.com/SandAI-org/MagiAttention.git MAGI-1/MagiAttention'`
    2.  **Copy `setup.py` Locally:** `scp -P <SSH_PORT> root@<INSTANCE_IP_ADDRESS>:/root/VideoDiffusion/MAGI-1/MagiAttention/setup.py /path/to/your/local/VideoDiffusion/setup_magiattention.py` (Replace local path)
    3.  **Edit Locally:** Open the local copy (`setup_magiattention.py`) and wrap the CUDA/NVCC download logic block (approx. lines 370-401) inside an `if False:` statement.
        ```python
        # Example structure after editing:
        if False:
            # Original download logic block here...
            # ... download nvcc ...
            # ... set PATH ...
        ```
    4.  **Upload Patched `setup.py`:** `scp -P <SSH_PORT> /path/to/your/local/VideoDiffusion/setup_magiattention.py root@<INSTANCE_IP_ADDRESS>:/root/VideoDiffusion/MAGI-1/MagiAttention/setup.py` (Replace local path)

## 5. Environment Setup (`setup.sh`)

Now that `MagiAttention/setup.py` is pre-patched, run the main `setup.sh` script on the remote instance.

**Key Steps & Solutions (Incorporated in `setup.sh`):**

1.  **System Packages:** Use `apt` to install `git`, `git-lfs`, `ffmpeg`, etc.
2.  **Git LFS Init:** Run `git lfs install`.
3.  **PyTorch First:** Install `torch`, `torchvision`, `torchaudio` via `pip` *before* other requirements:
    ```bash
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
    ```
4.  **Install Requirements:** Install from `MAGI-1/requirements.txt` using `pip`. Ensure `flashinfer-python` is commented out or removed from the file first due to installation issues.
5.  **`MagiAttention` Installation:** Inside the `/root/VideoDiffusion/MAGI-1/MagiAttention` directory (which should already exist and contain the patched `setup.py`), run:
    ```bash
    git submodule update --init --recursive # Initialize submodules
pip install --no-build-isolation .      # Install with patched setup
    ```
6.  **Other Dependencies:** Install any final dependencies (e.g., `pip install flask flask_cors pillow opencv-python-headless`).

**Running the Full Setup Script:**

```bash
ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'cd /root/VideoDiffusion && bash ./setup.sh'
```

*(Monitor output closely. If it succeeds, the environment should be ready. If errors occur, refer to the detailed troubleshooting steps in Section 10.)*

## 6. Download Weights (`download_weights.sh`)

Run the `download_weights.sh` script to fetch the model weights. The final version of this script uses `huggingface-cli download` for reliability.

**Key Challenges & Solutions:**

*   **Initial `git lfs pull` Failures:** Attempts to use `git lfs pull` failed to download the main model and VAE weights, likely due to missing LFS files in the include patterns or silent authentication failures with Hugging Face LFS.
*   **Incorrect Paths:** Early attempts used incorrect paths based on assumptions or outdated information (`./downloads/...`, `./checkpoints/...`).
*   **Final Solution (`huggingface-cli`):**
    *   The script was rewritten to use `huggingface-cli download` for all components.
    *   A web search confirmed the correct paths within the `sand-ai/MAGI-1` repo:
        *   Main Model (FP8 Quant): `ckpt/magi/24B_distill_quant/`
        *   VAE: `ckpt/vae/`
        *   T5: Downloaded from `DeepFloyd/t5-v1_1-xxl` (as the one in `sand-ai/MAGI-1` might be incomplete or differ).
    *   The script downloads these into corresponding relative paths *within* the `/root/VideoDiffusion/MAGI-1/` directory (e.g., `/root/VideoDiffusion/MAGI-1/ckpt/magi/24B_distill_quant/`).

**Running the Download Script:**

```bash
ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'cd /root/VideoDiffusion && bash ./download_weights.sh'
```

*   **Note:** This may take significant time.
*   **Authentication:** If downloads fail with authentication errors, you may need to run `huggingface-cli login` interactively within the instance first.
*   **Verification:** After completion, check that the target directories exist and contain files:
    ```bash
    ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'ls -l /root/VideoDiffusion/MAGI-1/ckpt/magi/24B_distill_quant/'
    ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'ls -l /root/VideoDiffusion/MAGI-1/ckpt/vae/'
    ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'ls -l /root/VideoDiffusion/MAGI-1/t5/'
    ```

## 7. Model Configuration (`24B_config.json`)

After downloading the weights, ensure the model configuration file points to the correct locations.

**File:** `/root/VideoDiffusion/MAGI-1/example/24B/24B_config.json`

**Key Paths to Verify/Correct:**

*   `runtime_config.load`: Should point to the main model weights. Needs to be: `./ckpt/magi/24B_distill_quant`
*   `runtime_config.vae_pretrained`: Should point to the VAE weights. Needs to be: `./ckpt/vae`
*   `runtime_config.t5_pretrained`: Should point to the T5 weights. Needs to be: `./t5`

**Challenge & Solution (Read-Only Filesystem):**

*   **Problem:** Attempts to edit `/root/VideoDiffusion/MAGI-1/example/24B/24B_config.json` directly on the Vast.ai instance failed with `EROFS: read-only file system`. This indicates parts of the mounted filesystem (potentially including the cloned repo) are not directly writable.
*   **Workaround:** Modify the configuration file locally and upload the corrected version:
    1.  **Copy Remote to Local:** `scp -P <SSH_PORT> root@<INSTANCE_IP_ADDRESS>:/root/VideoDiffusion/MAGI-1/example/24B/24B_config.json /path/to/local/VideoDiffusion/MAGI-1/example/24B/` (Replace local path)
    2.  **Edit Locally:** Open the local copy and ensure the `load`, `vae_pretrained`, and `t5_pretrained` paths under `runtime_config` are set correctly as listed above.
    3.  **Upload Local to Remote:** `scp -P <SSH_PORT> /path/to/local/VideoDiffusion/MAGI-1/example/24B/24B_config.json root@<INSTANCE_IP_ADDRESS>:/root/VideoDiffusion/MAGI-1/example/24B/` (Replace local path)

**Verification:** Check the remote file contains the correct paths:
```bash
ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'grep -E "load|vae_pretrained" /root/VideoDiffusion/MAGI-1/example/24B/24B_config.json'
# Expected output should show:
#         "load": "./ckpt/magi/24B_distill_quant",
#         "vae_pretrained": "./ckpt/vae",
```

## 8. Run Functional Test (`test_single_chunk.sh`)

With the environment set up, weights downloaded, and configuration corrected, run the provided functional test script to verify basic operation.

**Script:** `/root/VideoDiffusion/test_single_chunk.sh`

**Running the Test:**

```bash
ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'cd /root/VideoDiffusion && bash ./test_single_chunk.sh' | cat
```

**Expected Outcome:** The script should execute without Python tracebacks or assertion errors. It will likely print model loading information and progress updates, eventually saving a sample output video.

**Verification:** After successful execution, check for the output video file:
```bash
ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'ls -l /root/VideoDiffusion/MAGI-1/smoke_test.mp4'
```

**Troubleshooting Test Failures:**

During the initial setup documented in this log, several errors were encountered when first running this test script. These issues (and their solutions) are detailed in Section 12 under "Problem: Functional Test (`test_single_chunk.sh`) Failures". Key issues fixed included:
*   `ModuleNotFoundError: No module named 'magi_attention.lib'` (fixed by commenting out an unused import in `dit_module.py`).
*   `error: unrecognized arguments: --num_frames 24` (fixed by removing the argument from `test_single_chunk.sh`).
*   T5 loading errors (`OSError`, `TypeError`, `SyntaxError`) related to incorrect paths, missing `hf_token`, and regex errors (fixed by correcting `download_weights.sh`, `24B_config.json`, `t5_model.py`, and the calling script).
*   `AssertionError: os.path.exists(inference_weight_dir)` related to incorrect main model weight paths (fixed by correcting `download_weights.sh` and `24B_config.json`).

If the test fails, carefully examine the error message and compare it to the issues documented in Section 12.

## 9. Run Real-time Server (`realtime_magi_stream.py`)

Once the functional test passes, you can start the main real-time streaming application.

**Script:** `/root/VideoDiffusion/realtime_magi_stream.py`

**Running the Server:**

It's recommended to run the server in the background using `nohup` and redirect output to a log file.

```bash
ssh -p <SSH_PORT> root@<INSTANCE_IP_ADDRESS> 'cd /root/VideoDiffusion && nohup python realtime_magi_stream.py > server.log 2>&1 &'
```

*   The `&` at the end runs the command in the background.
*   `nohup` ensures the process continues even if you disconnect your SSH session.
*   Output (stdout and stderr) is redirected to `server.log` in the `/root/VideoDiffusion` directory.

**Accessing the Server:**

You will need to access the server running on the port you configured (e.g., port 8000) from your local machine. Common methods include:
*   **SSH Tunneling:** Create an SSH tunnel to forward the remote port to your local machine.
    ```bash
    # Example: Forward remote port 8000 to local port 8000
    ssh -p <SSH_PORT> -L 8000:localhost:8000 root@<INSTANCE_IP_ADDRESS>
    ```
    Then access `http://localhost:8000` in your local browser.
*   **Direct Access (If instance firewall allows):** If the instance firewall is configured to allow incoming connections on port 8000, you might be able to access it directly via `http://<INSTANCE_IP_ADDRESS>:8000`.

## 10. Troubleshooting Guide

This section details specific errors encountered during setup and their resolutions.

**(Setup Script Issues)**

*   **Problem:** `conda: command not found`
    *   **Symptom:** Initial `setup.sh` fails immediately.
    *   **Investigation:** The selected Docker image (`vastai/pytorch:2.6.0-cuda-12.4.1`) does not include Conda.
    *   **Solution:** Modify all scripts (`setup.sh`, `download_weights.sh`, etc.) to remove Conda commands (`conda activate`, `conda run`) and use the base Python 3.10 environment with `apt` and `pip`.

*   **Problem:** `flash-attn` (or similar) build fails with `ModuleNotFoundError: No module named 'torch'` during `pip install -r requirements.txt`.
    *   **Symptom:** `setup.sh` fails during the main requirements installation.
    *   **Investigation:** Build dependencies require PyTorch to be present in the environment *before* they are installed.
    *   **Solution:** Add an explicit `pip install torch torchvision torchaudio --index-url ...` command in `setup.sh` *before* the `pip install -r requirements.txt` line.

*   **Problem:** `Could not find a version that satisfies the requirement flashinfer-python==X.Y.Z`
