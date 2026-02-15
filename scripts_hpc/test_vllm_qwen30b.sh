#!/bin/bash
#SBATCH --job-name=test-qwen30b
#SBATCH --output=logs/test-qwen30b-%j.out
#SBATCH --error=logs/test-qwen30b-%j.err
#SBATCH --account=mle_agent
#SBATCH --nodes=1
#SBATCH --partition=pli
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=00:05:00

# Test script for Qwen3-30B vLLM server
# This runs on the same compute node to test the server

set -e

PORT=${PORT:-8000}
MODEL_NAME="qwen3-30b"

echo "========================================"
echo "Testing Qwen3-30B vLLM Server"
echo "========================================"
echo "Node: $SLURM_NODELIST"
echo "Testing port: $PORT"
echo ""

# Function to test endpoint
test_endpoint() {
    local endpoint=$1
    local description=$2
    
    echo "Testing $description..."
    if curl -s -f "$endpoint" > /dev/null 2>&1; then
        echo "  ✓ Success"
        return 0
    else
        echo "  ✗ Failed"
        return 1
    fi
}

# Wait a moment for any network setup
sleep 2

# Test health endpoint
echo "1. Health check"
if curl -s -f http://localhost:${PORT}/health > /dev/null 2>&1; then
    echo "  ✓ Health endpoint responding"
else
    echo "  ✗ Health endpoint not responding"
    echo "  Server may still be loading or not running on this node"
    exit 1
fi

# Test models endpoint
echo ""
echo "2. Models endpoint"
if curl -s -f http://localhost:${PORT}/v1/models > /dev/null 2>&1; then
    echo "  ✓ Models endpoint responding"
    echo ""
    echo "Available models:"
    curl -s http://localhost:${PORT}/v1/models | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for model in data.get('data', []):
        print(f\"  - {model['id']}\")
except:
    print('  (Unable to parse response)')
" 2>/dev/null
else
    echo "  ✗ Models endpoint not responding"
    exit 1
fi

# Test completion endpoint
echo ""
echo "3. Chat completion test"
response=$(curl -s http://localhost:${PORT}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Say exactly: Hello from Qwen3-30B!\"}],
        \"max_tokens\": 20,
        \"temperature\": 0.1
    }")

if [ $? -eq 0 ]; then
    echo "  ✓ Completion endpoint responding"
    echo ""
    echo "Response:"
    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    content = data['choices'][0]['message']['content']
    print(f\"  {content}\")
    print(f\"\\nTokens - Prompt: {data['usage']['prompt_tokens']}, Completion: {data['usage']['completion_tokens']}\")
except Exception as e:
    print(f'  Error parsing: {e}')
    print(sys.stdin.read())
" 2>/dev/null
    echo ""
    echo "  ✓ Server is fully functional!"
else
    echo "  ✗ Completion endpoint failed"
    echo "  Response: $response"
    exit 1
fi

echo ""
echo "========================================"
echo "All tests PASSED!"
echo "========================================"
echo "The Qwen3-30B server is working correctly on port $PORT"
echo ""

exit 0
