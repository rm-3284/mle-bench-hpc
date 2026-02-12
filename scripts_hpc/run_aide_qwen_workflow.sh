#!/bin/bash
# Complete workflow script for running AIDE with Qwen models on HPC
# This script handles the entire workflow: grading server + vLLM server + AIDE agent

set -e

COMPETITION="${1:-spaceship-titanic}"
MODEL_SIZE="${2:-30b}"  # 30b or 80b
PARTITION="${3:-gpu-short}"

if [ -z "$COMPETITION" ]; then
    echo "Usage: $0 <competition> [model_size] [partition]"
    echo ""
    echo "Arguments:"
    echo "  competition   - Competition ID (e.g., spaceship-titanic)"
    echo "  model_size    - Model size: 30b or 80b (default: 30b)"
    echo "  partition     - SLURM partition (default: gpu-short)"
    echo ""
    echo "Example:"
    echo "  $0 spaceship-titanic 30b gpu-short"
    exit 1
fi

echo "=============================================="
echo "AIDE + Qwen Workflow Setup"
echo "=============================================="
echo "Competition: $COMPETITION"
echo "Model:       Qwen3-${MODEL_SIZE}"
echo "Partition:   $PARTITION"
echo "=============================================="
echo ""

# =============================================================================
# Step 1: Start Grading Server
# =============================================================================
echo "Step 1: Starting grading server..."
GRADING_JOB=$(sbatch --parsable --partition=cpu scripts_hpc/slurm_grading_server.sh "$COMPETITION")
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
VLLM_JOB=$(sbatch --parsable --partition="$PARTITION" scripts_hpc/slurm_vllm_qwen${MODEL_SIZE}.sh)
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
# Step 3: Start AIDE Agent (on same node as vLLM)
# =============================================================================
echo "Step 3: Submitting AIDE agent job..."
echo "  AIDE will run on the same node as vLLM: $VLLM_NODE"

AIDE_JOB=$(sbatch --parsable \
    --partition="$PARTITION" \
    --nodelist="$VLLM_NODE" \
    scripts_hpc/slurm_aide_qwen.sh \
    "$COMPETITION" \
    "$VLLM_JOB" \
    "$MODEL_SIZE" \
    "auto:$GRADING_JOB")

echo "  AIDE agent job: $AIDE_JOB"
echo ""

# =============================================================================
# Step 4: Setup Auto-Cleanup (Optional)
# =============================================================================
# Uncomment the following section to automatically cancel grading/vLLM servers
# after the AIDE job completes (regardless of success/failure)

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
echo "  tail -f logs/aide-qwen-${AIDE_JOB}.out"
echo ""
echo "Job status:"
echo "  ./manage_qwen.sh slurm-status"
echo ""
echo "Cancel all jobs manually:"
echo "  scancel $GRADING_JOB $VLLM_JOB $AIDE_JOB"
echo ""
echo "Note: Servers will keep running after AIDE completes."
echo "      Uncomment Step 4 in this script for auto-cleanup."
echo ""
echo "The AIDE agent will start automatically once vLLM loads the model."
echo "This typically takes 15-20 minutes total."
echo "=============================================="
