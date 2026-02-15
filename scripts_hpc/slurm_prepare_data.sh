#!/bin/bash
#SBATCH --job-name=mlebench-prepare
#SBATCH --output=logs/prepare-%j.out
#SBATCH --error=logs/prepare-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=48:00:00
#SBATCH --account=mle_agent

# Script to prepare MLE-bench data using conda

set -e

MLEBENCH_DIR="$(pwd)"
PREPARE_TYPE="${1:-lite}"  # lite, all, or competition name

echo "========================================"
echo "MLE-bench Data Preparation"
echo "========================================"
echo "Job ID:         $SLURM_JOB_ID"
echo "Node:           $SLURM_NODELIST"
echo "Preparation:    $PREPARE_TYPE"
echo "Data Directory: ${MLEBENCH_DIR}/data"
echo ""

# Create conda environment with Python 3.11
echo "Setting up Python 3.11 conda environment..."
conda create -n mlebench_prep python=3.11 -y -q

# Activate environment
. /opt/conda/etc/profile.d/conda.sh
conda activate mlebench_prep

# Install mlebench with all dependencies
echo "Installing mlebench and dependencies..."
echo "(This may take 10-15 minutes)"
cd "$MLEBENCH_DIR"
pip install -e . --quiet 2>&1 | tail -20

echo ""
echo "Starting data preparation..."
echo "========================================"
echo ""

# Run appropriate prepare command
if [ "$PREPARE_TYPE" == "lite" ]; then
    echo "Preparing all lite (low complexity) competitions..."
    mlebench prepare --lite
elif [ "$PREPARE_TYPE" == "all" ]; then
    echo "Preparing all competitions..."
    mlebench prepare --all
else
    echo "Preparing competition: $PREPARE_TYPE"
    mlebench prepare -c "$PREPARE_TYPE"
fi

PREPARE_EXIT=$?

echo ""
echo "========================================"
echo "Preparation completed!"
echo "========================================"
echo "Exit Code: $PREPARE_EXIT"
echo ""
echo "Data location: ${MLEBENCH_DIR}/data/"
echo ""
echo "Prepared competitions can now be used with:"
echo "  sbatch scripts_hpc/slurm_grading_server.sh <competition>"
echo "  sbatch scripts_hpc/slurm_aide_qwen.sh <competition>"
echo "========================================"

exit $PREPARE_EXIT
