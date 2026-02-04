#!/bin/bash

set -x

unset CONDA_EXE CONDA_PREFIX CONDA_PYTHON_EXE CONDA_DEFAULT_ENV CONDA_SHLVL
export PATH="/opt/conda/bin:$PATH"

LOGS_DIR=/home/logs
mkdir -p $LOGS_DIR 2>/dev/null || true
GRADING_SERVER="${GRADING_SERVER:-http://localhost:5000}"

{
  echo "=== HPC Agent Container Entrypoint ==="
  echo "Running as user: $(whoami) (UID: $(id -u))"
  echo "Date: $(date)"
  echo "Competition: ${COMPETITION_ID}"
  echo "Grading Server: ${GRADING_SERVER}"
  
  ls -la /home/ || true
  
  echo "Checking for grading server at ${GRADING_SERVER}..."
  if curl -s "${GRADING_SERVER}/health" > /dev/null 2>&1; then
    echo "Grading server is available!"
  else
    echo "WARNING: Grading server not detected at ${GRADING_SERVER}"
  fi
  
  echo "Initializing container conda..."
  eval "$(/opt/conda/bin/conda shell.bash hook)"
  
  if [ $# -gt 0 ]; then
    echo "Executing agent command: $@"
    "$@"
    AGENT_EXIT_CODE=$?
    echo "Agent finished with exit code: $AGENT_EXIT_CODE"
  else
    echo "ERROR: No agent command provided."
    echo "Usage: apptainer exec <image> /entrypoint_hpc.sh bash /home/agent/start.sh"
    exit 1
  fi
  
  echo "=== HPC Agent Entrypoint Complete ==="
  
} 2>&1 | tee $LOGS_DIR/entrypoint.log

