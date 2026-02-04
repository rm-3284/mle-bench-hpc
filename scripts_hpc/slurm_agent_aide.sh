#!/bin/bash
#SBATCH --job-name=mlebench-aide
#SBATCH --partition=YOUR_PARTITION
#SBATCH --qos=YOUR_QOS
#SBATCH --account=YOUR_ACCOUNT
#SBATCH --nodes=1
#SBATCH --gres=gpu:1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=4:00:00
#SBATCH --output=slurm_output/mlebench/aide-%j.out

# =============================================================================
# AIDE Agent with GPT-4.1/GPT-5 patches
# =============================================================================

COMPETITION="${1:-spaceship-titanic}"
GRADING_SERVER_ARG="${2:-}"
MLEBENCH_DIR="/path/to/mle-bench"
DATA_DIR="/path/to/mlebench/data"
SIF_IMAGE="/path/to/images/aide.sif"
OUTPUT_BASE="/scratch/$USER/mlebench"
TIME_LIMIT_SECS=14000
export OPENAI_API_KEY="YOUR_OPENAI_KEY"

set -eo pipefail

module purge
module load proxy/default

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
    echo "Usage: sbatch slurm_agent_aide.sh <competition> <grading_server_url|auto:job_id>"
    exit 1
fi

OUTPUT_DIR="${OUTPUT_BASE}/${COMPETITION}_${SLURM_JOB_ID}"
mkdir -p "${OUTPUT_DIR}"/{submission,logs,code,workspaces}

echo "=============================================="
echo "AIDE Agent Job (with GPT-4.1/GPT-5 patches)"
echo "=============================================="
echo "Job ID:         $SLURM_JOB_ID"
echo "Competition:    $COMPETITION"
echo "Grading Server: $GRADING_SERVER"
echo "Output Dir:     $OUTPUT_DIR"
echo "Time Limit:     $TIME_LIMIT_SECS seconds"
echo "=============================================="

# =============================================================================
# Check grading server
# =============================================================================
echo "Checking grading server..."
if curl -s "${GRADING_SERVER}/health" > /dev/null 2>&1; then
    echo "Grading server is reachable"
else
    echo "Cannot reach grading server at ${GRADING_SERVER}"
    exit 1
fi

# =============================================================================
# Prepare overlay directory for patched files
# =============================================================================
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

# =============================================================================
# Apply AIDE patches (GPT-4.1/GPT-5 temperature support)
# =============================================================================
echo ""
echo "Applying AIDE patches..."

# Find the Python version in the agent environment (use ls -d to handle glob properly)
PYTHON_SITE_PACKAGES=$(apptainer exec ${SIF_IMAGE} bash -c 'ls -d /opt/conda/envs/agent/lib/python3.*/site-packages 2>/dev/null | tail -1')
echo "Python site-packages: ${PYTHON_SITE_PACKAGES}"

if [ -z "${PYTHON_SITE_PACKAGES}" ]; then
    echo "ERROR: Could not find Python site-packages directory"
    exit 1
fi

# Create patch directories
mkdir -p "${OVERLAY_DIR}/aide_backend"
mkdir -p "${OVERLAY_DIR}/aide_utils"

# Extract and patch backend_openai.py (GPT-4.1/GPT-5 model detection)
echo "Patching backend_openai.py for GPT-4.1/GPT-5 model detection..."
BACKEND_FILE="${PYTHON_SITE_PACKAGES}/aide/backend/backend_openai.py"
apptainer exec ${SIF_IMAGE} cat "${BACKEND_FILE}" > "${OVERLAY_DIR}/aide_backend/backend_openai.py"

# Patch: Change model detection regex to include gpt-4 and gpt-5
# Original: re.match(r"^o\d", filtered_kwargs["model"])
# Patched:  re.match(r"^(o\d|gpt-[45])", filtered_kwargs["model"])
sed -i 's/re\.match(r"^o\\d", filtered_kwargs\["model"\])/re.match(r"^(o\\d|gpt-[45])", filtered_kwargs["model"])/g' \
    "${OVERLAY_DIR}/aide_backend/backend_openai.py"

# Verify patch was applied
if grep -q 'gpt-\[45\]' "${OVERLAY_DIR}/aide_backend/backend_openai.py"; then
    echo "backend_openai.py patch applied successfully"
else
    echo "backend_openai.py patch may not have been applied (pattern not found)"
fi

# Extract and patch config.yaml (temperature settings)
echo "Patching config.yaml for temperature settings..."
CONFIG_FILE="${PYTHON_SITE_PACKAGES}/aide/utils/config.yaml"
apptainer exec ${SIF_IMAGE} cat "${CONFIG_FILE}" > "${OVERLAY_DIR}/aide_utils/config.yaml"

# Patch: Change temperature from 0.5 to 1.0 for code and feedback sections
sed -i '/^  code:/,/^  feedback:/ s/temp: 0\.5/temp: 1.0/' "${OVERLAY_DIR}/aide_utils/config.yaml"
sed -i '/^  feedback:/,/^  search:/ s/temp: 0\.5/temp: 1.0/' "${OVERLAY_DIR}/aide_utils/config.yaml"

# Verify patch was applied
if grep -q 'temp: 1.0' "${OVERLAY_DIR}/aide_utils/config.yaml"; then
    echo "config.yaml patch applied successfully"
else
    echo "config.yaml patch may not have been applied"
fi

echo ""
echo "Patches prepared in: ${OVERLAY_DIR}"

# =============================================================================
# Run AIDE agent with patched files
# =============================================================================
echo ""
echo "Starting AIDE agent..."
unset CONDA_EXE CONDA_PREFIX CONDA_PYTHON_EXE CONDA_DEFAULT_ENV CONDA_SHLVL

apptainer exec --nv \
    --contain \
    --cleanenv \
    --writable-tmpfs \
    --env COMPETITION_ID=${COMPETITION} \
    --env GRADING_SERVER=${GRADING_SERVER} \
    --env TIME_LIMIT_SECS=${TIME_LIMIT_SECS} \
    --env OPENAI_API_KEY=${OPENAI_API_KEY} \
    --bind ${DATA_DIR}/${COMPETITION}/prepared/public:/home/data:ro \
    --bind ${OUTPUT_DIR}/submission:/home/submission \
    --bind ${OUTPUT_DIR}/logs:/home/logs \
    --bind ${OUTPUT_DIR}/code:/home/code \
    --bind ${OUTPUT_DIR}/workspaces:/home/agent/workspaces \
    --bind ${OVERLAY_DIR}/instructions.txt:/home/instructions.txt:ro \
    --bind ${OVERLAY_DIR}/instructions_obfuscated.txt:/home/instructions_obfuscated.txt:ro \
    --bind ${OVERLAY_DIR}/validate_submission.sh:/home/validate_submission.sh:ro \
    --bind ${OVERLAY_DIR}/aide_backend/backend_openai.py:${PYTHON_SITE_PACKAGES}/aide/backend/backend_openai.py:ro \
    --bind ${OVERLAY_DIR}/aide_utils/config.yaml:${PYTHON_SITE_PACKAGES}/aide/utils/config.yaml:ro \
    ${SIF_IMAGE} \
    /entrypoint_hpc.sh bash /home/agent/start.sh

AGENT_EXIT_CODE=$?

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
echo "AIDE Agent finished with exit code: $AGENT_EXIT_CODE"
echo "=============================================="
echo "Submission: ${OUTPUT_DIR}/submission/"
echo "Logs:       ${OUTPUT_DIR}/logs/"
echo "Code:       ${OUTPUT_DIR}/code/"
echo ""
echo "To grade:"
echo "  mlebench grade --submission ${OUTPUT_DIR}/submission/submission.csv --competition ${COMPETITION}"
echo "=============================================="

