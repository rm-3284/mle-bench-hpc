#!/bin/bash
#SBATCH --job-name=mlebench-het
#SBATCH --mail-type=BEGIN,END,FAIL
#SBATCH --mail-user=YOUR_EMAIL

# ----- CPU node: grading server -----
#SBATCH --account=YOUR_ACCOUNT
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=4:00:00
#SBATCH --output=slurm_output/mlebench/grading-%j.out

#SBATCH hetjob

# ----- GPU node: agent -----
#SBATCH --partition=YOUR_PARTITION
#SBATCH --qos=YOUR_QOS
#SBATCH --account=YOUR_ACCOUNT
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=4:00:00
#SBATCH --output=slurm_output/mlebench/agent-%j.out

# =============================================================================
# Configuration - MODIFY THESE PATHS
# =============================================================================
COMPETITION="${1:-spaceship-titanic}"
MLEBENCH_DIR="/path/to/mle-bench"          # Path to mle-bench repo
DATA_DIR="/path/to/mlebench/data"          # Path to prepared competition data
SIF_IMAGE="/path/to/images/aide.sif"       # Path to Apptainer image
OUTPUT_BASE="/scratch/$USER/mlebench"      # Base output directory
TIME_LIMIT_SECS=14000                       # Agent time limit (leave buffer)
GRADING_PORT=5000

# =============================================================================
# Setup
# =============================================================================
set -euo pipefail

module purge
module load anaconda3/2024.2
module load apptainer

conda activate YOUR_ENV

OUTPUT_DIR="${OUTPUT_BASE}/${COMPETITION}_${SLURM_JOB_ID}"
mkdir -p "${OUTPUT_DIR}"/{submission,logs,code}
mkdir -p slurm_output/mlebench

echo "=============================================="
echo "MLE-Bench Heterogeneous Job"
echo "=============================================="
echo "Job ID:         $SLURM_JOB_ID"
echo "Competition:    $COMPETITION"
echo "Output Dir:     $OUTPUT_DIR"
echo "=============================================="

# =============================================================================
# Address file
# =============================================================================
ADDR_DIR="$HOME/.mlebench_addresses"
mkdir -p "$ADDR_DIR"
ADDR_FILE="$ADDR_DIR/grading_server_${SLURM_JOB_ID}"
rm -f "$ADDR_FILE"

# =============================================================================
# Start grading server on CPU node (het-group=0)
# =============================================================================
echo "[het-group=0] Starting grading server on CPU node..."

srun --het-group=0 --ntasks=1 bash -lc "
  set -e
  
  GRADING_HOST=\$(hostname -f)
  echo \"http://\${GRADING_HOST}:${GRADING_PORT}\" > \"$ADDR_FILE\"
  echo \"Grading server starting on \${GRADING_HOST}:${GRADING_PORT}\"

  module load anaconda3/2024.2
  conda activate mlebench
  
  python ${MLEBENCH_DIR}/environment/run_grading_server.py \
    --competition-id ${COMPETITION} \
    --data-dir ${DATA_DIR} \
    --host 0.0.0.0 \
    --port ${GRADING_PORT}
" &

GRADING_PID=$!

# =============================================================================
# Wait for grading server address
# =============================================================================
echo "Waiting for grading server to start..."
WAIT_COUNT=0
while [ ! -s "$ADDR_FILE" ]; do
  sleep 1
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -gt 120 ]; then
    echo "ERROR: Grading server did not start within 120 seconds"
    exit 1
  fi
done

GRADING_SERVER=$(<"$ADDR_FILE")
echo "Grading server available at: $GRADING_SERVER"
sleep 5

# =============================================================================
# Run agent on GPU node (het-group=1)
# =============================================================================
echo "[het-group=1] Starting agent on GPU node..."

srun --het-group=1 --ntasks=1 bash -lc "
  set -e
  
  echo \"Agent node: \$(hostname -f)\"
  echo \"Grading server: ${GRADING_SERVER}\"
  
  # Verify grading server is reachable
  if curl -s \"${GRADING_SERVER}/health\" > /dev/null 2>&1; then
    echo \"✓ Grading server is reachable\"
  else
    echo \"✗ Cannot reach grading server at ${GRADING_SERVER}\"
    exit 1
  fi
  
  # Run agent in Apptainer
  apptainer exec --nv \
    --contain \
    --env COMPETITION_ID=${COMPETITION} \
    --env GRADING_SERVER=${GRADING_SERVER} \
    --env TIME_LIMIT_SECS=${TIME_LIMIT_SECS} \
    --bind ${DATA_DIR}/${COMPETITION}/prepared/public:/home/data:ro \
    --bind ${OUTPUT_DIR}/submission:/home/submission \
    --bind ${OUTPUT_DIR}/logs:/home/logs \
    --bind ${OUTPUT_DIR}/code:/home/code \
    ${SIF_IMAGE} \
    /entrypoint_hpc.sh bash /home/agent/start.sh
"

AGENT_EXIT_CODE=$?

# =============================================================================
# Cleanup
# =============================================================================
echo "Agent finished with exit code: $AGENT_EXIT_CODE"
echo "Stopping grading server..."
kill $GRADING_PID 2>/dev/null || true
rm -f "$ADDR_FILE"

echo ""
echo "=============================================="
echo "Results"
echo "=============================================="
echo "Submission: ${OUTPUT_DIR}/submission/"
echo "Logs:       ${OUTPUT_DIR}/logs/"
echo "Code:       ${OUTPUT_DIR}/code/"
echo ""
echo "To grade:"
echo "  mlebench grade --submission ${OUTPUT_DIR}/submission/submission.csv --competition ${COMPETITION}"
echo "=============================================="

