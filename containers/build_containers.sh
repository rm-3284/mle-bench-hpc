#!/bin/bash
# Build script for vLLM Apptainer containers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_DIR="${SCRIPT_DIR}"

echo "Building vLLM containers for Qwen models..."

# Build Qwen3-30B container
echo ""
echo "========================================"
echo "Building Qwen3-30B-A3B-Instruct container..."
echo "========================================"
apptainer build --fakeroot "${CONTAINER_DIR}/qwen3-30b-vllm.sif" "${CONTAINER_DIR}/qwen3-30b-vllm.def"

# Build Qwen3-Next-80B container
echo ""
echo "========================================"
echo "Building Qwen3-Next-80B-A3B-Instruct container..."
echo "========================================"
apptainer build --fakeroot "${CONTAINER_DIR}/qwen3-80b-vllm.sif" "${CONTAINER_DIR}/qwen3-80b-vllm.def"

echo ""
echo "========================================"
echo "Build complete!"
echo "========================================"
echo "Containers created:"
echo "  - ${CONTAINER_DIR}/qwen3-30b-vllm.sif"
echo "  - ${CONTAINER_DIR}/qwen3-80b-vllm.sif"
echo ""
echo "To start the servers, use:"
echo "  ./launch_vllm_servers.sh"
