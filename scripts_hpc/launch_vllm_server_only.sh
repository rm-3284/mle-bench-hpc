#!/bin/bash
# Launch Qwen vLLM server for 72 hours (independent of AIDE agent)
# This allows you to run a long-lived inference server and submit AIDE jobs separately
# Usage: ./launch_vllm_server_only.sh [model_size] [partition]

set -e

MODEL_SIZE="${1:-30b}"  # 30b or 80b
PARTITION="${2:-gpu-short}"
DURATION="${3:-72}"  # Hours (default 72)

if [ "$MODEL_SIZE" != "30b" ] && [ "$MODEL_SIZE" != "80b" ]; then
    echo "Error: Model size must be 30b or 80b"
    exit 1
fi

echo "=============================================="
echo "vLLM Server Launcher (Independent)"
echo "=============================================="
echo "Model:       Qwen3-${MODEL_SIZE}"
echo "Partition:   $PARTITION"
echo "Duration:    ${DURATION} hours"
echo "=============================================="
echo ""

# =============================================================================
# Step 1: Start Grading Server
# =============================================================================
echo "Step 1: Starting grading server..."
GRADING_JOB=$(sbatch --parsable --partition=cpu scripts_hpc/slurm_grading_server.sh "dummy-competition")
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
echo "  This server will run for ${DURATION} hours"
echo ""

# Create a temporary SLURM script with extended time limit
TEMP_VLLM_SCRIPT="/tmp/slurm_vllm_qwen${MODEL_SIZE}_${DURATION}h_$$.sh"

# Copy the base script and modify time limit
if [ "$MODEL_SIZE" == "30b" ]; then
    BASE_SCRIPT="scripts_hpc/slurm_vllm_qwen30b.sh"
else
    BASE_SCRIPT="scripts_hpc/slurm_vllm_qwen80b.sh"
fi

cp "$BASE_SCRIPT" "$TEMP_VLLM_SCRIPT"

# Update the time limit in the temporary script
# Convert hours to HH:MM:SS format (assuming max 720 hours = 30 days)
TIME_LIMIT="${DURATION}:00:00"
sed -i 's/--time=24:00:00/--time='"${TIME_LIMIT}"'/g' "$TEMP_VLLM_SCRIPT"

# Submit the modified script
VLLM_JOB=$(sbatch --parsable --partition="$PARTITION" "$TEMP_VLLM_SCRIPT")
echo "  vLLM server job: $VLLM_JOB"
echo "  Time limit: ${TIME_LIMIT}"
echo "  Waiting for vLLM server to start (this may take 5-10 minutes)..."

# Clean up temporary script
rm "$TEMP_VLLM_SCRIPT"

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
# Summary
# =============================================================================
echo "=============================================="
echo "Servers Started Successfully!"
echo "=============================================="
echo ""
echo "Job IDs:"
echo "  Grading Server: $GRADING_JOB"
echo "  vLLM Server:    $VLLM_JOB"
echo "  Node:           $VLLM_NODE"
echo ""
echo "Server Details:"
echo "  Model: Qwen3-${MODEL_SIZE}"
echo "  Port: ${VLLM_PORT}"
echo "  API Base: http://localhost:${VLLM_PORT}/v1"
echo "  Time Limit: ${TIME_LIMIT} (${DURATION} hours)"
echo ""
echo "Monitor logs:"
echo "  tail -f logs/vllm-qwen${MODEL_SIZE}-${VLLM_JOB}.out"
echo ""
echo "Job status:"
echo "  squeue -u $USER"
echo ""
echo "=============================================="
echo ""
echo "To run AIDE agent with this server:"
echo "  ./scripts_hpc/launch_aide_agent_only.sh <competition> $MODEL_SIZE $VLLM_JOB $GRADING_JOB"
echo ""
echo "Example:"
echo "  ./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic $MODEL_SIZE $VLLM_JOB $GRADING_JOB"
echo ""
echo "To stop the servers manually:"
echo "  scancel $VLLM_JOB $GRADING_JOB"
echo ""
echo "=============================================="
