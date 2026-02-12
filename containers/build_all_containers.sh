#!/bin/bash
# Build all containers needed for AIDE + Qwen workflow

set -e

echo "========================================"
echo "Building AIDE + Qwen Containers"
echo "========================================"
echo ""
echo "This will build:"
echo "  1. MLEBench base environment (grading server)"
echo "  2. AIDE agent with Qwen support"
echo ""
echo "Already built:"
echo "  ✓ Qwen3-30B vLLM server"
echo "  ✓ Qwen3-80B vLLM server"
echo ""
echo "========================================"
echo ""

cd "$(dirname "$0")"

# Build MLEBench base environment
echo "Step 1/2: Building MLEBench base environment..."
echo "  This includes grading server support"
echo "  Estimated time: 30-40 minutes"
echo ""

if [ -f "mlebench-env.sif" ]; then
    read -p "mlebench-env.sif already exists. Rebuild? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  Skipping mlebench-env.sif"
    else
        rm mlebench-env.sif
        echo "  Trying build without fakeroot first..."
        apptainer build mlebench-env.sif mlebench-env.def || \
        (echo "  Retrying with --fakeroot..." && apptainer build --fakeroot mlebench-env.sif mlebench-env.def) || \
        (echo "  Retrying with --fakeroot --ignore-fakeroot-command..." && apptainer build --fakeroot --ignore-fakeroot-command mlebench-env.sif mlebench-env.def)
    fi
else
    echo "  Trying build without fakeroot first..."
    apptainer build mlebench-env.sif mlebench-env.def || \
    (echo "  Retrying with --fakeroot..." && apptainer build --fakeroot mlebench-env.sif mlebench-env.def) || \
    (echo "  Retrying with --fakeroot --ignore-fakeroot-command..." && apptainer build --fakeroot --ignore-fakeroot-command mlebench-env.sif mlebench-env.def)
fi

echo ""
echo "========================================"
echo ""

# Build AIDE agent
echo "Step 2/2: Building AIDE agent..."
echo "  This includes AIDE with local vLLM support"
echo "  Estimated time: 20-30 minutes"
echo ""

if [ -f "aide-qwen-minimal.sif" ]; then
    read -p "aide-qwen-minimal.sif already exists. Rebuild? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "  Skipping aide-qwen-minimal.sif"
    else
        rm aide-qwen-minimal.sif
        echo "  Trying build without fakeroot first..."
        apptainer build aide-qwen-minimal.sif aide-qwen-minimal.def || \
        (echo "  Retrying with --fakeroot..." && apptainer build --fakeroot aide-qwen-minimal.sif aide-qwen-minimal.def) || \
        (echo "  Retrying with --fakeroot --ignore-fakeroot-command..." && apptainer build --fakeroot --ignore-fakeroot-command aide-qwen-minimal.sif aide-qwen-minimal.def)
    fi
else
    echo "  Trying build without fakeroot first..."
    apptainer build aide-qwen-minimal.sif aide-qwen-minimal.def || \
    (echo "  Retrying with --fakeroot..." && apptainer build --fakeroot aide-qwen-minimal.sif aide-qwen-minimal.def) || \
    (echo "  Retrying with --fakeroot --ignore-fakeroot-command..." && apptainer build --fakeroot --ignore-fakeroot-command aide-qwen-minimal.sif aide-qwen-minimal.def)
fi

echo ""
echo "========================================"
echo "Build Complete!"
echo "========================================"
echo ""
echo "Containers created:"
ls -lh *.sif | awk '{print "  " $9 " (" $5 ")"}'
echo ""
echo "Next steps:"
echo "  1. Update paths in SLURM scripts"
echo "  2. Test with: ../scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b"
echo ""
