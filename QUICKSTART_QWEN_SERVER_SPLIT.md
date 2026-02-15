# Quick Reference: Qwen vLLM Server + AIDE Agent

## Option 1: All-in-One (Fastest - Everything at once)
```bash
./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b gpu-short
```
✓ Simple | ✗ Server stops with AIDE | Best for: Quick tests

---

## Option 2: Long-Lived Server (Recommended - Keep server running 72 hours)

### Step A: Start vLLM Server
```bash
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 72
```
Output shows:
```
Grading Server: 4665260
vLLM Server:    4665262
```

### Step B: Run AIDE Agent(s) - multiple times
```bash
# First run
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262 4665260

# Second run (reuse same server)
./scripts_hpc/launch_aide_agent_only.sh house-prices 30b 4665262 4665260

# Third run, etc...
./scripts_hpc/launch_aide_agent_only.sh iris 30b 4665262 4665260
```

✓ Reuse server | ✓ Efficient | ✓ Multiple runs | Best for: Production/scaling

---

## Common Commands

```bash
# Check server status
./manage_qwen.sh slurm-status

# Monitor AIDE job logs
tail -f logs/aide-qwen-<JOB_ID>.out

# Monitor vLLM server
tail -f logs/vllm-qwen30b-<JOB_ID>.out

# Cancel AIDE job only (keep server)
scancel <AIDE_JOB_ID>

# Cancel everything
scancel <AIDE_JOB_ID> <VLLM_JOB_ID> <GRADING_JOB_ID>
```

---

## Which Option Should I Use?

| Need | Use |
|------|-----|
| Quick test (1-2 runs) | Option 1 |
| Test multiple competitions | Option 2 |
| Production pipeline | Option 2 |
| Scale testing | Option 2 |
| Custom tuning | Manual scripts |

---

## Model Sizes Available

- `30b` - Qwen3-30B (1 GPU, ~7.4GB container, port 8000)
- `80b` - Qwen3-80B (2 GPUs, ~7.4GB container, port 8001)

**Important:** AIDE model size must match vLLM server model size!

```bash
# Server 30b, AIDE must be 30b
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 72
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262

# ✗ Wrong: Server 30b, AIDE 80b
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 80b 4665262
```

---

## Time Limits

**vLLM Server:**
- Default: 72 hours
- Customize: `./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 120`
- Check partition max: `sinfo -p gpu-short -o "%20N %10A %20l"`

**AIDE Agent:**
- SLURM job limit: 24 hours
- AIDE internal limit: ~3.9 hours (14000 seconds)
- Modify in: `slurm_aide_qwen.sh` line 37

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| vLLM not responding | Wait 5-15 minutes, still loading |
| Server doesn't exist | `squeue -j <JOB_ID>` to verify it's running |
| Model mismatch error | Check AIDE uses same model size as vLLM |
| Job allocation failed | Check GPU partition availability: `sinfo` |
| Out of memory error | Try 30b instead of 80b, or longer time |

---

## Example Workflow

```bash
# 1. Start server (will run for 72 hours)
./scripts_hpc/launch_vllm_server_only.sh 30b gpu-short 72

# Output:
# Grading Server: 4665260
# vLLM Server:    4665262

# 2. Now you can run multiple AIDE jobs during those 72 hours
./scripts_hpc/launch_aide_agent_only.sh spaceship-titanic 30b 4665262 4665260
# Job ID: 4665300

./scripts_hpc/launch_aide_agent_only.sh house-prices 30b 4665262 4665260
# Job ID: 4665301

./scripts_hpc/launch_aide_agent_only.sh iris 30b 4665262 4665260
# Job ID: 4665302

# 3. Check all jobs
squeue -u $USER

# 4. When you're done, cancel everything
scancel 4665300 4665301 4665302 4665262 4665260
```

---

For detailed information, see: `QWEN_SERVER_USAGE_GUIDE.md`
