#!/bin/bash
#SBATCH --job-name=mlebench-grading
#SBATCH --account=YOUR_ACCOUNT
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=6:00:00
#SBATCH --output=slurm_output/mlebench/grading-%j.out

COMPETITION="${1:-spaceship-titanic}"
DATA_DIR="/scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc/data"
SIF_IMAGE="/scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc/containers/mlebench-env.sif"
GRADING_PORT=5000

set -eo pipefail

module purge

mkdir -p slurm_output/mlebench

ADDR_DIR="$HOME/.mlebench_addresses"
mkdir -p "$ADDR_DIR"
ADDR_FILE="$ADDR_DIR/grading_server_${SLURM_JOB_ID}"

GRADING_HOST=$(hostname -f)
echo "http://${GRADING_HOST}:${GRADING_PORT}" > "$ADDR_FILE"

echo "=============================================="
echo "Grading Server (Containerized)"
echo "=============================================="
echo "Job ID:      $SLURM_JOB_ID"
echo "Competition: $COMPETITION"
echo "Host:        $GRADING_HOST"
echo "Port:        $GRADING_PORT"
echo "Address:     http://${GRADING_HOST}:${GRADING_PORT}"
echo "Image:       $SIF_IMAGE"
echo ""
echo "Address file: $ADDR_FILE"
echo ""
echo "Use this in agent job:"
echo "  sbatch slurm_agent.sh ${COMPETITION} auto:${SLURM_JOB_ID}"
echo "=============================================="

apptainer exec \
    --contain \
    --cleanenv \
    --no-home \
    --writable-tmpfs \
    --pwd /tmp \
    --bind ${DATA_DIR}:/data:ro \
    ${SIF_IMAGE} \
    /opt/conda/bin/conda run -n mleb python /mlebench/environment/run_grading_server.py \
        --competition-id "${COMPETITION}" \
        --data-dir /data \
        --host 0.0.0.0 \
        --port ${GRADING_PORT}


