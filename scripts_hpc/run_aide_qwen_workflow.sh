#!/bin/bash
# Complete workflow script for running AIDE with Qwen models on HPC
# This script handles the entire workflow: grading server + vLLM server + AIDE agent

set -e

COMPETITION="${1:-spaceship-titanic}"
MODEL_SIZE="${2:-30b}"  # 30b or 80b
PARTITION="${3:-}"
AGENT_PARTITION="${4:-}"
CLEANUP_MODE="${5:-on}"

if [ -z "$COMPETITION" ]; then
    echo "Usage: $0 <competition> [model_size] [vllm_partition] [agent_partition] [cleanup]"
    echo ""
    echo "Arguments:"
    echo "  competition   - Competition ID (e.g., spaceship-titanic)"
    echo "  model_size    - Model size: 30b or 80b (default: 30b)"
    echo "  vllm_partition  - SLURM partition for vLLM (default: script default)"
    echo "  agent_partition - SLURM partition for AIDE agent (default: script default)"
    echo "  cleanup         - on|off to schedule cleanup job (default: on)"
    echo "                 Cleanup job cancels grading + vLLM after AIDE finishes"
    echo ""
    echo "Example:"
    echo "  $0 spaceship-titanic 30b gpu-short cpu on"
    exit 1
fi

if [ "${CLEANUP_MODE}" != "on" ] && [ "${CLEANUP_MODE}" != "off" ]; then
    echo "Error: cleanup must be 'on' or 'off'"
    exit 1
fi

echo "=============================================="
echo "AIDE + Qwen Workflow Setup"
echo "=============================================="
echo "Competition: $COMPETITION"
echo "Model:       Qwen3-${MODEL_SIZE}"
echo "vLLM Partition:  ${PARTITION:-script default}"
echo "Agent Partition: ${AGENT_PARTITION:-script default}"
echo "Cleanup:     ${CLEANUP_MODE}"
echo "=============================================="
echo ""

# =============================================================================
# Step 1: Start Grading Server
# =============================================================================
echo "Step 1: Starting grading server..."
GRADING_JOB=$(sbatch --parsable scripts_hpc/slurm_grading_server.sh "$COMPETITION")
echo "  Grading server job: $GRADING_JOB"
echo "  Waiting for grading server to start..."

# Wait for address file
ADDR_FILE="$HOME/.mlebench_addresses/grading_server_${GRADING_JOB}"
for i in {1..60}; do
    if [ -f "$ADDR_FILE" ]; then
        GRADING_URL=$(<"$ADDR_FILE")
        echo "  ✓ Grading server ready at: $GRADING_URL"
        break
    fi
    sleep 2
    if [ $i -eq 60 ]; then
        echo "  ✗ Timeout waiting for grading server"
        scancel $GRADING_JOB
        exit 1
    fi
done

# Wait for grading server to be responsive
echo "  Waiting for grading server to be responsive..."
for i in {1..30}; do
    if curl -s "${GRADING_URL}/health" > /dev/null 2>&1; then
        echo "  ✓ Grading server is responsive"
        break
    fi
    sleep 2
    if [ $i -eq 30 ]; then
        echo "  ✗ Grading server not responding"
        scancel $GRADING_JOB
        exit 1
    fi
done

echo ""

# =============================================================================
# Step 2: Start vLLM Server
# =============================================================================
echo "Step 2: Starting vLLM server for Qwen3-${MODEL_SIZE}..."
if [ -n "${PARTITION}" ]; then
    VLLM_JOB=$(sbatch --parsable --partition="${PARTITION}" scripts_hpc/slurm_vllm_qwen${MODEL_SIZE}.sh)
else
    VLLM_JOB=$(sbatch --parsable scripts_hpc/slurm_vllm_qwen${MODEL_SIZE}.sh)
fi
echo "  vLLM server job: $VLLM_JOB"
echo "  Waiting for vLLM server to start (this may take 5-10 minutes)..."

# Get the node where vLLM is running
sleep 10  # Wait a bit for job to start
VLLM_NODE=""
for i in {1..60}; do
    VLLM_NODE=$(squeue -j $VLLM_JOB -h -o "%N" 2>/dev/null || echo "")
    if [ -n "$VLLM_NODE" ] && [ "$VLLM_NODE" != "(None)" ]; then
        echo "  ✓ vLLM server running on node: $VLLM_NODE"
        break
    fi
    sleep 5
    if [ $i -eq 60 ]; then
        echo "  ✗ Timeout waiting for vLLM server to be assigned a node"
        scancel $GRADING_JOB $VLLM_JOB
        exit 1
    fi
done

echo "  Note: vLLM server is loading the model. This takes 5-15 minutes."
echo "  You can monitor progress with:"
echo "    tail -f logs/vllm-qwen${MODEL_SIZE}-${VLLM_JOB}.out"
echo ""

# Wait for vLLM server to be fully loaded and responsive
echo "  Waiting for vLLM model to load..."
if [ "$MODEL_SIZE" == "30b" ]; then
    VLLM_PORT=8000
else
    VLLM_PORT=8001
fi

VLLM_READY=false
for i in {1..180}; do  # Wait up to 15 minutes (180 × 5 sec)
    # Try to check vLLM health from the vLLM node
    if srun --jobid=$VLLM_JOB --nodes=1 --ntasks=1 --overlap \
        bash -c "curl -s -f http://localhost:${VLLM_PORT}/v1/models > /dev/null 2>&1" 2>/dev/null; then
        echo "  ✓ vLLM server is loaded and responding"
        VLLM_READY=true
        break
    fi
    
    # Check if job is still running
    if ! squeue -j $VLLM_JOB -h > /dev/null 2>&1; then
        echo "  ✗ vLLM job is no longer running"
        echo "  Check logs: logs/vllm-qwen${MODEL_SIZE}-${VLLM_JOB}.out"
        scancel $GRADING_JOB 2>/dev/null || true
        exit 1
    fi
    
    if [ $((i % 12)) -eq 0 ]; then  # Every minute
        echo "  Still waiting for vLLM to load... (${i}/180, ~$((i*5/60)) min elapsed)"
    fi
    sleep 5
done

if [ "$VLLM_READY" = false ]; then
    echo "  ✗ Timeout waiting for vLLM server to be ready"
    echo "  Check logs: logs/vllm-qwen${MODEL_SIZE}-${VLLM_JOB}.out"
    scancel $GRADING_JOB $VLLM_JOB
    exit 1
fi

echo ""

# =============================================================================
# Step 3: Start AIDE Agent (CPU with SSH tunnel)
# =============================================================================
echo "Step 3: Submitting AIDE agent job..."
echo "  AIDE will run on a CPU node and tunnel to vLLM node: $VLLM_NODE"

if [ -n "${AGENT_PARTITION}" ]; then
    AIDE_JOB=$(sbatch --parsable \
        --partition="${AGENT_PARTITION}" \
        scripts_hpc/slurm_aide_qwen_feedback_chatgpt_cpu.sh \
        "$COMPETITION" \
        "$VLLM_JOB" \
        "$MODEL_SIZE" \
        "auto:$GRADING_JOB")
else
    AIDE_JOB=$(sbatch --parsable \
        scripts_hpc/slurm_aide_qwen_feedback_chatgpt_cpu.sh \
        "$COMPETITION" \
        "$VLLM_JOB" \
        "$MODEL_SIZE" \
        "auto:$GRADING_JOB")
fi

echo "  AIDE agent job: $AIDE_JOB"
echo ""

# =============================================================================
# Step 4: Setup Auto-Cleanup (Optional)
# =============================================================================
# Uncomment the following section to automatically cancel grading/vLLM servers
# after the AIDE job completes (regardless of success/failure)

if [ "${CLEANUP_MODE}" = "on" ]; then
    echo "Step 4: Setting up automatic cleanup..."
    CLEANUP_JOB=$(sbatch --parsable \
        --dependency=afterany:$AIDE_JOB \
        --job-name=cleanup-aide-${AIDE_JOB} \
        --partition=cpu \
        --time=00:05:00 \
        --output=logs/cleanup-${AIDE_JOB}.out \
        --wrap="echo 'AIDE job $AIDE_JOB finished. Canceling supporting jobs...'; scancel $GRADING_JOB $VLLM_JOB; echo 'Cleanup complete.'")
    echo "  Cleanup job: $CLEANUP_JOB (will run after AIDE finishes)"
    echo ""
else
    echo "Step 4: Automatic cleanup disabled"
    echo ""
fi

# =============================================================================
# Summary
# =============================================================================
echo "=============================================="
echo "All jobs submitted successfully!"
echo "=============================================="
echo ""
echo "Job IDs:"
echo "  Grading Server: $GRADING_JOB"
echo "  vLLM Server:    $VLLM_JOB"
echo "  AIDE Agent:     $AIDE_JOB"
# if [ -n "${CLEANUP_JOB:-}" ]; then
#     echo "  Cleanup Job:    $CLEANUP_JOB (auto-cleanup enabled)"
# fi
echo ""
echo "Monitor jobs:"
echo "  squeue -u $USER"
echo ""
echo "Monitor logs:"
echo "  tail -f logs/vllm-qwen${MODEL_SIZE}-${VLLM_JOB}.out"
echo "  tail -f logs/aide-qwen-chatgpt-cpu-${AIDE_JOB}.out"
echo ""
echo "Job status:"
echo "  ./manage_qwen.sh slurm-status"
echo ""
echo "Cancel all jobs manually:"
echo "  scancel $GRADING_JOB $VLLM_JOB $AIDE_JOB"
echo ""
echo "Note: Servers will keep running after AIDE completes when cleanup is off."
echo ""
echo "The AIDE agent will start automatically once vLLM loads the model."
echo "This typically takes 15-20 minutes total."
echo "=============================================="
