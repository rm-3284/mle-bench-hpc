#!/bin/bash
# Summary of containers needed for AIDE + Qwen workflow

echo "========================================"
echo "Container Status Check"
echo "========================================"
echo ""

echo "✓ Already Built (vLLM servers):"
echo "  - containers/qwen3-30b-vllm.sif (7.4GB)"
echo "  - containers/qwen3-80b-vllm.sif (7.4GB)"
echo ""

echo "❌ Still Need to Build:"
echo ""

# Check AIDE container
if [ -f "containers/aide-qwen.sif" ]; then
    echo "  ✓ AIDE agent: containers/aide-qwen.sif"
else
    echo "  ❌ AIDE agent: containers/aide-qwen.sif"
    echo "     Build with: cd containers && apptainer build --fakeroot aide-qwen.sif aide-qwen.def"
    echo "     Time: ~20-30 minutes"
fi

echo ""

# Check mlebench base container
MLEBENCH_CONTAINER=$(grep "SIF_IMAGE=" scripts_hpc/slurm_grading_server.sh | head -1 | cut -d'"' -f2)
if [ -f "$MLEBENCH_CONTAINER" ]; then
    echo "  ✓ Grading server: $MLEBENCH_CONTAINER"
else
    echo "  ❌ Grading server: $MLEBENCH_CONTAINER"
    echo "     This is referenced in scripts_hpc/slurm_grading_server.sh"
    echo "     You may need to build or update the path"
fi

echo ""
echo "========================================"
echo "Next Steps:"
echo "========================================"
echo ""
echo "1. Build AIDE agent container:"
echo "   cd containers"
echo "   apptainer build --fakeroot aide-qwen.sif aide-qwen.def"
echo ""
echo "2. Update paths in scripts:"
echo "   - Edit scripts_hpc/slurm_grading_server.sh (DATA_DIR, SIF_IMAGE)"
echo "   - Edit scripts_hpc/run_aide_qwen_workflow.sh (verify paths)"
echo ""
echo "3. Test the workflow:"
echo "   ./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b"
echo ""
