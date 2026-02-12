#!/bin/bash
# Quick setup script for Qwen vLLM servers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_DIR="${SCRIPT_DIR}/containers"

show_help() {
    cat << EOF
Qwen vLLM Server Manager for AIDE

Usage: $0 [command] [options]

Commands:
    build               Build Apptainer containers
    start-30b          Start Qwen3-30B server (1 GPU)
    start-80b          Start Qwen3-Next-80B server (2 GPUs)
    start-all          Start both servers
    status             Check server status
    test               Test servers
    stop               Stop all servers
    logs               Show recent logs
    help               Show this help

SLURM Commands (for HPC):
    slurm-30b          Submit Qwen3-30B job to SLURM
    slurm-80b          Submit Qwen3-80B job to SLURM
    slurm-status       Check SLURM job status

Examples:
    $0 build                # Build containers (one-time)
    $0 slurm-30b           # Launch 30B model on SLURM
    $0 status              # Check if servers are running
    $0 test                # Test server connectivity
    
Environment Variables:
    HF_TOKEN           Hugging Face token (optional)
    QWEN30B_PORT       Port for 30B model (default: 8000)
    QWEN80B_PORT       Port for 80B model (default: 8001)

EOF
}

build_containers() {
    echo "Building Apptainer containers..."
    cd "${CONTAINER_DIR}"
    ./build_containers.sh
}

start_local() {
    echo "Starting vLLM servers locally..."
    cd "${CONTAINER_DIR}"
    ./launch_vllm_servers.sh
}

start_30b_local() {
    echo "Starting Qwen3-30B server locally..."
    cd "${CONTAINER_DIR}"
    export QWEN30B_PORT=${QWEN30B_PORT:-8000}
    export QWEN30B_GPU=${QWEN30B_GPU:-1}
    
    nohup apptainer run --nv \
        --bind "${HF_HOME:-$HOME/.cache/huggingface}:/root/.cache/huggingface" \
        "${CONTAINER_DIR}/qwen3-30b-vllm.sif" \
        > "${CONTAINER_DIR}/logs/qwen3-30b.log" 2>&1 &
    
    echo $! > "${CONTAINER_DIR}/logs/qwen3-30b.pid"
    echo "Started with PID: $!"
    echo "Log: ${CONTAINER_DIR}/logs/qwen3-30b.log"
}

start_80b_local() {
    echo "Starting Qwen3-80B server locally..."
    cd "${CONTAINER_DIR}"
    export QWEN80B_PORT=${QWEN80B_PORT:-8001}
    export QWEN80B_GPU=${QWEN80B_GPU:-2}
    
    nohup apptainer run --nv \
        --bind "${HF_HOME:-$HOME/.cache/huggingface}:/root/.cache/huggingface" \
        "${CONTAINER_DIR}/qwen3-80b-vllm.sif" \
        > "${CONTAINER_DIR}/logs/qwen3-80b.log" 2>&1 &
    
    echo $! > "${CONTAINER_DIR}/logs/qwen3-80b.pid"
    echo "Started with PID: $!"
    echo "Log: ${CONTAINER_DIR}/logs/qwen3-80b.log"
}

slurm_30b() {
    echo "Submitting Qwen3-30B to SLURM..."
    cd "${SCRIPT_DIR}"
    JOB_ID=$(sbatch --parsable scripts_hpc/slurm_vllm_qwen30b.sh)
    echo "Job submitted: $JOB_ID"
    echo "Monitor with: tail -f logs/vllm-qwen30b-${JOB_ID}.out"
    echo "Check status: squeue -j $JOB_ID"
}

slurm_80b() {
    echo "Submitting Qwen3-80B to SLURM..."
    cd "${SCRIPT_DIR}"
    JOB_ID=$(sbatch --parsable scripts_hpc/slurm_vllm_qwen80b.sh)
    echo "Job submitted: $JOB_ID"
    echo "Monitor with: tail -f logs/vllm-qwen80b-${JOB_ID}.out"
    echo "Check status: squeue -j $JOB_ID"
}

slurm_status() {
    echo "SLURM jobs for user $USER:"
    squeue -u $USER -o "%.18i %.9P %.50j %.8T %.10M %.6D %R"
}

check_status() {
    cd "${CONTAINER_DIR}"
    ./check_vllm_status.sh
}

test_servers() {
    cd "${CONTAINER_DIR}"
    ./test_vllm_servers.sh
}

stop_servers() {
    cd "${CONTAINER_DIR}"
    ./stop_vllm_servers.sh
}

show_logs() {
    echo "=== Qwen3-30B Recent Logs ==="
    if [ -f "${CONTAINER_DIR}/logs/qwen3-30b.log" ]; then
        tail -20 "${CONTAINER_DIR}/logs/qwen3-30b.log"
    else
        echo "No log file found"
    fi
    
    echo ""
    echo "=== Qwen3-80B Recent Logs ==="
    if [ -f "${CONTAINER_DIR}/logs/qwen3-80b.log" ]; then
        tail -20 "${CONTAINER_DIR}/logs/qwen3-80b.log"
    else
        echo "No log file found"
    fi
}

# Main command handler
case "${1:-help}" in
    build)
        build_containers
        ;;
    start-30b)
        start_30b_local
        ;;
    start-80b)
        start_80b_local
        ;;
    start-all)
        start_local
        ;;
    slurm-30b)
        slurm_30b
        ;;
    slurm-80b)
        slurm_80b
        ;;
    slurm-status)
        slurm_status
        ;;
    status)
        check_status
        ;;
    test)
        test_servers
        ;;
    stop)
        stop_servers
        ;;
    logs)
        show_logs
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
