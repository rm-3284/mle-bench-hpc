# Complete Guide: Running AIDE with Qwen Models on HPC

This guide explains how to run the AIDE agent with local Qwen models using vLLM on your HPC cluster with Apptainer (not Docker).

## Architecture Overview

The complete system has 3 components running as separate SLURM jobs:

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Grading Server  │────▶│  vLLM Server     │────▶│  AIDE Agent     │
│  (CPU node)     │     │  (GPU node)      │     │  (same GPU node)│
└─────────────────┘     └──────────────────┘     └─────────────────┘
     Port 5000              Port 8000/8001           Runs inference
```

1. **Grading Server**: Validates submissions and provides feedback
2. **vLLM Server**: Serves Qwen model via OpenAI-compatible API
3. **AIDE Agent**: Runs on the same node as vLLM, uses local API

## Prerequisites

### 1. Build Containers (One-Time Setup)

```bash
# Build vLLM containers
cd containers
./build_containers.sh

# This creates:
# - qwen3-30b-vllm.sif (~5GB)
# - qwen3-80b-vllm.sif (~5GB)
```

### 2. Build AIDE Container (One-Time Setup)

```bash
# Build AIDE container with Qwen support
cd containers
apptainer build --fakeroot aide-qwen.sif aide-qwen.def

# This creates:
# - aide-qwen.sif (~3-4GB)
```

**Note**: The AIDE container definition ([aide-qwen.def](aide-qwen.def#L1)) assumes you have the AIDE agent files. You may need to adjust the `%files` section based on your actual file locations.

### 3. Data Setup

Ensure your competition data is in the expected location:
```bash
data/
  spaceship-titanic/
    prepared/
      public/
        ...
```

## Usage

### Option 1: Automated Workflow (Recommended)

The easiest way is to use the automated workflow script that handles all three components:

```bash
# Make script executable
chmod +x scripts_hpc/run_aide_qwen_workflow.sh

# Run the workflow
./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b gpu-short
```

**Arguments:**
- `<competition>`: Competition ID (e.g., `spaceship-titanic`)
- `[model_size]`: `30b` or `80b` (default: `30b`)
- `[partition]`: SLURM partition with GPUs (default: `gpu-short`)

**What it does:**
1. Starts grading server on CPU node
2. Starts vLLM server on GPU node
3. Waits for servers to be ready
4. Starts AIDE agent on same GPU node as vLLM
5. Displays job IDs and monitoring commands

### Option 2: Manual Step-by-Step

If you prefer to manually control each step:

#### Step 1: Start Grading Server

```bash
sbatch scripts_hpc/slurm_grading_server.sh spaceship-titanic
```

Note the job ID. Wait for it to start and get the URL from:
```bash
cat $HOME/.mlebench_addresses/grading_server_<JOB_ID>
```

#### Step 2: Start vLLM Server

For Qwen3-30B:
```bash
sbatch scripts_hpc/slurm_vllm_qwen30b.sh
```

For Qwen3-80B:
```bash
sbatch scripts_hpc/slurm_vllm_qwen80b.sh
```

Monitor the log to see when model is loaded:
```bash
tail -f logs/vllm-qwen30b-<JOB_ID>.out
```

Look for "Application startup complete" message.

#### Step 3: Start AIDE Agent

Important: Run AIDE on the **same node** as vLLM for localhost connectivity.

```bash
# Get the node where vLLM is running
VLLM_NODE=$(squeue -j <VLLM_JOB_ID> -h -o "%N")

# Submit AIDE to that specific node
sbatch --nodelist=$VLLM_NODE \
    scripts_hpc/slurm_aide_qwen.sh \
    spaceship-titanic \
    <VLLM_JOB_ID> \
    30b \
    auto:<GRADING_JOB_ID>
```

## Monitoring

### Check Job Status

```bash
# All your jobs
squeue -u $USER

# Specific job
squeue -j <JOB_ID>

# Using management script
./manage_qwen.sh slurm-status
```

### Monitor Logs

```bash
# vLLM server
tail -f logs/vllm-qwen30b-<JOB_ID>.out

# AIDE agent
tail -f logs/aide-qwen-<JOB_ID>.out

# Grading server
tail -f slurm_output/mlebench/grading-<JOB_ID>.out
```

### Check vLLM Server Status

Once vLLM is running, from the same node:
```bash
curl http://localhost:8000/v1/models  # For 30B
curl http://localhost:8001/v1/models  # For 80B
```

## Output and Results

After the AIDE agent completes, results are saved to:
```
/scratch/$USER/mlebench-runs/<competition>_qwen3-<size>_<job_id>/
├── submission/     # submission.csv
├── logs/          # Agent logs
├── code/          # Generated code
└── workspaces/    # AIDE workspaces
```

## Grading Submissions

```bash
# Using mlebench CLI
mlebench grade \
    --submission /scratch/$USER/mlebench-runs/.../submission/submission.csv \
    --competition spaceship-titanic
```

## Resource Requirements

### Qwen3-30B
- **Grading Server**: 1 CPU node, 2 cores, 8GB RAM
- **vLLM Server**: 1 GPU (A100 40-80GB), 8 CPU cores, 64GB RAM
- **AIDE Agent**: Shared with vLLM (same node)

### Qwen3-80B
- **Grading Server**: 1 CPU node, 2 cores, 8GB RAM
- **vLLM Server**: 2 GPUs (A100 40-80GB), 16 CPU cores, 128GB RAM
- **AIDE Agent**: Shared with vLLM (same node)

## Time Estimates

- **Container builds**: 30-60 minutes (one-time)
- **Grading server startup**: 1-2 minutes
- **vLLM model loading**: 5-15 minutes
- **AIDE agent run**: Variable (hours to a day, depending on competition)

## Troubleshooting

### Problem: AIDE can't connect to vLLM

**Cause**: AIDE and vLLM are on different nodes.

**Solution**: Ensure AIDE runs on the same node as vLLM:
```bash
VLLM_NODE=$(squeue -j <VLLM_JOB_ID> -h -o "%N")
sbatch --nodelist=$VLLM_NODE scripts_hpc/slurm_aide_qwen.sh ...
```

### Problem: vLLM server OOM (Out of Memory)

**Solution**: Reduce memory usage in container definition:
```bash
# Edit containers/qwen3-30b-vllm.def
GPU_MEMORY=${GPU_MEMORY:-0.90}      # Reduce from 0.95
MAX_MODEL_LEN=${MAX_MODEL_LEN:-16384}  # Reduce from 32768
```

Then rebuild:
```bash
cd containers
apptainer build --fakeroot qwen3-30b-vllm.sif qwen3-30b-vllm.def
```

### Problem: AIDE fails with API errors

**Check**:
1. vLLM server is fully loaded (check logs)
2. API endpoint is correct (http://localhost:8000/v1)
3. Model name matches what vLLM is serving

**Test vLLM**:
```bash
# From the same node
curl http://localhost:8000/v1/models
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-30b", "messages": [{"role": "user", "content": "test"}]}'
```

### Problem: Grading server not found

**Solution**: Pass grading server URL explicitly:
```bash
GRADING_URL=$(cat $HOME/.mlebench_addresses/grading_server_<JOB_ID>)
echo "Using grading server: $GRADING_URL"
```

Or use the `auto:<JOB_ID>` syntax in the workflow script.

### Problem: Container build fails

**Common causes**:
1. Conda TOS not accepted (fixed in current definitions)
2. Permission errors (use `--fakeroot` flag)
3. Missing files in `%files` section

**Solution**:
```bash
# Build with verbose output
apptainer build --fakeroot -v aide-qwen.sif aide-qwen.def
```

## Advanced Configuration

### Using Different Models

To add support for other models:

1. Create a new `.def` file in `containers/`
2. Update vLLM container to use different model
3. Create corresponding SLURM script
4. Update AIDE config in `agents/aide/config.yaml`

### Adjusting AIDE Parameters

Edit the SLURM script [slurm_aide_qwen.sh](slurm_aide_qwen.sh#L1) to change:
- `TIME_LIMIT_SECS`: Maximum runtime
- `STEP_LIMIT`: Maximum agent steps
- Model parameters passed to AIDE

### Running Multiple Jobs

You can run multiple AIDE jobs against the same vLLM server:
```bash
# Start vLLM once
VLLM_JOB=$(sbatch --parsable scripts_hpc/slurm_vllm_qwen30b.sh)
VLLM_NODE=$(squeue -j $VLLM_JOB -h -o "%N")

# Run multiple AIDE jobs on same node
sbatch --nodelist=$VLLM_NODE scripts_hpc/slurm_aide_qwen.sh competition1 ...
sbatch --nodelist=$VLLM_NODE scripts_hpc/slurm_aide_qwen.sh competition2 ...
```

## Best Practices

1. **Build containers once**: Containers are reusable across runs
2. **Share vLLM servers**: Multiple AIDE jobs can use one vLLM server
3. **Monitor logs**: Always check logs to catch issues early
4. **Test with dev mode**: Use `agent.steps=8` for quick testing
5. **Clean up**: Cancel jobs when done: `scancel <JOB_ID>`

## Files Created

```
mle-bench-hpc/
├── containers/
│   ├── aide-qwen.def               # AIDE container definition
│   ├── qwen3-30b-vllm.def         # Qwen3-30B vLLM container
│   ├── qwen3-80b-vllm.def         # Qwen3-80B vLLM container
│   └── ...
├── scripts_hpc/
│   ├── slurm_aide_qwen.sh         # AIDE agent SLURM script
│   ├── slurm_vllm_qwen30b.sh      # vLLM 30B SLURM script
│   ├── slurm_vllm_qwen80b.sh      # vLLM 80B SLURM script
│   ├── run_aide_qwen_workflow.sh  # Automated workflow
│   └── ...
└── AIDE_QWEN_COMPLETE_GUIDE.md    # This file
```

## Next Steps

1. **Build containers**: `cd containers && ./build_containers.sh && apptainer build aide-qwen.sif aide-qwen.def`
2. **Test workflow**: `./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b`
3. **Monitor**: `squeue -u $USER` and check logs
4. **Iterate**: Adjust parameters and retry as needed

## References

- [vLLM Documentation](https://docs.vllm.ai/)
- [Apptainer Documentation](https://apptainer.org/docs/)
- [AIDE GitHub](https://github.com/aide-ai/aide)
- [Qwen Models](https://huggingface.co/Qwen)

## Summary

You've successfully set up a complete Apptainer-based workflow for running AIDE with local Qwen models on your HPC cluster. This replaces the Docker-based approach with Apptainer containers, enabling efficient use of HPC resources while maintaining full functionality.
