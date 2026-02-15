# Qwen vLLM Server and AIDE Agent - Usage Guide

This document explains the different ways to run AIDE with Qwen models on HPC, with emphasis on the new option to run a long-lived vLLM server (72+ hours) independently from AIDE jobs.

## Overview

There are now three ways to run AIDE with Qwen models:

### 1. **All-in-One Workflow** (Original - everything at once)
- **Best for**: Quick testing, single runs
- **Pros**: Simple, one command
- **Cons**: Server stops when AIDE finishes
- **Script**: `run_aide_qwen_workflow.sh`

### 2. **Long-Lived Server** (New - recommended for production)
- **Best for**: Multiple AIDE runs, long-running inference server
- **Pros**: Keep server running for 72+ hours, submit many AIDE jobs
- **Cons**: Requires two separate submissions
- **Scripts**: 
  - `launch_vllm_server_only.sh` - Start servers
  - `launch_aide_agent_only.sh` - Submit AIDE job(s)

### 3. **Expert Mode** (Manual SLURM scripts)
- **Best for**: Advanced customization
- **Scripts**:
  - `slurm_grading_server.sh`
  - `slurm_vllm_qwen30b.sh` or `slurm_vllm_qwen80b.sh`
  - `slurm_aide_qwen.sh`

---

## New Workflow: Long-Lived Server + Multiple AIDE Jobs

This is the **recommended approach for production use**.

### Step 1: Start the vLLM Server (72 hours)

```bash
cd /scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 72
```

**Parameters:**
- `30b` or `80b` - Model size
- `gpu-short` - SLURM partition (adjust as needed)
- `72` - Duration in hours (optional, default: 72)

**Output:**
```
============================================
Servers Started Successfully!
============================================

Job IDs:
  Grading Server: 4665260
  vLLM Server:    4665262
  Node:           della101

Server Details:
  Model: Qwen3-30b
  Port: 8000
  API Base: http://localhost:8000/v1
  Time Limit: 72:00:00 (72 hours)

To run AIDE agent with this server:
  ./scripts_hpc/launch_aide_agent_only.sh <competition> 30b 4665262 4665260
```

**Save the Job IDs!** You'll use them to submit AIDE jobs.

### Step 2: Run AIDE Agent (any time during 72-hour window)

```bash
# Run the first competition
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262 4665260

# Later, run another competition with same server
./scripts_hpc/launch_aide_agent_only.sh house-prices 30b 4665262 4665260

# Run yet another...
./scripts_hpc/launch_aide_agent_only.sh iris 30b 4665262 4665260
```

**Parameters:**
- `competition` - Competition ID (e.g., spaceship-titanic)
- `30b` or `80b` - Model size (must match the running server!)
- `4665262` - vLLM job ID (from step 1)
- `4665260` - Grading server job ID (from step 1)

### Step 3: Monitor and Manage

**Check if servers are still running:**
```bash
./manage_qwen.sh slurm-status
```

**Monitor AIDE agent:**
```bash
tail -f logs/aide-qwen-<AIDE_JOB_ID>.out
```

**Monitor vLLM server:**
```bash
tail -f logs/vllm-qwen30b-<VLLM_JOB_ID>.out
```

**Cancel AIDE job only (keep vLLM running):**
```bash
scancel <AIDE_JOB_ID>
```

**Cancel both AIDE and vLLM (keep running servers):**
```bash
scancel <AIDE_JOB_ID> <VLLM_JOB_ID>
```

**Cancel everything:**
```bash
scancel <AIDE_JOB_ID> <VLLM_JOB_ID> <GRADING_JOB_ID>
```

---

## Comparison: All-in-One vs. Long-Lived Server

| Feature | All-in-One | Long-Lived Server |
|---------|-----------|------------------|
| **Simplicity** | Very simple (1 command) | Slightly more complex (2 steps) |
| **Server lifetime** | Stops with AIDE | Runs for 72+ hours independently |
| **Multiple AIDE runs** | ✗ Must restart server | ✓ Reuse same server |
| **Resource efficiency** | ✗ Waste startup time | ✓ Efficient |
| **Cost** | Higher (more startup overhead) | Lower (better utilization) |
| **Testing** | Good | Better |
| **Testing pipeline** | Good | ✓ Excellent |
| **Best use case** | Quick tests | Production/scale |

---

## Advanced Usage

### Custom Time Limits

Start server with custom duration:
```bash
# 48 hours
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 48

# 168 hours (7 days, if cluster allows)
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 168
```

### Switch Models Mid-Testing

If you need to test a different model size:
1. Stop the current server: `scancel <VLLM_JOB_ID>`
2. Start new server with different size: `./scripts_hpc/launch_vllm_server_only.sh 80b gpu-short 72`
3. Submit AIDE with new job IDs

### Check Max Time Limits

Different partitions have different time limits:
```bash
sinfo -p gpu-short -o "%20N %10A %20l"
```

This shows the default time limits. vLLM server time can be set up to the partition maximum.

---

## Troubleshooting

### "vLLM server is not responding"

This is normal if the server is still loading. Wait 5-15 minutes and try the AIDE submission again.

### "Could not determine node for vLLM job"

vLLM hasn't been assigned a node yet. Wait a moment and retry:
```bash
sleep 30
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262
```

### "Server doesn't exist" when submitting AIDE

Check if the vLLM job is still running:
```bash
squeue -j 4665262
```

If not running, start a new server:
```bash
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 72
```

### Model mismatch error

Make sure the AIDE job uses the same model size as the running vLLM server:
```bash
# Wrong - 30b server, 80b job
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 80b 4665262

# Correct - both 30b
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262
```

---

## Examples: Real-World Usage

### Example 1: Quick single test
```bash
# Use the original all-in-one script
./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b gpu-short
```

### Example 2: Test multiple competitions
```bash
# Start server (72 hours)
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 72

# ... (note the job IDs printed)
# Grading Server: 4665260
# vLLM Server:    4665262

# Submit multiple AIDE jobs
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262 4665260
./scripts_hpc/launch_aide_agent_only.sh house-prices 30b 4665262 4665260
./scripts_hpc/launch_aide_agent_only.sh iris 30b 4665262 4665260

# Monitor them all
squeue -u $USER
```

### Example 3: Scale testing with 80B model
```bash
# Start larger model server (2 GPUs, 72 hours)
./scripts_hpc/launch_vllm_server_only.sh 80b gpu-short 72

# Job IDs:
# Grading Server: 4665260
# vLLM Server:    4665262

# Submit AIDE with 80B model
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 80b 4665262 4665260
```

### Example 4: Long-running server (+7 days if supported)
```bash
# Check partition limits
sinfo -p gpu-short -o "%20N %10A %20l"

# Start for 168 hours if allowed
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 168

# Submit as many AIDE jobs as needed
./scripts_hpc/launch_aide_agent_only.sh comp1 30b 4665262 4665260
./scripts_hpc/launch_aide_agent_only.sh comp2 30b 4665262 4665260
# ... more competitions
```

---

## Key Differences in Job Behavior

### All-in-One Script (`run_aide_qwen_workflow.sh`)
- ✓ Auto-cleanup enabled by default
- ✓ Single submission point
- ✗ Server dies with AIDE job
- ✓ Best for: Single runs, testing

### Server + Agent Split (`launch_vllm_server_only.sh` + `launch_aide_agent_only.sh`)
- ✓ Server runs independently
- ✓ Submit multiple AIDE jobs
- ✓ Fine-grained control
- ✓ Better resource utilization
- ✓ Best for: Production, scaling, multiple runs

---

## File Locations

- **Workflow scripts**: `scripts_hpc/`
  - `run_aide_qwen_workflow.sh` (all-in-one)
  - `launch_vllm_server_only.sh` (new)
  - `launch_aide_agent_only.sh` (new)

- **SLURM scripts**: `scripts_hpc/`
  - `slurm_grading_server.sh`
  - `slurm_vllm_qwen30b.sh`
  - `slurm_vllm_qwen80b.sh`
  - `slurm_aide_qwen.sh`

- **Containers**: `containers/`
  - `mlebench-env.sif` (grading server)
  - `qwen3-30b-vllm.sif` (vLLM 30B)
  - `qwen3-80b-vllm.sif` (vLLM 80B)
  - `aide-qwen-minimal.sif` (AIDE agent)

- **Logs**: `logs/`
  - `vllm-qwen30b-<JOB_ID>.out`
  - `aide-qwen-<JOB_ID>.out`
  - etc.

- **Results**: `runs/`
  - Timestamped run directories with results

---

## Summary

**For a quick test:** Use `run_aide_qwen_workflow.sh`

**For production/scaling:** Use `launch_vllm_server_only.sh` + `launch_aide_agent_only.sh`

**For full control:** Use the individual SLURM scripts with manual `sbatch` commands
