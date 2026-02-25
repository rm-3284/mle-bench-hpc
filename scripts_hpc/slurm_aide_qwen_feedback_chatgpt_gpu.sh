#!/bin/bash
#SBATCH --job-name=aide-qwen-chatgpt-cpu
#SBATCH --output=logs/aide-qwen-chatgpt-cpu-%j.out
#SBATCH --error=logs/aide-qwen-chatgpt-cpu-%j.err
#SBATCH --nodes=1
#SBATCH --partition=ailab
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --gres=gpu:1
#SBATCH --time=24:00:00

# =============================================================================
# CPU AIDE Agent with Qwen vLLM via SSH tunnel + OpenAI feedback
# =============================================================================
# This script runs the AIDE agent on a CPU node, creates an SSH tunnel to the
# Qwen vLLM server node, and uses OpenAI for feedback.
# =============================================================================
set -eo pipefail
module load proxy/default
export XDG_CACHE_HOME=/scratch/gpfs/KARTHIKN/rm4411/cache

# Proxy bypass list will be set after node hostnames are resolved
# (See below after Grading Server Setup section)

# =============================================================================
# Configuration
# =============================================================================
COMPETITION="${1:-spaceship-titanic}"
VLLM_JOB_ID="${2:-}"  # Optional: Job ID of running vLLM server
MODEL_SIZE="${3:-30b}"  # 30b or 80b
GRADING_SERVER_ARG="${4:-}"
QWEN_NODE_ARG="${5:-}"
FEEDBACK_MODEL="${6:-gpt-4o-mini}"
FEEDBACK_API_BASE="${7:-https://api.openai.com/v1}"
AIDE_PROVIDER="${AIDE_PROVIDER:-}"
AIDE_CODE_PROVIDER="${AIDE_CODE_PROVIDER:-vllm}"
AIDE_FEEDBACK_PROVIDER="${AIDE_FEEDBACK_PROVIDER:-openai}"

# Paths
MLEBENCH_DIR="$(pwd)"
DATA_DIR="/scratch/gpfs/KARTHIKN/rm4411/mle-cache/data"
SIF_IMAGE="${MLEBENCH_DIR}/containers/aide-qwen-minimal.sif"
OUTPUT_BASE="${MLEBENCH_DIR}/runs"
DOTENV_FILE="${MLEBENCH_DIR}/.env"

# Agent configuration
TIME_LIMIT_SECS=21600  # 6 hours
STEP_LIMIT=500

# vLLM server configuration

# Use different local port for agent to avoid conflicts
if [ "$MODEL_SIZE" == "30b" ]; then
    VLLM_PORT=8000
    AGENT_LOCAL_PORT=18000
    MODEL_NAME="qwen3-30b"
else
    VLLM_PORT=8001
    AGENT_LOCAL_PORT=18001
    MODEL_NAME="qwen3-80b"
fi

AIDE_CODE_MODEL="${AIDE_CODE_MODEL:-${MODEL_NAME}}"

VLLM_API_BASE="http://localhost:${AGENT_LOCAL_PORT}/v1"


# Output directory with run-group structure
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S-UTC")
RUN_GROUP_DIR="${OUTPUT_BASE}/${TIMESTAMP}_run-group_aide"
RUN_ID="${SLURM_JOB_ID}"
OUTPUT_DIR="${RUN_GROUP_DIR}/${COMPETITION}_${RUN_ID}"
mkdir -p "${OUTPUT_DIR}"/{submission,logs,code,workspaces}

# Create a dedicated tmp and cache directory for container temp files and Apptainer cache
HOST_TMPDIR="/scratch/gpfs/KARTHIKN/rm4411/tmp"
HOST_CACHEDIR="/scratch/gpfs/KARTHIKN/rm4411/cache"
mkdir -p "$HOST_TMPDIR"
mkdir -p "$HOST_CACHEDIR"

# Set Apptainer cache and tmp to large scratch locations (best practice for HPC)
export APPTAINER_CACHEDIR="$HOST_CACHEDIR"
export APPTAINER_TMPDIR="$HOST_TMPDIR"
export XDG_CACHE_HOME="$HOST_CACHEDIR"
export TMPDIR="$HOST_TMPDIR"

# =============================================================================
# Load .env if present
# =============================================================================
if [ -f "$DOTENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$DOTENV_FILE"
    set +a
fi

# Bind .env into container if present (cleanenv clears host env)
ENV_BIND=""
if [ -f "$DOTENV_FILE" ]; then
    ENV_BIND="--bind ${DOTENV_FILE}:/home/agent/.env:ro"
fi

# =============================================================================
# Resolve Qwen node hostname
# =============================================================================
QWEN_NODE="$QWEN_NODE_ARG"
if [ -z "$QWEN_NODE" ] && [ -n "$VLLM_JOB_ID" ]; then
    QWEN_NODE=$(squeue -j "$VLLM_JOB_ID" -h -o "%N" 2>/dev/null || true)
fi

if [ -z "$QWEN_NODE" ] || [ "$QWEN_NODE" = "(None)" ]; then
    echo "ERROR: Qwen node hostname not found."
    echo "Provide it as arg 5 or pass a valid vLLM job ID as arg 2."
    exit 1
fi

# =============================================================================
# Display Configuration
# =============================================================================
echo "=============================================="
echo "CPU AIDE Agent with Qwen vLLM + OpenAI feedback"
echo "=============================================="
echo "Job ID:          $SLURM_JOB_ID"
echo "Node:            $SLURM_NODELIST"
echo "Competition:     $COMPETITION"
echo "Code Model:      $AIDE_CODE_MODEL"
echo "Feedback Model:  $FEEDBACK_MODEL"
echo "Qwen Node:       $QWEN_NODE"
echo "vLLM Endpoint:   $VLLM_API_BASE"
echo "OpenAI Endpoint: $FEEDBACK_API_BASE"
echo "Provider Override: ${AIDE_PROVIDER:-auto}"
echo "Code Provider:   ${AIDE_CODE_PROVIDER}"
echo "Feedback Provider: ${AIDE_FEEDBACK_PROVIDER}"
echo "Run Group:       $RUN_GROUP_DIR"
echo "Output Dir:      $OUTPUT_DIR"
echo "Time Limit:      $TIME_LIMIT_SECS seconds"
echo "Step Limit:      $STEP_LIMIT steps"
echo "=============================================="

METADATA_FILE="${OUTPUT_DIR}/logs/run_metadata.txt"
cat > "$METADATA_FILE" << EOF
timestamp_utc=${TIMESTAMP}
slurm_job_id=${SLURM_JOB_ID}
competition=${COMPETITION}
model_size=${MODEL_SIZE}
code_model=${AIDE_CODE_MODEL}
feedback_model=${FEEDBACK_MODEL}
vllm_job_id=${VLLM_JOB_ID}
qwen_node=${QWEN_NODE}
vllm_api_base=${VLLM_API_BASE}
grading_server=${GRADING_SERVER}
grading_job_id=${GRADING_JOB_ID}
feedback_api_base=${FEEDBACK_API_BASE}
provider_override=${AIDE_PROVIDER}
code_provider=${AIDE_CODE_PROVIDER}
feedback_provider=${AIDE_FEEDBACK_PROVIDER}
EOF

# =============================================================================
# Check container exists
# =============================================================================
if [ ! -f "$SIF_IMAGE" ]; then
    echo "ERROR: AIDE container not found at $SIF_IMAGE"
    echo "Please build it first with:"
    echo "  cd containers && apptainer build aide-qwen.sif aide-qwen.def"
    exit 1
fi

# =============================================================================
# Grading Server Setup
# =============================================================================
if [[ "$GRADING_SERVER_ARG" == auto:* ]]; then
    GRADING_JOB_ID="${GRADING_SERVER_ARG#auto:}"
    ADDR_FILE="$HOME/.mlebench_addresses/grading_server_${GRADING_JOB_ID}"
    if [ ! -f "$ADDR_FILE" ]; then
        echo "ERROR: Address file not found: $ADDR_FILE"
        echo "Make sure grading server job $GRADING_JOB_ID is running"
        exit 1
    fi
    GRADING_SERVER=$(<"$ADDR_FILE")
elif [ -n "$GRADING_SERVER_ARG" ]; then
    GRADING_SERVER="$GRADING_SERVER_ARG"
else
    echo "WARNING: No grading server specified. Using localhost:5000"
    GRADING_SERVER="http://localhost:5000"
fi

echo "Grading Server: $GRADING_SERVER"

# =============================================================================
# Setup dynamic proxy bypass list
# =============================================================================
# Extract hostname from GRADING_SERVER (remove protocol and port)
GRADING_HOST=$(echo "$GRADING_SERVER" | sed 's|^https\?://||' | cut -d: -f1)

# Build no_proxy list with actual node hostnames to avoid proxy for internal connections
# Include: localhost, 127.0.0.1, Qwen node, grading server node
export no_proxy="localhost,127.0.0.1,${QWEN_NODE},${GRADING_HOST}"
export NO_PROXY="$no_proxy"  # Some tools use uppercase
export AIDE_LOG_LEVEL="DEBUG"

echo "Proxy bypass list (no_proxy): $no_proxy"

# =============================================================================
# Port utility functions
# =============================================================================
is_port_in_use() {
    local port=$1
    nc -z 127.0.0.1 "$port" 2>/dev/null && return 0 || return 1
}

cleanup_port() {
    local port=$1
    if is_port_in_use "$port"; then
        echo "⚠ Port $port is already in use. Attempting cleanup..."
        # Try fuser (most reliable)
        if command -v fuser &> /dev/null; then
            fuser -k "${port}/tcp" 2>/dev/null || true
            sleep 1
        fi
        # Verify it's freed
        if is_port_in_use "$port"; then
            echo "  ✗ Failed to free port $port"
            return 1
        fi
        echo "  ✓ Port $port freed"
    fi
    return 0
}

# =============================================================================
# Create SSH tunnel to Qwen vLLM server
# =============================================================================
echo ""

echo "Checking for port conflicts..."
if ! cleanup_port "$AGENT_LOCAL_PORT"; then
    echo "ERROR: Cannot free port $AGENT_LOCAL_PORT"
    exit 1
fi

echo "Creating SSH tunnel to ${QWEN_NODE}:${VLLM_PORT} (local port ${AGENT_LOCAL_PORT})..."
ssh -N -L "${AGENT_LOCAL_PORT}:localhost:${VLLM_PORT}" "${QWEN_NODE}" &
TUNNEL_PID=$!

# Enhanced trap function to clean up tunnel and ports
cleanup_tunnel() {
    if [ -n "$TUNNEL_PID" ]; then
        echo "Terminating SSH tunnel (PID $TUNNEL_PID)..."
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
}
trap cleanup_tunnel EXIT

# Give SSH tunnel time to establish
sleep 2

# Verify tunnel is alive
if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "✗ SSH tunnel process died immediately. Checking SSH connectivity..."
    echo "Run this manually to debug: ssh -v -N -L ${AGENT_LOCAL_PORT}:localhost:${VLLM_PORT} ${QWEN_NODE}"
    exit 1
fi
echo "✓ SSH tunnel established (PID $TUNNEL_PID)"

# =============================================================================
# Diagnostic tunnel tests
# =============================================================================
echo ""
echo "Running tunnel diagnostics..."

echo "Test 1: Port listening check..."
        if nc -z 127.0.0.1 $AGENT_LOCAL_PORT 2>/dev/null; then
            echo "    ✓ Port $AGENT_LOCAL_PORT is listening on localhost"
        else
            echo "    ✗ Port $AGENT_LOCAL_PORT NOT listening on localhost"
            echo "    (This may be normal if vLLM server is not yet started; continuing to retry...)"
        fi
echo "Test 2: Netstat check..."
        netstat -tlnp 2>/dev/null | grep -E ":$AGENT_LOCAL_PORT|LISTEN" | head -5 || true
echo "Test 3: First curl attempt (verbose, 5 second timeout)..."
        CURL_OUTPUT=$(timeout 5 curl -v http://localhost:${AGENT_LOCAL_PORT}/v1/models 2>&1 | head -20 || true)
        echo "$CURL_OUTPUT"
        if echo "$CURL_OUTPUT" | grep -q 'Failed to connect'; then
                echo "    ✗ Curl failed to connect"
        else
                echo "    ✓ Curl succeeded"
    fi
    echo "$CURL_OUTPUT" | sed 's/^/      /'

# Test 4: Check tunnel process still alive
echo "  Test 4: Tunnel process status..."
if ps -p $TUNNEL_PID > /dev/null; then
    echo "    ✓ SSH tunnel process still running (PID $TUNNEL_PID)"
else
    echo "    ✗ SSH tunnel process has died!"
    exit 1
fi

echo ""

# =============================================================================
# Wait for vLLM server to be reachable
# =============================================================================
echo "Waiting for vLLM server at $VLLM_API_BASE..."
MAX_RETRIES=120  # doubled from 60 (10 minutes instead of 5)
LAST_ERROR=""
for i in $(seq 1 $MAX_RETRIES); do
    CURL_RESULT=$(curl -s -f "${VLLM_API_BASE}/models" 2>&1)
    CURL_EXIT=$?
    if [ $CURL_EXIT -eq 0 ]; then
        echo "✓ vLLM server is reachable"
        break
    fi
    LAST_ERROR=$(echo "$CURL_RESULT" | head -1)
    SLEEP_SECS=5
    sleep $SLEEP_SECS
    if [ $i -eq $MAX_RETRIES ]; then
        echo "✗ vLLM server not reachable after $((MAX_RETRIES * SLEEP_SECS)) seconds"
        echo ""
        echo "Last error (curl exit code $CURL_EXIT):"
        echo "  $LAST_ERROR"
        echo "Terminating tunnel and exiting."
        cleanup_tunnel
        exit 1
    fi
    if [ $((i % 4)) -eq 0 ]; then
        # Show diagnostic every ~20 seconds (4 * 5 = 20 seconds)
        ELAPSED=$((i * SLEEP_SECS))
        PROGRESS=$((i * 100 / MAX_RETRIES))
        echo "  [${PROGRESS}%] still waiting... ($ELAPSED/${MAX_RETRIES * SLEEP_SECS}s) - last error: $LAST_ERROR"
        # Also check tunnel is still alive
        if ! ps -p $TUNNEL_PID > /dev/null 2>&1; then
            echo "    ✗ WARNING: SSH tunnel process died!"
        fi
    fi
done

# =============================================================================
# Prepare overlay files
# =============================================================================
echo ""
echo "Preparing configuration overlays..."
OVERLAY_DIR="${OUTPUT_DIR}/overlay"
mkdir -p "${OVERLAY_DIR}"

# Install a sitecustomize hook to raise AIDE logging without modifying the package
PYHOOK_DIR="${OVERLAY_DIR}/pyhook"
mkdir -p "${PYHOOK_DIR}"
cat > "${PYHOOK_DIR}/sitecustomize.py" << 'PY'
import logging
import os

level_name = os.getenv("AIDE_LOG_LEVEL", "INFO").upper()
level = getattr(logging, level_name, logging.INFO)

# Raise both root and AIDE logger levels
logging.getLogger().setLevel(level)
logging.getLogger("aide").setLevel(level)
PY

# Ensure Python loads sitecustomize from the injected directory
export PYTHONPATH="/home/agent/pyhook${PYTHONPATH:+:${PYTHONPATH}}"

# Extract and modify files for grading server URL
cp "${MLEBENCH_DIR}/environment/instructions.txt" "${OVERLAY_DIR}/instructions.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/instructions.txt"

cp "${MLEBENCH_DIR}/environment/instructions_obfuscated.txt" "${OVERLAY_DIR}/instructions_obfuscated.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/instructions_obfuscated.txt"

cp "${MLEBENCH_DIR}/environment/validate_submission.sh" "${OVERLAY_DIR}/validate_submission.sh"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/validate_submission.sh"
chmod +x "${OVERLAY_DIR}/validate_submission.sh"

cp "${MLEBENCH_DIR}/agents/aide/additional_notes.txt" "${OVERLAY_DIR}/additional_notes.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/additional_notes.txt"

echo "Overlay files prepared in: ${OVERLAY_DIR}"

# =============================================================================
# Final connectivity test before launching container
# =============================================================================
echo ""
echo "Final connectivity test (from host)..."
echo "  Testing: curl -s -f ${VLLM_API_BASE}/models"

CURL_OUTPUT=$(curl -s -f -v "${VLLM_API_BASE}/models" 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -eq 0 ]; then
    echo "  ✓ Success! vLLM responding from host"
    echo "    Response: $(echo "$CURL_OUTPUT" | head -c 80)..."
else
    echo "  ✗ Failed on host with curl exit code: $CURL_EXIT"
    if [ $CURL_EXIT -eq 7 ]; then
        echo "    Error: Connection refused (port not open or service not responding)"
    elif [ $CURL_EXIT -eq 28 ]; then
        echo "    Error: Operation timeout"
    fi
    echo "    Full curl output:"
    echo "$CURL_OUTPUT" | head -20 | sed 's/^/      /'
    echo ""
    echo "  Tunnel status:"
    if ps -p $TUNNEL_PID > /dev/null 2>&1; then
        echo "    ✓ SSH tunnel still running (PID $TUNNEL_PID)"
    else
        echo "    ✗ SSH tunnel has died!"
    fi
    echo ""
    echo "  This test runs on the HOST. If it fails on the host,"
    echo "  the container will definitely fail too."
fi

# =============================================================================
# Run AIDE Agent (CPU)
# =============================================================================
echo ""
echo "Starting AIDE agent..."
echo ""
echo "=== Matplotlib cache directory diagnostics ==="
apptainer exec \
    --contain \
    --cleanenv \
    --writable-tmpfs \
    --env XDG_CACHE_HOME="$HOST_CACHEDIR" \
    --env TMPDIR="$HOST_TMPDIR" \
    --env APPTAINER_CACHEDIR="$HOST_CACHEDIR" \
    --env APPTAINER_TMPDIR="$HOST_TMPDIR" \
    --bind "$HOST_TMPDIR:/tmp" \
    --bind "$HOST_CACHEDIR:/scratch/gpfs/KARTHIKN/rm4411/cache" \
    ${SIF_IMAGE} \
    bash -c "id; umask; ls -ld /scratch/gpfs/KARTHIKN/rm4411/cache/matplotlib; touch /scratch/gpfs/KARTHIKN/rm4411/cache/matplotlib/diagnostic_testfile && ls -l /scratch/gpfs/KARTHIKN/rm4411/cache/matplotlib/diagnostic_testfile"
# ===================== OSError Debugging + PyTorch Cache =====================
# Set TORCH_HOME to a unique per-job directory to avoid collisions
export TORCH_HOME=/scratch/gpfs/KARTHIKN/rm4411/cache/torch_job_${SLURM_JOB_ID}
mkdir -p "$TORCH_HOME"

# Clean up TORCH_HOME after job ends
cleanup_torch_home() {
    echo "Cleaning up TORCH_HOME: $TORCH_HOME"
    rm -rf "$TORCH_HOME"
}
trap cleanup_torch_home EXIT

echo "=== OSError Debugging Diagnostics (host) ==="
echo "--- Disk usage (df -h) ---"; df -h
echo "--- Inode usage (df -ih) ---"; df -ih
echo "--- Disk usage (du -sh $OUTPUT_DIR) ---"; du -sh "$OUTPUT_DIR"
echo "--- Disk usage (du -sh $TORCH_HOME) ---"; du -sh "$TORCH_HOME"
echo "--- Disk usage (du -sh /tmp) ---"; du -sh /tmp
echo "--- Quota (if available) ---"; (quota -s 2>/dev/null || echo "No quota command")
echo "--- Environment variables (selected) ---"; env | grep -E 'HOME|TMP|CACHE|USER|SLURM|PWD|TORCH_HOME'
echo "--- Host free (free -h) ---"; free -h || true

# Trap to print diagnostics on error/exit (runs before cleanup)
oserror_debug_trap() {
    echo "=== OSError Debugging Diagnostics (on EXIT) ==="
    echo "--- Disk usage (df -h) ---"; df -h
    echo "--- Inode usage (df -ih) ---"; df -ih
    echo "--- Disk usage (du -sh $OUTPUT_DIR) ---"; du -sh "$OUTPUT_DIR"
    echo "--- Disk usage (du -sh $TORCH_HOME) ---"; du -sh "$TORCH_HOME"
    echo "--- Disk usage (du -sh /tmp) ---"; du -sh /tmp
    echo "--- Quota (if available) ---"; (quota -s 2>/dev/null || echo "No quota command")
    echo "--- Environment variables (selected) ---"; env | grep -E 'HOME|TMP|CACHE|USER|SLURM|PWD|TORCH_HOME'
    echo "--- Host free (free -h) ---"; free -h || true
}
trap oserror_debug_trap EXIT
# Note: If the agent cannot access the internet, model download will fail with a connection error, not OSError 28. OSError 28 specifically means the target device is out of space or inodes.

# Clear conda environment variables
unset CONDA_EXE CONDA_PREFIX CONDA_PYTHON_EXE CONDA_DEFAULT_ENV CONDA_SHLVL

apptainer exec \
    --contain \
    --cleanenv \
    --writable-tmpfs \
    --nv \
    --env XDG_CACHE_HOME="$HOST_CACHEDIR" \
    --env TMPDIR="$HOST_TMPDIR" \
    --env APPTAINER_CACHEDIR="$HOST_CACHEDIR" \
    --env APPTAINER_TMPDIR="$HOST_TMPDIR" \
    --env COMPETITION_ID=${COMPETITION} \
    --env GRADING_SERVER=${GRADING_SERVER} \
    --env TIME_LIMIT_SECS=${TIME_LIMIT_SECS} \
    --env STEP_LIMIT=${STEP_LIMIT} \
    --env OPENAI_API_KEY="${OPENAI_API_KEY}" \
    --env AIDE_CODE_MODEL="${AIDE_CODE_MODEL}" \
    --env AIDE_CODE_API_BASE="${VLLM_API_BASE}" \
    --env AIDE_FEEDBACK_MODEL="${FEEDBACK_MODEL}" \
    --env AIDE_FEEDBACK_API_BASE="${FEEDBACK_API_BASE}" \
    --env AIDE_AGENT_STEPS="${STEP_LIMIT}" \
    --env AIDE_PROVIDER="${AIDE_PROVIDER}" \
    --env AIDE_CODE_PROVIDER="${AIDE_CODE_PROVIDER}" \
    --env AIDE_FEEDBACK_PROVIDER="${AIDE_FEEDBACK_PROVIDER}" \
    --env AIDE_LOG_LEVEL="INFO" \
    --env no_proxy="${no_proxy}" \
    --env NO_PROXY="${no_proxy}" \
    --env PYTHONPATH="${PYTHONPATH}" \
    --bind ${DATA_DIR}/${COMPETITION}/prepared/public:/home/data:ro \
    --bind ${OUTPUT_DIR}/submission:/home/submission \
    --bind ${OUTPUT_DIR}/logs:/home/logs \
    --bind ${OUTPUT_DIR}/code:/home/code \
    --bind ${OUTPUT_DIR}/workspaces:/home/agent/workspaces \
    --bind ${OVERLAY_DIR}/instructions.txt:/home/instructions.txt:ro \
    --bind ${OVERLAY_DIR}/instructions_obfuscated.txt:/home/instructions_obfuscated.txt:ro \
    --bind ${OVERLAY_DIR}/validate_submission.sh:/home/validate_submission.sh:ro \
    --bind ${OVERLAY_DIR}/additional_notes.txt:/home/agent/additional_notes.txt:ro \
    --bind ${PYHOOK_DIR}:/home/agent/pyhook:ro \
    --bind ${MLEBENCH_DIR}/scripts_hpc/aide_start_qwen.sh:/home/agent/start.sh:ro \
    --bind "$HOST_TMPDIR:/tmp" \
    --bind "$HOST_CACHEDIR:/scratch/gpfs/KARTHIKN/rm4411/cache" \
    ${ENV_BIND} \
    ${SIF_IMAGE} \
    bash /home/agent/start.sh

AGENT_EXIT_CODE=$?

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
echo "AIDE Agent finished"
echo "=============================================="
echo "Exit Code:   $AGENT_EXIT_CODE"
echo "Competition: $COMPETITION"
echo "Model:       $MODEL_NAME"
echo "Run Group:   $RUN_GROUP_DIR"
echo ""
echo "Results:"
echo "  Submission: ${OUTPUT_DIR}/submission/"
echo "  Logs:       ${OUTPUT_DIR}/logs/"
echo "  Code:       ${OUTPUT_DIR}/code/"
echo ""
echo "To grade:"
echo "  mlebench grade --submission ${OUTPUT_DIR}/submission/submission.csv --competition ${COMPETITION}"
echo "=============================================="

exit $AGENT_EXIT_CODE
