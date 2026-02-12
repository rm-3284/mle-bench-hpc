#!/bin/bash
# Test script for vLLM servers

set -e

QWEN30B_PORT=${QWEN30B_PORT:-8000}
QWEN80B_PORT=${QWEN80B_PORT:-8001}

echo "========================================"
echo "Testing vLLM Servers"
echo "========================================"
echo ""

test_server() {
    local name=$1
    local port=$2
    local model=$3
    
    echo "Testing $name on port $port..."
    echo "----------------------------------------"
    
    # Test health endpoint
    echo "1. Checking health endpoint..."
    if curl -s -f http://localhost:${port}/health > /dev/null 2>&1; then
        echo "   ✓ Health check passed"
    else
        echo "   ✗ Health check failed"
        return 1
    fi
    
    # Test models endpoint
    echo "2. Checking models endpoint..."
    if curl -s -f http://localhost:${port}/v1/models > /dev/null 2>&1; then
        echo "   ✓ Models endpoint accessible"
        echo "   Available models:"
        curl -s http://localhost:${port}/v1/models | python3 -c "import sys, json; data = json.load(sys.stdin); [print(f\"     - {m['id']}\") for m in data.get('data', [])]" 2>/dev/null || echo "     (Unable to parse)"
    else
        echo "   ✗ Models endpoint failed"
        return 1
    fi
    
    # Test completion endpoint
    echo "3. Testing completion endpoint..."
    response=$(curl -s -f http://localhost:${port}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${model}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Say 'test successful' and nothing else.\"}],
            \"max_tokens\": 10
        }" 2>&1)
    
    if [ $? -eq 0 ]; then
        echo "   ✓ Completion endpoint working"
        echo "   Response preview:"
        echo "$response" | python3 -c "import sys, json; data = json.load(sys.stdin); print(f\"     {data['choices'][0]['message']['content'][:100]}\")" 2>/dev/null || echo "     (Response received but unable to parse)"
    else
        echo "   ✗ Completion endpoint failed"
        echo "   Error: $response"
        return 1
    fi
    
    echo "   ✓ All tests passed for $name"
    echo ""
    return 0
}

# Test both servers
success=0

if test_server "Qwen3-30B" "$QWEN30B_PORT" "qwen3-30b"; then
    success=$((success + 1))
fi

if test_server "Qwen3-80B" "$QWEN80B_PORT" "qwen3-80b"; then
    success=$((success + 1))
fi

echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Servers tested: 2"
echo "Servers passed: $success"
echo ""

if [ $success -eq 2 ]; then
    echo "✓ All servers are working correctly!"
    echo ""
    echo "You can now use them with AIDE:"
    echo "  python run_agent.py --agent aide/qwen3-30b --competition <competition_id>"
    echo "  python run_agent.py --agent aide/qwen3-80b --competition <competition_id>"
    exit 0
else
    echo "✗ Some servers failed tests"
    echo ""
    echo "Check server status with: ./check_vllm_status.sh"
    echo "Check logs at: logs/qwen3-*.log"
    exit 1
fi
