#!/bin/bash
# Launch AIDE agent to connect to a pre-existing vLLM server
# This allows multiple AIDE runs against a single long-running vLLM server
# Usage: ./launch_aide_agent_only.sh <competition> [model_size] [vllm_job_id] [grading_job_id]

set -e

COMPETITION="${1:-}"
MODEL_SIZE="${2:-30b}"
VLLM_JOB_ID="${3:-}"
GRADING_JOB_ID="${4:-}"
PARTITION="${5:-gpu-short}"

if [ -z "$COMPETITION" ]; then
    echo "Usage: $0 <competition> [model_size] [vllm_job_id] [grading_job_id] [partition]"
    echo ""
    echo "Arguments:"
    echo "  competition    - Competition ID (e.g., spaceship-titanic)"
    echo "  model_size     - Model size: 30b or 80b (default: 30b)"
    echo "  vllm_job_id    - Job ID of running vLLM server (required for automatic node assignment)"
    echo "  grading_job_id - Job ID of grading server (optional, for cleanup)"
    echo "  partition      - SLURM partition for AIDE job (default: gpu-short)"
    echo ""
    echo "Example (with existing server):"
    echo "  $0 spaceship-titanic 30b 4665262 4665260"
    echo ""
    echo "Example (simple, finds vLLM node automatically):"
    echo "  $0 spaceship-titanic 30b 4665262"
    exit 1
fi

if [ "$MODEL_SIZE" != "30b" ] && [ "$MODEL_SIZE" != "80b" ]; then
    echo "Error: Model size must be 30b or 80b"
    exit 1
fi

echo "=============================================="
echo "AIDE Agent Launcher (Independent)"
echo "=============================================="
echo "Competition: $COMPETITION"
echo "Model:       Qwen3-${MODEL_SIZE}"
echo "vLLM Job:    ${VLLM_JOB_ID:-not specified}"
echo "Partition:   $PARTITION"
echo "=============================================="
echo ""

# Verify vLLM job is running if provided
if [ -n "$VLLM_JOB_ID" ]; then
    echo "Checking vLLM server status..."
    if ! squeue -j $VLLM_JOB_ID -h > /dev/null 2>&1; then
        echo "✗ Error: vLLM job $VLLM_JOB_ID is not running"
        echo "  Check with: squeue -j $VLLM_JOB_ID"
        exit 1
    fi
    echo "✓ vLLM job $VLLM_JOB_ID is running"
    
    # Get the node
    VLLM_NODE=$(squeue -j $VLLM_JOB_ID -h -o "%N" 2>/dev/null || echo "")
    if [ -z "$VLLM_NODE" ] || [ "$VLLM_NODE" = "(None)" ]; then
        echo "✗ Error: Could not determine node for vLLM job"
        exit 1
    fi
    echo "✓ vLLM running on node: $VLLM_NODE"
    
    # Verify vLLM is actually responding
    if [ "$MODEL_SIZE" == "30b" ]; then
        VLLM_PORT=8000
    else
        VLLM_PORT=8001
    fi
    
    echo "Verifying vLLM server is responding on port ${VLLM_PORT}..."
    if srun --jobid=$VLLM_JOB_ID --nodes=1 --ntasks=1 --overlap \
        bash -c "curl -s -f http://localhost:${VLLM_PORT}/v1/models > /dev/null 2>&1" 2>/dev/null; then
        echo "✓ vLLM server is responding"
    else
        echo "✗ Warning: vLLM server is not responding yet"
        echo "  It may still be loading. Try again in a few minutes."
        echo "  Monitor with: tail -f logs/vllm-qwen${MODEL_SIZE}-${VLLM_JOB_ID}.out"
        exit 1
    fi
else
    echo "Warning: No vLLM job ID provided. AIDE will need to find vLLM on same node."
    VLLM_NODE=""
fi

echo ""

# =============================================================================
# Submit AIDE Agent Job
# =============================================================================
echo "Submitting AIDE agent job..."
echo ""

# Build sbatch command
SBATCH_CMD="sbatch --parsable --partition=$PARTITION"

# If vLLM job and node are known, restrict to same node
if [ -n "$VLLM_NODE" ]; then
    SBATCH_CMD="$SBATCH_CMD --nodelist=$VLLM_NODE"
    echo "  AIDE will run on same node as vLLM: $VLLM_NODE"
fi

# Prepare grading server argument (for auto-cleanup)
if [ -n "$GRADING_JOB_ID" ]; then
    GRADING_ARG="auto:$GRADING_JOB_ID"
else
    GRADING_ARG=""
fi

# Submit the job
AIDE_JOB=$($SBATCH_CMD scripts_hpc/slurm_aide_qwen.sh "$COMPETITION" "$VLLM_JOB_ID" "$MODEL_SIZE" "$GRADING_ARG")

echo "  AIDE agent job submitted: $AIDE_JOB"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "=============================================="
echo "AIDE Job Submitted!"
echo "=============================================="
echo ""
echo "Job IDs:"
echo "  AIDE Agent:     $AIDE_JOB"
if [ -n "$VLLM_JOB_ID" ]; then
    echo "  vLLM Server:    $VLLM_JOB_ID"
fi
if [ -n "$GRADING_JOB_ID" ]; then
    echo "  Grading Server: $GRADING_JOB_ID"
fi
echo ""
echo "Monitor job status:"
echo "  squeue -j $AIDE_JOB"
echo ""
echo "Monitor logs:"
echo "  tail -f logs/aide-qwen-${AIDE_JOB}.out"
echo ""
echo "Full status check:"
echo "  ./manage_qwen.sh slurm-status"
echo ""
if [ -n "$VLLM_JOB_ID" ]; then
    echo "Cancel AIDE job only (keeps vLLM running):"
    echo "  scancel $AIDE_JOB"
    echo ""
    echo "Cancel AIDE and vLLM servers:"
    echo "  scancel $AIDE_JOB $VLLM_JOB_ID"
    if [ -n "$GRADING_JOB_ID" ]; then
        echo ""
        echo "Cancel all (AIDE, vLLM, and grading server):"
        echo "  scancel $AIDE_JOB $VLLM_JOB_ID $GRADING_JOB_ID"
    fi
fi
echo ""
echo "=============================================="
