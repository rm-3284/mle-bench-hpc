#!/bin/bash
# Quick commands to build containers for AIDE + Qwen workflow

cat << 'EOF'
========================================
Container Build Commands
========================================

You need to build 2 containers:

1. MLEBench Base Environment (for grading server)
2. AIDE Agent (for running AIDE with Qwen models)

========================================
OPTION A: Build All at Once (Recommended)
========================================

cd containers
./build_all_containers.sh

This will build both containers sequentially.
Total time: ~50-70 minutes

========================================
OPTION B: Build Individually
========================================

# 1. Build MLEBench base environment (30-40 min)
cd containers
apptainer build --fakeroot mlebench-env.sif mlebench-env.def

# 2. Build AIDE agent (20-30 min)
apptainer build --fakeroot aide-qwen-minimal.sif aide-qwen-minimal.def

========================================
Monitor Build Progress
========================================

Builds can take a while. You can:
- Run in tmux/screen session
- Submit as SLURM job (if cluster allows)
- Monitor with: watch -n 5 'ls -lh containers/*.sif'

========================================
After Building
========================================

Once built, update script paths:
1. Edit scripts_hpc/slurm_grading_server.sh
2. Edit scripts_hpc/slurm_aide_qwen.sh
3. Run: ./scripts_hpc/run_aide_qwen_workflow.sh spaceship-titanic 30b

========================================
Troubleshooting
========================================

If build fails with permission errors:
  sudo apptainer build mlebench-env.sif mlebench-env.def

If conda TOS errors occur:
  Already fixed in the .def files!

If missing dependencies:
  Check that you're in the right directory
  Verify definition files exist

========================================
EOF
