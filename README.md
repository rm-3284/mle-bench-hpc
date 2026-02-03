# Running MLE-Bench on a Slurm-based cluster with Apptainer

The goal of this fork is to run MLE-Bench agents on a Slurm-based cluster that use Apptainer instead of Docker, and circumvent the root/user separation.

## What To Look Out For

The agent must not have access to private test answers. This is why the root/user separation exists in the initial MLE-Bench project (grading server and agent are being run inside the same container). To go around it, we:
- Run the grading server as a separate process with access to private data
- Run the agent in an Apptainer container without private data mounted
- Agent validates submissions via HTTP (`http://<grading-server>:5000/validate`)

## Pre-requisites
We assume familiarity with MLE-Bench; if you need setup information, see the [MLE-Bench ReadMe](https://github.com/openai/mle-bench/blob/main/README.md).

## Step 1: Build Apptainer Image

> **Note**: If you are on an arm64 machine, you probably need to add ```--platform=linux/amd64``` when building locally.

On a machine with Docker access:

```bash
# Build Docker images
docker build -t mlebench-env -f environment/Dockerfile .
docker build -t aide agents/aide/ \
    --build-arg SUBMISSION_DIR=/home/submission \
    --build-arg LOGS_DIR=/home/logs \
    --build-arg CODE_DIR=/home/code \
    --build-arg AGENT_DIR=/home/agent
```

Then you can save your docker as .tar file, transfer to HPC and convert:
```
apptainer build aide.sif docker-archive://aide.tar
```

<details>
    <summary>For Princeton University users</summary>
    ```scp aide.tar netid@della.princeton.edu:/home/netid/path/to/save/```
</details>

## Step 2: Start Grading Server (Manual Method)

> **Note**: If using the heterogeneous job script (`scripts_hpc/slurm_hetjob.sh`), skip to Step 4. The script handles Steps 2-3 automatically.

### Option A: SLURM Job

```bash
# Edit paths in script first, then:
sbatch scripts_hpc/slurm_grading_server.sh spaceship-titanic

# Check output for the grading server URL
cat slurm_output/mlebench/grading-<jobid>.out
```

### Option B: Interactive

On a node that has access to the private test data:

```bash
python environment/run_grading_server.py \
    --competition-id spaceship-titanic \
    --data-dir /path/to/mlebench/data \
    --port 5000
```

## Step 3: Run Agent (Manual Method)

### Option A: SLURM Job

```bash
# With explicit grading server URL:
sbatch scripts_hpc/slurm_agent.sh spaceship-titanic http://node123:5000

# Or auto-discover from grading job ID:
sbatch scripts_hpc/slurm_agent.sh spaceship-titanic auto:<grading-job-id>
```

### Option B: Interactive

On a compute node:

```bash
COMPETITION="spaceship-titanic"
GRADING_SERVER="http://grading-node:5000"  # URL of grading server from Step 2
OUTPUT_DIR="/scratch/$USER/run_001"

mkdir -p ${OUTPUT_DIR}/{submission,logs,code}

apptainer exec --nv \
    --contain \
    --env COMPETITION_ID=${COMPETITION} \
    --env GRADING_SERVER=${GRADING_SERVER} \
    --env TIME_LIMIT_SECS=14400 \
    --bind /path/to/data/${COMPETITION}/prepared/public:/home/data:ro \
    --bind ${OUTPUT_DIR}/submission:/home/submission \
    --bind ${OUTPUT_DIR}/logs:/home/logs \
    --bind ${OUTPUT_DIR}/code:/home/code \
    aide.sif \
    /entrypoint_hpc.sh bash /home/agent/start.sh
```

## Step 4: Grade Submission

After the agent finishes:

```bash
mlebench grade \
    --submission ${OUTPUT_DIR}/submission/submission.csv \
    --competition ${COMPETITION}
```

## SLURM Heterogeneous Job

Use a heterogeneous job to schedule grading server on CPU and agent on GPUs together:

```bash
sbatch scripts_hpc/slurm_hetjob.sh spaceship-titanic
```

Make sure to edit `scripts_hpc/slurm_hetjob.sh` to set your paths:
- `MLEBENCH_DIR`: path to mle-bench repo
- `DATA_DIR`: path to data  
- `SIF_IMAGE`: path to Apptainer image
- `OUTPUT_BASE`: base output directory