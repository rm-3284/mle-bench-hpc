#!/bin/bash

set -x

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
  
  # Update instructions and scripts to use the correct grading server URL
  if [ "$GRADING_SERVER" != "http://localhost:5000" ]; then
    echo "Updating grading server URL in instruction files..."
    
    # Replace in instructions.txt
    if [ -f /home/instructions.txt ]; then
      sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" /home/instructions.txt
      echo "  Updated /home/instructions.txt"
    fi
    
    # Replace in instructions_obfuscated.txt
    if [ -f /home/instructions_obfuscated.txt ]; then
      sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" /home/instructions_obfuscated.txt
      echo "  Updated /home/instructions_obfuscated.txt"
    fi
    
    # Replace in validate_submission.sh
    if [ -f /home/validate_submission.sh ]; then
      sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" /home/validate_submission.sh
      echo "  Updated /home/validate_submission.sh"
    fi
    
    # Replace in agent-specific files (e.g., AIDE's additional_notes.txt)
    if [ -f /home/agent/additional_notes.txt ]; then
      sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" /home/agent/additional_notes.txt
      echo "  Updated /home/agent/additional_notes.txt"
    fi
    
    # For OpenHands templates
    if [ -f /home/agent/templates.py ]; then
      sed -i "s|http://localhost:5000|${GRADING_SERVER}|g" /home/agent/templates.py
      echo "  Updated /home/agent/templates.py"
    fi
  fi
  
  # Check if grading server is available
  echo "Checking for grading server at ${GRADING_SERVER}..."
  if curl -s "${GRADING_SERVER}/health" > /dev/null 2>&1; then
    echo "Grading server is available!"
  else
    echo "WARNING: Grading server not detected at ${GRADING_SERVER}"
  fi
  
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

