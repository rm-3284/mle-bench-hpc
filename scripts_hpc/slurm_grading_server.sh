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
MLEBENCH_DIR="/path/to/mle-bench"
DATA_DIR="/path/to/mlebench/data"
GRADING_PORT=5000

set -euo pipefail

module purge
module load anaconda3/2024.2
conda activate YOUR_ENV

mkdir -p slurm_output/mlebench

ADDR_DIR="$HOME/.mlebench_addresses"
mkdir -p "$ADDR_DIR"
ADDR_FILE="$ADDR_DIR/grading_server_${SLURM_JOB_ID}"

GRADING_HOST=$(hostname -f)
echo "http://${GRADING_HOST}:${GRADING_PORT}" > "$ADDR_FILE"

echo "=============================================="
echo "Grading Server"
echo "=============================================="
echo "Job ID:      $SLURM_JOB_ID"
echo "Competition: $COMPETITION"
echo "Host:        $GRADING_HOST"
echo "Port:        $GRADING_PORT"
echo "Address:     http://${GRADING_HOST}:${GRADING_PORT}"
echo ""
echo "Address file: $ADDR_FILE"
echo ""
echo "Use this in agent job:"
echo "  GRADING_SERVER=http://${GRADING_HOST}:${GRADING_PORT}"
echo "=============================================="

python "${MLEBENCH_DIR}/environment/run_grading_server.py" \
    --competition-id "$COMPETITION" \
    --data-dir "$DATA_DIR" \
    --host 0.0.0.0 \
    --port "$GRADING_PORT"

