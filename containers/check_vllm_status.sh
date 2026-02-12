#!/bin/bash
# Check status of vLLM servers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

check_server() {
    local model_name=$1
    local port=$2
    local pid_file="${LOG_DIR}/${model_name}.pid"
    
    echo "========================================"
    echo "$model_name Status"
    echo "========================================"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Status: RUNNING (PID: $pid)"
            
            # Check if server is responding
            if curl -s http://localhost:${port}/health > /dev/null 2>&1; then
                echo "Health: OK"
                echo "Endpoint: http://localhost:${port}/v1"
                
                # Get model info
                echo ""
                echo "Available models:"
                curl -s http://localhost:${port}/v1/models | python3 -m json.tool 2>/dev/null || echo "  (Unable to parse response)"
            else
                echo "Health: NOT RESPONDING (may still be loading)"
                echo "Check logs: tail -f ${LOG_DIR}/${model_name}.log"
            fi
        else
            echo "Status: NOT RUNNING (stale PID file)"
        fi
    else
        echo "Status: NOT RUNNING (no PID file)"
    fi
    echo ""
}

# Default ports
QWEN30B_PORT=${QWEN30B_PORT:-8000}
QWEN80B_PORT=${QWEN80B_PORT:-8001}

check_server "qwen3-30b" "$QWEN30B_PORT"
check_server "qwen3-80b" "$QWEN80B_PORT"

echo "========================================"
echo "Recent log entries"
echo "========================================"
echo ""
echo "Qwen3-30B (last 5 lines):"
if [ -f "${LOG_DIR}/qwen3-30b.log" ]; then
    tail -5 "${LOG_DIR}/qwen3-30b.log"
else
    echo "  No log file found"
fi

echo ""
echo "Qwen3-80B (last 5 lines):"
if [ -f "${LOG_DIR}/qwen3-80b.log" ]; then
    tail -5 "${LOG_DIR}/qwen3-80b.log"
else
    echo "  No log file found"
fi
