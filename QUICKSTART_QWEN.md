# Using Qwen Models with AIDE Agent - Complete Guide

This guide explains how to use the Qwen3-30B and Qwen3-Next-80B models with the AIDE agent in mle-bench using vLLM servers in Apptainer containers.

## Overview

We've set up a system to run these models locally using vLLM (a fast inference engine) inside Apptainer containers, exposing them via OpenAI-compatible APIs that AIDE can use.

**Models:**
- Qwen3-30B-A3B-Instruct-2507 (30B params, 1 GPU, port 8000)
- Qwen3-Next-80B-A3B-Instruct (80B params, 2 GPUs, port 8001)

## Step-by-Step Setup

### Step 1: Build the Containers

```bash
cd /scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc/containers
./build_containers.sh
```

This builds two Apptainer containers (~4-5GB each) and takes 30-60 minutes.

**Output:**
- `qwen3-30b-vllm.sif`
- `qwen3-80b-vllm.sif`

### Step 2: Launch vLLM Servers on HPC

Since you're on HPC, use SLURM to launch the servers on compute nodes with GPUs:

#### Launch Qwen3-30B (1 GPU)

```bash
cd /scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc
sbatch scripts_hpc/slurm_vllm_qwen30b.sh
```

#### Launch Qwen3-80B (2 GPUs)

```bash
sbatch scripts_hpc/slurm_vllm_qwen80b.sh
```

#### Check Job Status

```bash
squeue -u $USER
```

#### Monitor Logs

```bash
# Qwen3-30B logs
tail -f logs/vllm-qwen30b-<JOB_ID>.out

# Qwen3-80B logs
tail -f logs/vllm-qwen80b-<JOB_ID>.out
```

**Wait for startup:** Models take 5-15 minutes to load. Look for "Application startup complete" in logs.

### Step 3: Verify Servers Are Running

From the compute node where servers are running:

```bash
cd containers
./test_vllm_servers.sh
```

Or test manually:
```bash
curl http://localhost:8000/v1/models  # Qwen3-30B
curl http://localhost:8001/v1/models  # Qwen3-80B
```

### Step 4: Run AIDE with Qwen Models

Once servers are running, use them with AIDE:

#### Full Run (500 steps)

```bash
# With Qwen3-30B
python run_agent.py --agent aide/qwen3-30b --competition <competition_id>

# With Qwen3-80B
python run_agent.py --agent aide/qwen3-80b --competition <competition_id>
```

#### Development Run (8 steps)

```bash
# With Qwen3-30B
python run_agent.py --agent aide/qwen3-30b-dev --competition <competition_id>

# With Qwen3-80B
python run_agent.py --agent aide/qwen3-80b-dev --competition <competition_id>
```

### Step 5: Stop Servers

When done, cancel the SLURM jobs:

```bash
scancel <JOB_ID>
```

Or if running locally:
```bash
cd containers
./stop_vllm_servers.sh
```

## Configuration Details

### AIDE Agent Configurations

Four new configurations were added to `agents/aide/config.yaml`:

1. **aide/qwen3-30b**: Production run with Qwen3-30B
   - Code model: qwen3-30b @ http://localhost:8000/v1
   - Feedback model: qwen3-30b @ http://localhost:8000/v1
   - Steps: 500

2. **aide/qwen3-80b**: Production run with Qwen3-80B
   - Code model: qwen3-80b @ http://localhost:8001/v1
   - Feedback model: qwen3-80b @ http://localhost:8001/v1
   - Steps: 500

3. **aide/qwen3-30b-dev**: Development run with Qwen3-30B (8 steps)

4. **aide/qwen3-80b-dev**: Development run with Qwen3-80B (8 steps)

### Resource Requirements

#### Qwen3-30B
- GPUs: 1x A100 (40-80GB recommended)
- RAM: 64GB
- CPUs: 8 cores
- Storage: ~60GB (model + cache)

#### Qwen3-Next-80B
- GPUs: 2x A100 (40-80GB recommended)
- RAM: 128GB
- CPUs: 16 cores
- Storage: ~160GB (model + cache)

## Workflow Example

Here's a complete workflow from start to finish:

```bash
# 1. Build containers (one-time setup)
cd /scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc/containers
./build_containers.sh

# 2. Launch Qwen3-30B server
cd /scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc
sbatch scripts_hpc/slurm_vllm_qwen30b.sh

# 3. Check job status
squeue -u $USER
# Note the JOB_ID and wait for R (running) status

# 4. Monitor until "Application startup complete"
tail -f logs/vllm-qwen30b-<JOB_ID>.out

# 5. On the SAME compute node, run AIDE
# You can either:
# a) Submit another SLURM job that uses the server
# b) SSH to the compute node and run interactively

# Example: Test development run
python run_agent.py --agent aide/qwen3-30b-dev --competition spaceship-titanic

# 6. When done, stop the server
scancel <JOB_ID>
```

## Advanced Configuration

### Custom Ports

If default ports conflict, modify the SLURM scripts:

```bash
# Edit scripts_hpc/slurm_vllm_qwen30b.sh
export PORT=9000  # Change from 8000 to 9000

# Update config.yaml accordingly
agent.code.api_base: http://localhost:9000/v1
```

### Tensor Parallelism

For better performance with more GPUs:

```bash
# Edit SLURM script
export TENSOR_PARALLEL=4  # Use 4 GPUs instead of 1
#SBATCH --gres=gpu:4      # Request 4 GPUs
```

### Memory Optimization

If you run out of GPU memory:

Edit the `.def` file:
```bash
GPU_MEMORY=${GPU_MEMORY:-0.90}      # Reduce from 0.95
MAX_MODEL_LEN=${MAX_MODEL_LEN:-16384}  # Reduce from 32768
```

Then rebuild:
```bash
./build_containers.sh
```

### Hugging Face Authentication

If models require authentication:

```bash
export HF_TOKEN="your_huggingface_token"
sbatch scripts_hpc/slurm_vllm_qwen30b.sh
```

## Troubleshooting

### Problem: Container build fails with permission error

**Solution:**
```bash
# Use --fakeroot flag
cd containers
apptainer build --fakeroot qwen3-30b-vllm.sif qwen3-30b-vllm.def
```

### Problem: Server won't start / "CUDA out of memory"

**Solutions:**
1. Request more GPU memory in SLURM
2. Reduce `GPU_MEMORY` and `MAX_MODEL_LEN` in container definition
3. Increase tensor parallelism (use more GPUs)
4. Use a smaller model

### Problem: Can't connect to server from AIDE

**Common causes:**
1. Server not fully started (wait 5-15 minutes)
2. Running on different compute nodes
3. Firewall blocking

**Solutions:**
- Ensure AIDE runs on the SAME node as vLLM server
- Check logs: `tail -f logs/vllm-qwen30b-*.out`
- Test connectivity: `curl http://localhost:8000/v1/models`

### Problem: Model download is slow or fails

**Solutions:**
```bash
# Pre-download models before running server
python -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen3-30B-A3B-Instruct-2507')"

# Or set larger cache location
export HF_HOME="/scratch/gpfs/KARTHIKN/rm4411/hf_cache"
```

### Problem: Server crashes during inference

**Check logs for:**
- Out of memory errors → Reduce batch size or context length
- Model errors → Verify model compatibility with vLLM version
- CUDA errors → Check GPU health with `nvidia-smi`

## Performance Tips

1. **First run is slow**: Models are downloaded (~30-80GB). Subsequent runs use cache.

2. **Batch requests**: If running multiple competitions, keep server running between runs.

3. **Use SSD for cache**: Set `HF_HOME` to fast storage for better load times.

4. **Monitor GPU usage**: Use `nvidia-smi -l 1` to watch GPU utilization.

5. **Development mode**: Use `-dev` variants for quick testing (8 steps vs 500).

## Files Created

```
mle-bench-hpc/
├── containers/
│   ├── qwen3-30b-vllm.def          # Container definition for 30B model
│   ├── qwen3-80b-vllm.def          # Container definition for 80B model
│   ├── build_containers.sh         # Build both containers
│   ├── launch_vllm_servers.sh      # Launch servers locally
│   ├── stop_vllm_servers.sh        # Stop servers
│   ├── check_vllm_status.sh        # Check server status
│   ├── test_vllm_servers.sh        # Test server functionality
│   └── README.md                   # Detailed documentation
├── scripts_hpc/
│   ├── slurm_vllm_qwen30b.sh       # SLURM script for 30B model
│   └── slurm_vllm_qwen80b.sh       # SLURM script for 80B model
├── agents/aide/
│   └── config.yaml                 # Updated with Qwen configurations
└── QUICKSTART_QWEN.md              # This file
```

## API Compatibility

The vLLM servers expose OpenAI-compatible APIs, so you can also use them directly:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="dummy"
)

response = client.chat.completions.create(
    model="qwen3-30b",
    messages=[{"role": "user", "content": "Hello!"}]
)

print(response.choices[0].message.content)
```

## Next Steps

1. **Build containers**: `cd containers && ./build_containers.sh`
2. **Launch server**: `sbatch scripts_hpc/slurm_vllm_qwen30b.sh`
3. **Test**: `cd containers && ./test_vllm_servers.sh`
4. **Run AIDE**: `python run_agent.py --agent aide/qwen3-30b-dev --competition spaceship-titanic`

## Support

For issues:
- Check logs in `logs/vllm-qwen*.out`
- Review the detailed README in `containers/README.md`
- Verify GPU availability with `nvidia-smi`
- Test API with `curl http://localhost:8000/v1/models`

## References

- [vLLM Documentation](https://docs.vllm.ai/)
- [Apptainer Documentation](https://apptainer.org/docs/)
- [Qwen Models](https://huggingface.co/Qwen)
- [OpenAI API Specification](https://platform.openai.com/docs/api-reference)
