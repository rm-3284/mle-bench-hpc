#!/bin/bash
# Launch vLLM servers in Apptainer containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_DIR="${SCRIPT_DIR}"
LOG_DIR="${SCRIPT_DIR}/logs"

mkdir -p "${LOG_DIR}"

# Default configuration
QWEN30B_PORT=${QWEN30B_PORT:-8000}
QWEN80B_PORT=${QWEN80B_PORT:-8001}
QWEN30B_GPU=${QWEN30B_GPU:-1}
QWEN80B_GPU=${QWEN80B_GPU:-2}
HF_HOME=${HF_HOME:-"$HOME/.cache/huggingface"}

# Check if containers exist
if [ ! -f "${CONTAINER_DIR}/qwen3-30b-vllm.sif" ]; then
    echo "Error: qwen3-30b-vllm.sif not found. Please run build_containers.sh first."
    exit 1
fi

if [ ! -f "${CONTAINER_DIR}/qwen3-80b-vllm.sif" ]; then
    echo "Error: qwen3-80b-vllm.sif not found. Please run build_containers.sh first."
    exit 1
fi

# Function to launch a vLLM server
launch_server() {
    local model_name=$1
    local container_file=$2
    local port=$3
    local tensor_parallel=$4
    local log_file=$5
    
    echo "Launching $model_name on port $port..."
    echo "  Log file: $log_file"
    echo "  Tensor parallel size: $tensor_parallel"
    
    export PORT=$port
    export TENSOR_PARALLEL=$tensor_parallel
    export APPTAINERENV_PORT=$port
    export APPTAINERENV_TENSOR_PARALLEL=$tensor_parallel
    
    # Launch in background with apptainer
    nohup apptainer run --nv \
        --bind "${HF_HOME}:/root/.cache/huggingface" \
        "${container_file}" \
        > "${log_file}" 2>&1 &
    
    local pid=$!
    echo "  Started with PID: $pid"
    echo "$pid" > "${LOG_DIR}/${model_name}.pid"
    
    return 0
}

# Launch Qwen3-30B
echo "========================================"
echo "Starting Qwen3-30B-A3B-Instruct server"
echo "========================================"
launch_server \
    "qwen3-30b" \
    "${CONTAINER_DIR}/qwen3-30b-vllm.sif" \
    "${QWEN30B_PORT}" \
    "${QWEN30B_GPU}" \
    "${LOG_DIR}/qwen3-30b.log"

echo ""
echo "========================================"
echo "Starting Qwen3-Next-80B-A3B-Instruct server"
echo "========================================"
launch_server \
    "qwen3-80b" \
    "${CONTAINER_DIR}/qwen3-80b-vllm.sif" \
    "${QWEN80B_PORT}" \
    "${QWEN80B_GPU}" \
    "${LOG_DIR}/qwen3-80b.log"

echo ""
echo "========================================"
echo "vLLM servers launched!"
echo "========================================"
echo ""
echo "Server endpoints:"
echo "  Qwen3-30B:  http://localhost:${QWEN30B_PORT}/v1"
echo "  Qwen3-80B:  http://localhost:${QWEN80B_PORT}/v1"
echo ""
echo "Check logs at:"
echo "  Qwen3-30B:  ${LOG_DIR}/qwen3-30b.log"
echo "  Qwen3-80B:  ${LOG_DIR}/qwen3-80b.log"
echo ""
echo "Wait a few minutes for models to load. Monitor with:"
echo "  tail -f ${LOG_DIR}/qwen3-30b.log"
echo "  tail -f ${LOG_DIR}/qwen3-80b.log"
echo ""
echo "Stop servers with:"
echo "  ./stop_vllm_servers.sh"
echo ""
echo "Test the servers with:"
echo "  curl http://localhost:${QWEN30B_PORT}/v1/models"
echo "  curl http://localhost:${QWEN80B_PORT}/v1/models"
