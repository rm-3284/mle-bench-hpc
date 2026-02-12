#!/bin/bash
# Stop vLLM servers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

stop_server() {
    local model_name=$1
    local pid_file="${LOG_DIR}/${model_name}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        echo "Stopping $model_name (PID: $pid)..."
        
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            sleep 2
            
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                echo "  Force killing $model_name..."
                kill -9 "$pid"
            fi
            
            rm "$pid_file"
            echo "  Stopped successfully"
        else
            echo "  Process not running"
            rm "$pid_file"
        fi
    else
        echo "$model_name: No PID file found"
    fi
}

echo "Stopping vLLM servers..."
echo ""

stop_server "qwen3-30b"
stop_server "qwen3-80b"

echo ""
echo "All servers stopped."
