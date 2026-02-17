# Running MLE-Bench with AIDE and Qwen Models on HPC

This repository enables running MLE-Bench experiments on HPC clusters using Slurm, Apptainer containers, and AIDE agents powered by Qwen language models. The system separates the grading server (with access to private data) from the agent (without access to private data) into different containers for security.

## Table of Contents

1. [Overview & Architecture](#overview--architecture)
2. [General Workflow](#general-workflow)
3. [Building Containers](#building-containers)
4. [Running Experiments](#running-experiments)
5. [Checking Results](#checking-results)

## Overview & Architecture

### Security Model

The agent must not have access to private test answers. To enforce this while still allowing validation:
- **Grading Server**: Runs in an Apptainer container with access to private benchmark data
- **vLLM Server**: Runs in a separate container with Qwen language models
- **AIDE Agent**: Runs in a separate container without access to private data
- **Communication**: Agent validates submissions via HTTP (`http://<grading-server>:5000/validate`)

### Container Structure

| Container | Purpose | GPU Required | Mount Points |
|-----------|---------|--------------|--------------|
| `mlebench-env.sif` | Grading server | No (CPU) | Private test data |
| `qwen3-30b-vllm.sif` | Qwen3-30B language model | 1× GPU | Model cache |
| `qwen3-80b-vllm.sif` | Qwen3-80B language model | 2× GPU | Model cache |
| `aide-qwen-minimal.sif` | AIDE agent executor | No (CPU) | Submission/logs/code dirs |

---

## Getting Started: Setup Your Cluster

### Clone the Repository

```bash
git clone https://github.com/your-org/mle-bench-hpc.git
cd mle-bench-hpc
```

### Critical Path Configuration

After cloning, you **must** update paths in several files to match your cluster's environment. Use this checklist:

#### 1. **`scripts_hpc/run_aide_qwen_workflow.sh`** (Workflow orchestrator)

This script launches all jobs and handles inter-service communication. No explicit path changes needed here—it uses relative paths. However, verify the location you run it from.

#### 2. **`scripts_hpc/slurm_grading_server.sh`** (Grading server)

Update these variables at the top of the file:

```bash
MLEBENCH_DIR="/path/to/your/mle-bench-hpc"    # Change this to your repo location
DATA_DIR="/path/to/benchmark/data"             # Change to your data directory
SIF_IMAGE="${MLEBENCH_DIR}/containers/mlebench-env.sif"  # Typically no change needed
GRADING_PORT=5000  # Change if port 5000 is unavailable
```

**Example for Princeton Della cluster:**
```bash
MLEBENCH_DIR="/home/username/projects/mle-bench-hpc"
DATA_DIR="/scratch/gpfs/username/mle-cache/data"
```

#### 3. **`scripts_hpc/slurm_vllm_qwen30b.sh`** and **`slurm_vllm_qwen80b.sh`** (vLLM servers)

Update the HuggingFace cache directory (model cache location):

```bash
HF_HOME=${HF_HOME:-"/path/to/huggingface-cache"}  # Change to your cache location
```

**Optional:** Adjust SLURM parameters if your cluster uses different names:
```bash
#SBATCH --partition=ailab          # Change to your GPU partition name
#SBATCH --qos=YOUR_QOS             # Add QOS if required
#SBATCH --account=YOUR_ACCOUNT     # Add account if required
```

**Example:**
```bash
#SBATCH --partition=gpu            # Use your actual GPU partition
HF_HOME="/scratch/gpfs/username/huggingface-cache"
```

#### 4. **`scripts_hpc/slurm_agent_aide.sh`** (AIDE agent)

Update these variables:

```bash
COMPETITION="${1:-spaceship-titanic}"   # Default competition (can override per run)
MLEBENCH_DIR="/path/to/your/mle-bench-hpc"  # Must match slurm_grading_server.sh
DATA_DIR="/path/to/benchmark/data"          # Must match slurm_grading_server.sh
SIF_IMAGE="/path/to/images/aide-qwen-minimal.sif"  # Path to AIDE container
OUTPUT_BASE="/path/to/output/directory"     # Where to save results
export OPENAI_API_KEY="YOUR_OPENAI_KEY"     # Optional: if using GPT-4 fallback
TIME_LIMIT_SECS=14000   # Adjust based on your cluster limits
```

**Optional:** Adjust SLURM parameters:
```bash
#SBATCH --partition=YOUR_PARTITION  # GPU partition for agent
#SBATCH --qos=YOUR_QOS
#SBATCH --account=YOUR_ACCOUNT
#SBATCH --cpus-per-task=8          # Adjust based on your cluster
#SBATCH --mem=32G                  # Adjust based on your cluster
#SBATCH --time=4:00:00             # Adjust job time limit
```

**Example:**
```bash
MLEBENCH_DIR="/home/username/projects/mle-bench-hpc"
DATA_DIR="/scratch/gpfs/username/mle-cache/data"
SIF_IMAGE="/home/username/projects/mle-bench-hpc/containers/aide-qwen-minimal.sif"
OUTPUT_BASE="/scratch/username/mlebench-results"
```

### Path Configuration Summary Table

| File | Variable | What to Change | Example Value |
|------|----------|---|---|
| `slurm_grading_server.sh` | `MLEBENCH_DIR` | Repository location | `/home/user/mle-bench-hpc` |
| `slurm_grading_server.sh` | `DATA_DIR` | MLE-Bench test data | `/scratch/gpfs/user/mle-cache/data` |
| `slurm_grading_server.sh` | `GRADING_PORT` | Port (if 5000 occupied) | `5000` |
| `slurm_vllm_qwen30b.sh` | `HF_HOME` | Model cache directory | `/scratch/gpfs/user/hf-cache` |
| `slurm_vllm_qwen30b.sh` | `#SBATCH --partition` | GPU partition name | `gpu` |
| `slurm_vllm_qwen80b.sh` | `HF_HOME` | Model cache directory | `/scratch/gpfs/user/hf-cache` |
| `slurm_vllm_qwen80b.sh` | `#SBATCH --partition` | GPU partition name | `gpu` |
| `slurm_agent_aide.sh` | `MLEBENCH_DIR` | Repository location | `/home/user/mle-bench-hpc` |
| `slurm_agent_aide.sh` | `DATA_DIR` | MLE-Bench test data | `/scratch/gpfs/user/mle-cache/data` |
| `slurm_agent_aide.sh` | `SIF_IMAGE` | AIDE container location | `/home/user/mle-bench-hpc/containers/aide-qwen-minimal.sif` |
| `slurm_agent_aide.sh` | `OUTPUT_BASE` | Results output directory | `/scratch/user/mlebench-results` |
| `slurm_agent_aide.sh` | `OPENAI_API_KEY` | OpenAI key (optional) | `sk-...` |
| `slurm_agent_aide.sh` | `#SBATCH --partition` | Partition name | `cpu` |

### Finding Your Cluster's Values

**To find partition names:**
```bash
sinfo -o "%20P %3a %8t %4D"
```

**To find account/QOS (if required):**
```bash
sacctmgr show user $USER
```

**To verify storage paths:**
```bash
df -h /scratch/gpfs/$USER  # HPC scratch space
df -h /home/$USER          # Home directory
```

---

## General Workflow

The complete workflow consists of the following steps:

### Step 1: Build Containers (One-time Setup)

```bash
cd containers
./build_all_containers.sh
```

This builds:
- MLEBench grading server image (~2-3GB)
- Qwen 30B vLLM server image (~4-5GB)
- Qwen 80B vLLM server image (~4-5GB)
- AIDE agent image (~1-2GB)

**Total time**: 60-120 minutes

### Step 2: Submit Experiment Workflow

Submit a complete end-to-end experiment with one command:

```bash
./scripts_hpc/run_aide_qwen_workflow.sh <competition> [model_size] [vllm_partition] [agent_partition]
```

Example:
```bash
./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b gpu cpu on
```

This automatically:
1. Launches grading server job
2. Launches vLLM model server job
3. Launches AIDE agent job
4. Waits for each service to be ready before starting the next
5. Monitors progress throughout

### Step 3: Monitor Progress

```bash
# Check job status
squeue -u $USER

# View agent logs
tail -f logs/aide-<job-id>.out

# View vLLM model loading progress
tail -f logs/vllm-qwen30b-<job-id>.out
```

### Step 4: Check Results

After the agent finishes, results are in the `runs/` directory:

```bash
ls -la runs/
cat runs/*/grading_report.json
```

---

## Building Containers

### Prerequisites

- Apptainer (version 1.0+)
- At least 50GB free disk space (for all containers)
- Sufficient time (60-120 minutes for all builds)

### Container Build Files

Definition files are located in `containers/`:
- `mlebench-env.def` - MLEBench base environment
- `qwen3-30b-vllm.def` - Qwen3-30B model server
- `qwen3-80b-vllm.def` - Qwen3-80B model server
- `aide-qwen-minimal.def` - AIDE agent

### Build Options

#### Option A: Build All Containers (Recommended)

```bash
cd containers
chmod +x *.sh
./build_all_containers.sh
```

This builds all four containers sequentially. The script handles any build failures gracefully.

#### Option B: Build Individually

Build specific containers as needed:

```bash
cd containers

# Build MLEBench grading server (30-40 min)
apptainer build --fakeroot mlebench-env.sif mlebench-env.def

# Build Qwen3-30B vLLM server (20-30 min)
apptainer build --fakeroot qwen3-30b-vllm.sif qwen3-30b-vllm.def

# Build Qwen3-80B vLLM server (20-30 min)
apptainer build --fakeroot qwen3-80b-vllm.sif qwen3-80b-vllm.def

# Build AIDE agent (15-25 min)
apptainer build --fakeroot aide-qwen-minimal.sif aide-qwen-minimal.def
```

#### Monitoring Builds

Builds run in the foreground. For longer builds, use tmux/screen:

```bash
tmux new-session -d -s build
tmux send-keys -t build "cd containers && ./build_all_containers.sh" Enter
tmux attach -t build
```

Monitor disk usage:
```bash
watch -n 5 'ls -lh containers/*.sif'
```

### Container Details

#### MLEBench Grading Server (`mlebench-env.sif`)

- **Base image**: Conda environment with MLEBench installed
- **Python packages**: mlebench, pandas, scikit-learn, etc.
- **Purpose**: Runs the grading server with access to private test data
- **CPU**: 2 cores, 8GB RAM sufficient (see `slurm_grading_server.sh`)
- **Size**: ~2-3GB

#### Qwen3-30B vLLM Server (`qwen3-30b-vllm.sif`)

- **Model**: Qwen/Qwen3-30B-A3B-Instruct-2507
- **Framework**: vLLM for efficient inference
- **Requirements**: 1× GPU (typically A40 or better), 64GB RAM
- **Port**: 8000
- **Size**: ~4-5GB loaded into memory

#### Qwen3-80B vLLM Server (`qwen3-80b-vllm.sif`)

- **Model**: Qwen/Qwen3-Next-80B-A3B-Instruct
- **Framework**: vLLM with tensor parallelism
- **Requirements**: 2× GPUs, 80GB RAM
- **Port**: 8001
- **Size**: ~4-5GB loaded into memory per GPU

#### AIDE Agent (`aide-qwen-minimal.sif`)

- **Framework**: AIDE (AI Data Exploration)
- **Dependencies**: No private data access, connects to vLLM and grading servers via HTTP
- **GPU**: Not required (CPU only)
- **Resources**: 8 CPUs, 32GB RAM (see `slurm_agent_aide.sh`)
- **Size**: ~1-2GB

---

## Running Experiments

### Prerequisites: Download Benchmark Data

Before running any experiments, you must download the competition data using the MLE-Bench client:

```bash
# Install mlebench if you haven't already
pip install mle-bench

# Download data for a specific competition
mlebench download <competition-id> --data-dir /path/to/mle-cache/data

# Example: Download spaceship-titanic data
mlebench download spaceship-titanic --data-dir /scratch/gpfs/$USER/mle-cache/data

# List available competitions
mlebench list competitions
```

The `DATA_DIR` path you set in the SLURM scripts must point to where you downloaded this data.

### API Keys & Environment Configuration

If your agent configuration uses external models (OpenAI GPT, Google Gemini, etc.), you need to create a `.env` file with your API keys.

**Create `.env` file in your repo root:**

```bash
cat > /path/to/mle-bench-hpc/.env << 'EOF'
# OpenAI API key (if using GPT models as fallback)
OPENAI_API_KEY="sk-your-key-here"

# Google Gemini API key (if using Gemini models)
GEMINI_API_KEY="your-gemini-key-here"

# HuggingFace token (for model access)
HUGGINGFACE_HUB_TOKEN="hf_your-token-here"
EOF
```

The AIDE container will automatically load this `.env` file from `/home/agent/.env` (which is the mounted `.env` in the container). See `scripts_hpc/aide_start_qwen.sh` for details.

### Quick Start: Run Full Workflow

The easiest way to run an experiment is with the automated workflow script:

```bash
./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b
```

This handles all steps automatically. Skip ahead to [Checking Results](#checking-results).

### Manual Workflow (Advanced)

If you need more control, run each step manually.

#### Step 1: Configure Paths

Edit the following scripts to set your cluster paths:

**`scripts_hpc/slurm_grading_server.sh`**:
```bash
MLEBENCH_DIR="/path/to/mle-bench-hpc"
DATA_DIR="/path/to/benchmark/data"
SIF_IMAGE="${MLEBENCH_DIR}/containers/mlebench-env.sif"
```

**`scripts_hpc/slurm_vllm_qwen30b.sh`** (or `qwen80b.sh`):
```bash
export HF_HOME="/path/to/huggingface-cache"  # For model caching
```

**`scripts_hpc/slurm_agent_aide.sh`**:
```bash
MLEBENCH_DIR="/path/to/mle-bench-hpc"
DATA_DIR="/path/to/benchmark/data"
OUTPUT_BASE="/path/to/output"
export OPENAI_API_KEY="sk-..."  # If using OpenAI fallback
```

#### Step 2: Start the Grading Server

```bash
GRADING_JOB=$(sbatch --parsable scripts_hpc/slurm_grading_server.sh spaceship-titanic)
echo "Grading server job: $GRADING_JOB"

# Wait for it to be ready (check logs)
tail -f slurm_output/mlebench/grading-${GRADING_JOB}.out
```

Once the grading server is running, note the address (e.g., `http://node123:5000`).

#### Step 3: Start the vLLM Server

```bash
# For 30B model (requires 1 GPU)
VLLM_JOB=$(sbatch --parsable --partition=gpu scripts_hpc/slurm_vllm_qwen30b.sh)

# Or for 80B model (requires 2 GPUs)
VLLM_JOB=$(sbatch --parsable --partition=gpu scripts_hpc/slurm_vllm_qwen80b.sh)

echo "vLLM server job: $VLLM_JOB"

# Monitor loading (takes 5-15 minutes)
tail -f logs/vllm-qwen30b-${VLLM_JOB}.out
```

Wait for the message: `"vLLM server is loaded and responding"`.

#### Step 4: Start the AIDE Agent

Once both servers are running:

```bash
# Using auto-discovery (recommended)
sbatch --parsable scripts_hpc/slurm_agent_aide.sh spaceship-titanic auto:${GRADING_JOB}

# Or with explicit server URL
sbatch --parsable scripts_hpc/slurm_agent_aide.sh spaceship-titanic http://node123:5000
```

Watch the agent run:
```bash
tail -f slurm_output/mlebench/aide-${AGENT_JOB}.out
```

#### Step 5: Cleanup

After the agent finishes, stop the helper servers:

```bash
scancel $GRADING_JOB $VLLM_JOB
```

Or configure automatic cleanup by using the workflow script with `cleanup=on`.

### Script Reference

| Script | Purpose | Arguments |
|--------|---------|-----------|
| `run_aide_qwen_workflow.sh` | Full automated workflow | `<competition> [model_size] [vllm_partition] [agent_partition] [cleanup]` |
| `slurm_grading_server.sh` | Start grading server | `<competition>` |
| `slurm_vllm_qwen30b.sh` | Start Qwen 30B server | None (configure in script) |
| `slurm_vllm_qwen80b.sh` | Start Qwen 80B server | None (configure in script) |
| `slurm_agent_aide.sh` | Start AIDE agent | `<competition> <grading_server_url\|auto:job_id>` |

---

## Checking Results

### Output Directory Structure

Experiment results are organized by timestamp in the `runs/` directory:

```
runs/
├── 2026-02-17T18-40-12-UTC_run-group_aide/
│   └── spaceship-titanic_<SLURM_JOB_ID>/
│       ├── logs/
│       │   ├── journal.json                 # Complete agent trace & reasoning
│       │   └── <other log files>
│       ├── code/                            # Generated code solutions
│       ├── submission/                      # Final submissions
│       └── workspaces/                      # Working directories
├── 2026-02-18T10-30-45-UTC_run-group_aide/
│   └── spaceship-titanic_<SLURM_JOB_ID>/
│       ├── logs/
│       │   └── journal.json
│       └── ...
└── ...
```

Each run directory corresponds to one AIDE agent execution. The directory naming follows the pattern:
`<ISO-TIMESTAMP>_run-group_aide/`

Inside each timestamp directory, there's a subdirectory for each competition run: `<competition>_<SLURM_JOB_ID>/`

### Viewing Results

#### Quick Summary

```bash
# List all runs
ls -lh runs/

# View the latest run timestamp
ls -t runs/ | head -1
```

#### Journal Data (Complete Agent Trace)

The most comprehensive data is in `logs/journal.json` - it contains the complete agent reasoning, step-by-step actions, and outputs:

```bash
# View the latest journal
latest_journal=$(find runs -name "journal.json" -type f | sort -r | head -1)
cat "$latest_journal" | jq '.' | less

# View a specific run's journal
cat runs/2026-02-17T18-40-12-UTC_run-group_aide/spaceship-titanic_4835099/logs/journal.json | jq '.'

# Extract specific information from journal
cat "$latest_journal" | jq '.messages[]'  # View all messages
cat "$latest_journal" | jq '.messages[] | select(.type=="tool_use")'  # View tool calls only
```

The `journal.json` file contains:
- All agent reasoning and decision-making
- Tool calls and their outputs
- Code generated and executed
- Submission attempts and results
- Detailed timestamps for each action

#### Visualize Results with Dashboard

To better understand agent performance and behavior across multiple runs, use the [MLE-Bench Dashboard Visualization](https://github.com/rm-3284/MLE-Bench-Dashboard-Visualization):

```bash
# Clone the visualization repo
git clone https://github.com/rm-3284/MLE-Bench-Dashboard-Visualization.git
cd MLE-Bench-Dashboard-Visualization

# Point it to your runs directory and visualize
python visualize.py --runs-dir /path/to/mle-bench-hpc/runs
```

The dashboard provides:
- Performance metrics across runs
- Agent action timelines
- Code quality analysis
- Submission accuracy trends

### Monitoring Long-Running Experiments

For experiments that take hours or days:

```bash
# Monitor in real-time
watch -n 30 'ls -lhrt runs | tail -10'

# Check agent progress
tail -f slurm_output/mlebench/aide-<job_id>.out

# Check for any errors
grep -i "error\|fail" slurm_output/mlebench/aide-<job_id>.out
```

### Troubleshooting Failed Experiments

If an experiment fails, check the logs in this order:

1. **SLURM job status**:
   ```bash
   squeue -j <job_id>
   scancel -p <job_id>  # View formatted output
   ```

2. **Agent logs**:
   ```bash
   cat slurm_output/mlebench/aide-<job_id>.out
   ```

3. **Grading server logs**:
   ```bash
   cat slurm_output/mlebench/grading-<job_id>.out
   ```

4. **vLLM server logs**:
   ```bash
   cat logs/vllm-qwen30b-<job_id>.out
   ```

### Comparing Multiple Runs

```bash
# Compare scores across multiple runs
for dir in runs/*/; do
    echo "=== $(basename "$dir") ==="
    cat "$dir/grading_report.json" | jq '.total_score'
done

# Export to CSV for analysis
for dir in runs/*/; do
    echo "$(basename "$dir"),$(cat "$dir/grading_report.json" | jq '.total_score')"
done > results.csv
```

---

## Troubleshooting

### Common Issues

#### Grading server not responding
- Check if the job is running: `squeue -j <job_id>`
- View logs: `cat slurm_output/mlebench/grading-<job_id>.out`
- Verify address file exists: `ls -la ~/.mlebench_addresses/`

#### vLLM server stuck loading model
- Normal for first load (5-15 minutes)
- Check GPU allocation: `nvidia-smi` on the node
- View detailed logs: `tail -f logs/vllm-qwen30b-<job_id>.out`

#### Agent fails to connect to servers
- Verify firewall allows inter-node communication
- Check network connectivity: `ping <node-address>`
- Ensure both grading and vLLM servers are fully started before agent

#### Out of memory errors
- Increase `--mem` in SLURM scripts
- Reduce batch size in agent configuration
- Use 30B model instead of 80B if available

#### Missing API keys or .env errors
- Ensure `.env` file exists in your repo root directory (same location as `README.md`)
- The AIDE container will automatically load it from `/home/agent/.env`
- Check that all required API keys are set (OPENAI_API_KEY, GEMINI_API_KEY, etc.)
- View `scripts_hpc/aide_start_qwen.sh` to see how .env is loaded in the container

### Getting Help

For issues with:
- **MLE-Bench**: See [MLE-Bench GitHub](https://github.com/openai/mle-bench/blob/main/README.md)
- **AIDE**: Check `aideml/` directory in this repository
- **Qwen models**: Refer to [Qwen GitHub](https://github.com/QwenLM/Qwen)
- **Apptainer**: See [Apptainer documentation](https://apptainer.org/docs/)
