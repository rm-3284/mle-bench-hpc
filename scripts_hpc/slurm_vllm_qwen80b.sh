#!/bin/bash
#SBATCH --job-name=vllm-qwen80b
#SBATCH --output=logs/vllm-qwen80b-%j.out
#SBATCH --error=logs/vllm-qwen80b-%j.err
#SBATCH --nodes=1
#SBATCH --partition=gpu-short
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --gres=gpu:2
#SBATCH --mem=128G
#SBATCH --time=24:00:00

# SLURM script to run Qwen3-Next-80B vLLM server on HPC

set -e

echo "========================================"
echo "Starting Qwen3-Next-80B vLLM Server"
echo "========================================"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_NODELIST"
echo "GPUs: $CUDA_VISIBLE_DEVICES"
echo "========================================"

# Configuration
CONTAINER_DIR="$(pwd)/containers"
CONTAINER_FILE="${CONTAINER_DIR}/qwen3-80b-vllm.sif"
PORT=${PORT:-8001}
TENSOR_PARALLEL=${TENSOR_PARALLEL:-2}
HF_HOME=${HF_HOME:-"$HOME/.cache/huggingface"}

# Check if container exists
if [ ! -f "$CONTAINER_FILE" ]; then
    echo "Error: Container not found at $CONTAINER_FILE"
    echo "Please build the container first with: cd containers && ./build_containers.sh"
    exit 1
fi

# Set environment variables for Apptainer
export APPTAINERENV_PORT=$PORT
export APPTAINERENV_TENSOR_PARALLEL=$TENSOR_PARALLEL
export APPTAINERENV_HF_TOKEN=$HF_TOKEN

# Print server info
echo ""
echo "Server Configuration:"
echo "  Model: Qwen/Qwen3-Next-80B-A3B-Instruct"
echo "  Port: $PORT"
echo "  Tensor Parallel: $TENSOR_PARALLEL"
echo "  HF Cache: $HF_HOME"
echo ""
echo "Starting server..."
echo ""

# Run the container
apptainer run --nv \
    --bind "${HF_HOME}:/root/.cache/huggingface" \
    "$CONTAINER_FILE"

echo ""
echo "Server stopped."
