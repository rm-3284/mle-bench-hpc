#!/bin/bash
#SBATCH --job-name=aide-qwen
#SBATCH --output=logs/aide-qwen-%j.out
#SBATCH --error=logs/aide-qwen-%j.err
#SBATCH --nodes=1
#SBATCH --partition=gpu-short
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:1
#SBATCH --mem=64G
#SBATCH --time=24:00:00

# =============================================================================
# AIDE Agent with Local Qwen vLLM Server
# =============================================================================
# This script runs AIDE agent using a local vLLM server for Qwen models.
# It assumes a vLLM server is already running on the same node.
# =============================================================================

set -eo pipefail

# =============================================================================
# Configuration
# =============================================================================
COMPETITION="${1:-spaceship-titanic}"
VLLM_JOB_ID="${2:-}"  # Optional: Job ID of running vLLM server
MODEL_SIZE="${3:-30b}"  # 30b or 80b

# Paths
MLEBENCH_DIR="$(pwd)"
DATA_DIR="${MLEBENCH_DIR}/data"
SIF_IMAGE="${MLEBENCH_DIR}/containers/aide-qwen-minimal.sif"
OUTPUT_BASE="${MLEBENCH_DIR}/runs"
GRADING_SERVER_ARG="${4:-}"

# Agent configuration
TIME_LIMIT_SECS=14000
STEP_LIMIT=500

# vLLM server configuration
if [ "$MODEL_SIZE" == "30b" ]; then
    VLLM_PORT=8000
    MODEL_NAME="qwen3-30b"
else
    VLLM_PORT=8001
    MODEL_NAME="qwen3-80b"
fi

VLLM_API_BASE="http://localhost:${VLLM_PORT}/v1"

# Output directory with run-group structure
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S-UTC")
RUN_GROUP_DIR="${OUTPUT_BASE}/${TIMESTAMP}_run-group_aide"
RUN_ID="${SLURM_JOB_ID}"
OUTPUT_DIR="${RUN_GROUP_DIR}/${COMPETITION}_${RUN_ID}"
mkdir -p "${OUTPUT_DIR}"/{submission,logs,code,workspaces}

# =============================================================================
# Display Configuration
# =============================================================================
echo "=============================================="
echo "AIDE Agent with Local Qwen vLLM"
echo "=============================================="
echo "Job ID:         $SLURM_JOB_ID"
echo "Node:           $SLURM_NODELIST"
echo "Competition:    $COMPETITION"
echo "Model:          $MODEL_NAME"
echo "vLLM Endpoint:  $VLLM_API_BASE"
echo "Run Group:      $RUN_GROUP_DIR"
echo "Output Dir:     $OUTPUT_DIR"
echo "Time Limit:     $TIME_LIMIT_SECS seconds"
echo "Step Limit:     $STEP_LIMIT steps"
echo "=============================================="

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
# Check vLLM server is running
# =============================================================================
echo ""
echo "Checking vLLM server at $VLLM_API_BASE..."
if curl -s -f "${VLLM_API_BASE}/models" > /dev/null 2>&1; then
    echo "✓ vLLM server is reachable"
    echo "Available models:"
    curl -s "${VLLM_API_BASE}/models" | python3 -c "import sys, json; data = json.load(sys.stdin); [print(f\"  - {m['id']}\") for m in data.get('data', [])]" 2>/dev/null || echo "  (Unable to parse)"
else
    echo "✗ Cannot reach vLLM server at ${VLLM_API_BASE}"
    echo ""
    echo "Make sure vLLM server is running on this node:"
    if [ -n "$VLLM_JOB_ID" ]; then
        echo "  Check job status: squeue -j $VLLM_JOB_ID"
    else
        echo "  Start server: sbatch scripts_hpc/slurm_vllm_qwen${MODEL_SIZE}.sh"
    fi
    exit 1
fi

# =============================================================================
# Prepare overlay files
# =============================================================================
echo ""
echo "Preparing configuration overlays..."
OVERLAY_DIR="${OUTPUT_DIR}/overlay"
mkdir -p "${OVERLAY_DIR}"

# Extract and modify files for grading server URL
apptainer exec ${SIF_IMAGE} cat /home/instructions.txt > "${OVERLAY_DIR}/instructions.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/instructions.txt"

apptainer exec ${SIF_IMAGE} cat /home/instructions_obfuscated.txt > "${OVERLAY_DIR}/instructions_obfuscated.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/instructions_obfuscated.txt"

apptainer exec ${SIF_IMAGE} cat /home/validate_submission.sh > "${OVERLAY_DIR}/validate_submission.sh"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/validate_submission.sh"
chmod +x "${OVERLAY_DIR}/validate_submission.sh"

apptainer exec ${SIF_IMAGE} cat /home/agent/additional_notes.txt > "${OVERLAY_DIR}/additional_notes.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/additional_notes.txt"

echo "Overlay files prepared in: ${OVERLAY_DIR}"

# =============================================================================
# Run AIDE Agent
# =============================================================================
echo ""
echo "Starting AIDE agent..."
echo ""

# Clear conda environment variables
unset CONDA_EXE CONDA_PREFIX CONDA_PYTHON_EXE CONDA_DEFAULT_ENV CONDA_SHLVL

apptainer exec --nv \
    --contain \
    --cleanenv \
    --writable-tmpfs \
    --env COMPETITION_ID=${COMPETITION} \
    --env GRADING_SERVER=${GRADING_SERVER} \
    --env TIME_LIMIT_SECS=${TIME_LIMIT_SECS} \
    --env STEP_LIMIT=${STEP_LIMIT} \
    --env OPENAI_API_KEY="dummy-key" \
    --env OPENAI_API_BASE="${VLLM_API_BASE}" \
    --bind ${DATA_DIR}/${COMPETITION}/prepared/public:/home/data:ro \
    --bind ${OUTPUT_DIR}/submission:/home/submission \
    --bind ${OUTPUT_DIR}/logs:/home/logs \
    --bind ${OUTPUT_DIR}/code:/home/code \
    --bind ${OUTPUT_DIR}/workspaces:/home/agent/workspaces \
    --bind ${OVERLAY_DIR}/instructions.txt:/home/instructions.txt:ro \
    --bind ${OVERLAY_DIR}/instructions_obfuscated.txt:/home/instructions_obfuscated.txt:ro \
    --bind ${OVERLAY_DIR}/validate_submission.sh:/home/validate_submission.sh:ro \
    --bind ${OVERLAY_DIR}/additional_notes.txt:/home/agent/additional_notes.txt:ro \
    ${SIF_IMAGE} \
    bash /home/agent/start.sh \
    agent.code.model=${MODEL_NAME} \
    agent.feedback.model=${MODEL_NAME} \
    agent.code.api_base=${VLLM_API_BASE} \
    agent.feedback.api_base=${VLLM_API_BASE} \
    agent.steps=${STEP_LIMIT} \
    agent.time_limit=${TIME_LIMIT_SECS} \
    data_dir=/home/data/ \
    desc_file=/home/agent/full_instructions.txt \
    exp_name=exp

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
