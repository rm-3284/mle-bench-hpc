# vLLM Container Setup for Qwen Models

This directory contains Apptainer container definitions and management scripts for running vLLM servers with Qwen models on HPC clusters.

## Models

- **Qwen3-30B-A3B-Instruct-2507**: 30B parameter model, runs on 1 GPU (port 8000)
- **Qwen3-Next-80B-A3B-Instruct**: 80B parameter model, requires 2 GPUs (port 8001)

## Files

### Container Definitions
- `qwen3-30b-vllm.def`: Apptainer definition for Qwen3-30B
- `qwen3-80b-vllm.def`: Apptainer definition for Qwen3-Next-80B

### Management Scripts
- `build_containers.sh`: Build both Apptainer containers
- `launch_vllm_servers.sh`: Launch both vLLM servers locally
- `stop_vllm_servers.sh`: Stop all running vLLM servers
- `check_vllm_status.sh`: Check status of vLLM servers

### SLURM Scripts
- `../scripts_hpc/slurm_vllm_qwen30b.sh`: Run Qwen3-30B server on SLURM
- `../scripts_hpc/slurm_vllm_qwen80b.sh`: Run Qwen3-Next-80B server on SLURM

## Quick Start

### 1. Build Containers

```bash
cd containers
chmod +x *.sh
./build_containers.sh
```

This will create:
- `qwen3-30b-vllm.sif` (~4-5GB)
- `qwen3-80b-vllm.sif` (~4-5GB)

**Note**: Building may take 30-60 minutes depending on your system.

### 2. Launch Servers

#### Option A: Local Launch (if you have GPUs on login node)

```bash
./launch_vllm_servers.sh
```

#### Option B: SLURM Launch (recommended for HPC)

```bash
# Launch Qwen3-30B (requires 1 GPU)
sbatch ../scripts_hpc/slurm_vllm_qwen30b.sh

# Launch Qwen3-Next-80B (requires 2 GPUs)
sbatch ../scripts_hpc/slurm_vllm_qwen80b.sh
```

Check job status:
```bash
squeue -u $USER
```

View logs:
```bash
tail -f logs/vllm-qwen30b-<JOB_ID>.out
tail -f logs/vllm-qwen80b-<JOB_ID>.out
```

### 3. Check Server Status

```bash
./check_vllm_status.sh
```

Or test directly:
```bash
# Test Qwen3-30B
curl http://localhost:8000/v1/models

# Test Qwen3-80B
curl http://localhost:8001/v1/models
```

### 4. Use with AIDE

Once the servers are running, you can use them with the AIDE agent:

```bash
# Run with Qwen3-30B
python run_agent.py --agent aide/qwen3-30b --competition <competition_id>

# Run with Qwen3-80B
python run_agent.py --agent aide/qwen3-80b --competition <competition_id>

# Development mode (8 steps only)
python run_agent.py --agent aide/qwen3-30b-dev --competition <competition_id>
python run_agent.py --agent aide/qwen3-80b-dev --competition <competition_id>
```

### 5. Stop Servers

```bash
./stop_vllm_servers.sh
```

Or cancel SLURM jobs:
```bash
scancel <JOB_ID>
```

## Configuration

### Environment Variables

You can customize server settings using environment variables:

**For Qwen3-30B:**
```bash
export QWEN30B_PORT=8000
export QWEN30B_GPU=1  # Tensor parallelism
export HF_HOME="$HOME/.cache/huggingface"
```

**For Qwen3-80B:**
```bash
export QWEN80B_PORT=8001
export QWEN80B_GPU=2  # Tensor parallelism
export HF_HOME="$HOME/.cache/huggingface"
```

### Hugging Face Token

If the models require authentication:

```bash
export HF_TOKEN="your_huggingface_token"
```

## Resource Requirements

### Qwen3-30B
- **GPUs**: 1x A100 (40GB) or similar
- **RAM**: 64GB
- **CPUs**: 8 cores
- **Disk**: ~60GB (model + cache)

### Qwen3-Next-80B
- **GPUs**: 2x A100 (40GB) or similar
- **RAM**: 128GB
- **CPUs**: 16 cores
- **Disk**: ~160GB (model + cache)

## Troubleshooting

### Container Build Fails

If you get permission errors:
```bash
# Try with sudo (if available)
sudo apptainer build qwen3-30b-vllm.sif qwen3-30b-vllm.def

# Or use --fakeroot flag
apptainer build --fakeroot qwen3-30b-vllm.sif qwen3-30b-vllm.def
```

### Server Won't Start

1. Check GPU availability:
```bash
nvidia-smi
```

2. Check logs:
```bash
tail -f logs/qwen3-30b.log
tail -f logs/qwen3-80b.log
```

3. Verify model can be downloaded:
```bash
python -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen3-30B-A3B-Instruct-2507')"
```

### Out of Memory

- Reduce `GPU_MEMORY` from 0.95 to 0.9
- Reduce `MAX_MODEL_LEN` from 32768 to 16384 or 8192
- Use more GPUs for tensor parallelism

Edit the `.def` file and rebuild.

### Server Not Responding

Models take time to load. Wait 5-15 minutes after starting before testing.

Monitor with:
```bash
watch -n 5 'curl -s http://localhost:8000/health'
```

## API Usage

The vLLM servers expose an OpenAI-compatible API:

### Python Example

```python
from openai import OpenAI

# Qwen3-30B
client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="dummy"  # vLLM doesn't require real API key
)

response = client.chat.completions.create(
    model="qwen3-30b",
    messages=[
        {"role": "user", "content": "Write a Python function to sort a list"}
    ]
)

print(response.choices[0].message.content)
```

### cURL Example

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-30b",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## Integration with AIDE

The AIDE agent has been configured to use these local vLLM servers. The following configurations are available in `agents/aide/config.yaml`:

- `aide/qwen3-30b`: Full run with Qwen3-30B (500 steps)
- `aide/qwen3-80b`: Full run with Qwen3-Next-80B (500 steps)
- `aide/qwen3-30b-dev`: Development run with Qwen3-30B (8 steps)
- `aide/qwen3-80b-dev`: Development run with Qwen3-Next-80B (8 steps)

The servers must be running before starting the AIDE agent.

## Notes

- Models are downloaded on first run and cached in `$HF_HOME` (default: `~/.cache/huggingface`)
- First run will be slow due to model download (~30-80GB per model)
- Subsequent runs will use cached models
- vLLM provides significant speedup over standard inference
- Both models support the OpenAI Chat Completions API format

## Additional Resources

- [vLLM Documentation](https://docs.vllm.ai/)
- [Apptainer Documentation](https://apptainer.org/docs/)
- [Qwen Models on Hugging Face](https://huggingface.co/Qwen)
