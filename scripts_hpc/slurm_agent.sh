#!/bin/bash
#SBATCH --job-name=mlebench-agent
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

COMPETITION="${1:-spaceship-titanic}"
GRADING_SERVER_ARG="${2:-}"
MLEBENCH_DIR="/path/to/mle-bench"
DATA_DIR="/path/to/mlebench/data"
SIF_IMAGE="/path/to/images/aide.sif"
OUTPUT_BASE="/scratch/$USER/mlebench"
TIME_LIMIT_SECS=14000

set -eo pipefail

module purge

mkdir -p slurm_output/mlebench

if [[ "$GRADING_SERVER_ARG" == auto:* ]]; then
    GRADING_JOB_ID="${GRADING_SERVER_ARG#auto:}"
    ADDR_FILE="$HOME/.mlebench_addresses/grading_server_${GRADING_JOB_ID}"
    if [ ! -f "$ADDR_FILE" ]; then
        echo "ERROR: Address file not found: $ADDR_FILE"
        echo "Make sure grading server job $GRADING_JOB_ID is running"
        exit 1
    fi
    GRADING_SERVER=$(<"$ADDR_FILE")
elif [ -n "$GRADING_SERVER_ARG" ]; then
    GRADING_SERVER="$GRADING_SERVER_ARG"
else
    echo "ERROR: Grading server URL required"
    exit 1
fi

OUTPUT_DIR="${OUTPUT_BASE}/${COMPETITION}_${SLURM_JOB_ID}"
mkdir -p "${OUTPUT_DIR}"/{submission,logs,code}

echo "=============================================="
echo "Agent Job"
echo "=============================================="
echo "Job ID:         $SLURM_JOB_ID"
echo "Competition:    $COMPETITION"
echo "Grading Server: $GRADING_SERVER"
echo "Output Dir:     $OUTPUT_DIR"
echo "Time Limit:     $TIME_LIMIT_SECS seconds"
echo "=============================================="

echo "Checking grading server..."
if curl -s "${GRADING_SERVER}/health" > /dev/null 2>&1; then
    echo "Grading server is reachable"
else
    echo "Cannot reach grading server at ${GRADING_SERVER}"
    exit 1
fi

OVERLAY_DIR="${OUTPUT_DIR}/overlay"
mkdir -p "${OVERLAY_DIR}"

echo "Preparing instruction files with grading server URL: ${GRADING_SERVER}"

# Extract and modify instructions.txt
apptainer exec ${SIF_IMAGE} cat /home/instructions.txt > "${OVERLAY_DIR}/instructions.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/instructions.txt"

# Extract and modify instructions_obfuscated.txt
apptainer exec ${SIF_IMAGE} cat /home/instructions_obfuscated.txt > "${OVERLAY_DIR}/instructions_obfuscated.txt"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/instructions_obfuscated.txt"

# Extract and modify validate_submission.sh
apptainer exec ${SIF_IMAGE} cat /home/validate_submission.sh > "${OVERLAY_DIR}/validate_submission.sh"
sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" "${OVERLAY_DIR}/validate_submission.sh"
chmod +x "${OVERLAY_DIR}/validate_submission.sh"

echo "Starting agent..."
unset CONDA_EXE CONDA_PREFIX CONDA_PYTHON_EXE CONDA_DEFAULT_ENV CONDA_SHLVL

# Add --nv flag below if GPU is needed
apptainer exec \
    --contain \
    --cleanenv \
    --env COMPETITION_ID=${COMPETITION} \
    --env GRADING_SERVER=${GRADING_SERVER} \
    --env TIME_LIMIT_SECS=${TIME_LIMIT_SECS} \
    --bind ${DATA_DIR}/${COMPETITION}/prepared/public:/home/data:ro \
    --bind ${OUTPUT_DIR}/submission:/home/submission \
    --bind ${OUTPUT_DIR}/logs:/home/logs \
    --bind ${OUTPUT_DIR}/code:/home/code \
    --bind ${OVERLAY_DIR}/instructions.txt:/home/instructions.txt:ro \
    --bind ${OVERLAY_DIR}/instructions_obfuscated.txt:/home/instructions_obfuscated.txt:ro \
    --bind ${OVERLAY_DIR}/validate_submission.sh:/home/validate_submission.sh:ro \
    ${SIF_IMAGE} \
    /entrypoint_hpc.sh bash /home/agent/start.sh

AGENT_EXIT_CODE=$?

echo ""
echo "=============================================="
echo "Agent finished with exit code: $AGENT_EXIT_CODE"
echo "=============================================="
echo "Submission: ${OUTPUT_DIR}/submission/"
echo "Logs:       ${OUTPUT_DIR}/logs/"
echo "Code:       ${OUTPUT_DIR}/code/"
echo ""
echo "To grade:"
echo "  mlebench grade --submission ${OUTPUT_DIR}/submission/submission.csv --competition ${COMPETITION}"
echo "=============================================="
