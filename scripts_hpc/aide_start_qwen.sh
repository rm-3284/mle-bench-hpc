#!/bin/bash
set -x # Print commands and their arguments as they are executed

cd ${AGENT_DIR}

# Load .env from host bind mount if present
if [ -f /home/agent/.env ]; then
  XTRACE_WAS_ON=0
  case "$-" in
    *x*) XTRACE_WAS_ON=1; set +x ;;
  esac
  set -a
  # shellcheck disable=SC1091
  source /home/agent/.env
  set +a
  if [ "$XTRACE_WAS_ON" -eq 1 ]; then
    set -x
  fi
fi

eval "$(conda shell.bash hook)" # make conda available to the shell
conda activate agent

# determine hardware available
if command -v nvidia-smi &> /dev/null && nvidia-smi --query-gpu=name --format=csv,noheader &> /dev/null; then
  HARDWARE=$(nvidia-smi --query-gpu=name --format=csv,noheader \
    | sed 's/^[ \t]*//' \
    | sed 's/[ \t]*$//' \
    | sort \
    | uniq -c \
    | sed 's/^ *\([0-9]*\) *\(.*\)$/\1 \2/' \
    | paste -sd ', ' -)
else
  HARDWARE="a CPU"
fi
export HARDWARE
# check that we can use the GPU in PyTorch
python -c "import torch; print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'WARNING: No GPU')"
# check that we can use the GPU in TensorFlow
python -c "import tensorflow as tf; print('GPUs Available: ', tf.config.list_physical_devices('GPU'))" 2>/dev/null || true

# convert $TIME_LIMIT_SECS to more readable format for prompt
format_time() {
  local time_in_sec=$1
  local hours=$((time_in_sec / 3600))
  local minutes=$(((time_in_sec % 3600) / 60))
  local seconds=$((time_in_sec % 60))
  echo "${hours}hrs ${minutes}mins ${seconds}secs"
}
export TIME_LIMIT=$(format_time $TIME_LIMIT_SECS)

# overwrite instructions.txt with instructions_obfuscated.txt if $OBFUSCATE is set
if [ "$OBFUSCATE" = "true" ]; then
  if [ ! -w /home/data/ ]; then
    echo "Obfuscation not implemented for read-only mounts"
    exit 1
  fi
  mv /home/instructions_obfuscated.txt /home/instructions.txt
fi

# start a new file to store the full instructions, starting with general instructions
cp /home/instructions.txt ${AGENT_DIR}/full_instructions.txt

# Update instructions for agent-specific details: replace `/home/` paths to make paths relative
# (since the agent will have its own copies of these files in its workspace).
# e.g. /home/submission/submission.csv -> submission/submission.csv
sed -i 's|/home/||g' ${AGENT_DIR}/full_instructions.txt
# we'll take care of moving things to home/submission/ ourselves

# move on to agent-specific instructions, with a linebreak in between
# substitute env variables into additional_notes.txt and append result to full_instructions.txt
echo "" >> ${AGENT_DIR}/full_instructions.txt
envsubst < ${AGENT_DIR}/additional_notes.txt >> ${AGENT_DIR}/full_instructions.txt
# finally, append the comp instructions, with a linebreak in between
printf "\nCOMPETITION INSTRUCTIONS\n------\n\n" >> ${AGENT_DIR}/full_instructions.txt

# overwrite description.md with description_obfuscated.md if $OBFUSCATE is set
if [ "$OBFUSCATE" = "true" ]; then
  if [ ! -w /home/data/ ]; then
    echo "Obfuscation not implemented for read-only mounts"
    exit 1
  fi
  mv /home/data/description_obfuscated.md /home/data/description.md
fi
cat /home/data/description.md >> ${AGENT_DIR}/full_instructions.txt

# symbolic linking
# agent will write to AGENT_DIR/workspaces/exp/ and AGENT_DIR/logs/exp
# we will mirror the contents of these to CODE_DIR, LOGS_DIR, and SUBMISSION_DIR

# these need to pre-exist for the symbolic links to work
mkdir -p ${AGENT_DIR}/workspaces/exp
mkdir -p ${AGENT_DIR}/logs
# symbolic linking
ln -s ${LOGS_DIR} ${AGENT_DIR}/logs/exp
ln -s ${CODE_DIR} ${AGENT_DIR}/workspaces/exp/best_solution
ln -s ${SUBMISSION_DIR} ${AGENT_DIR}/workspaces/exp/best_submission

# ============================================================================
# SET UP ENVIRONMENT VARIABLES FOR AIDE MODELS
# ============================================================================
# AIDE respects these environment variables:
# - OPENAI_API_KEY: API key (set to dummy for local Qwen via vLLM)
# - OPENAI_API_BASE: API endpoint for code model
# For feedback model (ChatGPT), we need to figure out the env variable

# Read the model configuration from environment variables passed by the script
CODE_MODEL="${AIDE_CODE_MODEL:-qwen3-30b}"
CODE_API_BASE="${AIDE_CODE_API_BASE:-http://localhost:8000/v1}"
FEEDBACK_MODEL="${AIDE_FEEDBACK_MODEL:-gpt-4o-mini}"
FEEDBACK_API_BASE="${AIDE_FEEDBACK_API_BASE:-https://api.openai.com/v1}"
AGENT_STEPS="${AIDE_AGENT_STEPS:-500}"
AIDE_PROVIDER="${AIDE_PROVIDER:-}"
AIDE_CODE_PROVIDER="${AIDE_CODE_PROVIDER:-vllm}"
AIDE_FEEDBACK_PROVIDER="${AIDE_FEEDBACK_PROVIDER:-openai}"

# Fail fast if feedback provider needs OpenAI but connectivity/auth is missing
if [ "${AIDE_FEEDBACK_PROVIDER}" = "openai" ]; then
  XTRACE_WAS_ON=0
  case "$-" in
    *x*) XTRACE_WAS_ON=1; set +x ;;
  esac
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: OPENAI_API_KEY is not set for feedback model"
    exit 1
  fi
  if ! curl -s -f -H "Authorization: Bearer ${OPENAI_API_KEY}" "${FEEDBACK_API_BASE}/models" >/dev/null 2>&1; then
    echo "ERROR: Unable to reach feedback endpoint at ${FEEDBACK_API_BASE}"
    exit 1
  fi
  if [ "$XTRACE_WAS_ON" -eq 1 ]; then
    set -x
  fi
fi

# Set OPENAI_API_BASE for the code model (Qwen via vLLM)
export OPENAI_API_BASE="${CODE_API_BASE}"
export AIDE_PROVIDER
export AIDE_CODE_PROVIDER
export AIDE_FEEDBACK_PROVIDER

echo "AIDE Configuration:"
echo "  Code Model: ${CODE_MODEL}"
echo "  Code API Base: ${CODE_API_BASE}"
echo "  Feedback Model: ${FEEDBACK_MODEL}"
echo "  Feedback API Base: ${FEEDBACK_API_BASE}"
echo "  Provider Override: ${AIDE_PROVIDER:-auto}"
echo "  Code Provider: ${AIDE_CODE_PROVIDER}"
echo "  Feedback Provider: ${AIDE_FEEDBACK_PROVIDER}"
echo "  Agent Steps: ${AGENT_STEPS}"

# Set log level - use DEBUG to see all AIDE steps
AIDE_LOG_LEVEL="${AIDE_LOG_LEVEL:-DEBUG}"
export AIDE_LOG_LEVEL
echo "  Log Level: ${AIDE_LOG_LEVEL}"

# Setup Python environment to allow custom model names
# The OpenAI SDK validates model names, so we patch it to accept custom ones
mkdir -p /tmp/python_site
cat > /tmp/python_site/sitecustomize.py << 'PYTHON_EOF'
import sys
try:
    import openai.resources.chat.completions
    
    # Store original method
    _original_create = openai.resources.chat.completions.Completions.create
    
    def patched_create(self, *args, **kwargs):
        # Just call the original - let vLLM handle any validation
        return _original_create(self, *args, **kwargs)
    
    # Monkey patch
    openai.resources.chat.completions.Completions.create = patched_create
    print("[sitecustomize] OpenAI SDK patched to accept custom model names", file=sys.stderr)
except Exception as e:
    print(f"[sitecustomize] Failed to patch OpenAI SDK: {e}", file=sys.stderr)
PYTHON_EOF

# Add to PYTHONPATH so sitecustomize.py is auto-imported by all Python processes
export PYTHONPATH="/tmp/python_site:${PYTHONPATH:-}"

# Create a log file for AIDE step-by-step output
AIDE_LOG_FILE="${LOGS_DIR}/aide_steps.log"
echo "Writing AIDE logs to: ${AIDE_LOG_FILE}"

# Calculate outer timeout with buffer (add 10 minutes for graceful shutdown)
OUTER_TIMEOUT=$((TIME_LIMIT_SECS + 600))

# run with timeout, and print if timeout occurs
# Redirect both stdout and stderr to log file AND console
# AIDE will gracefully save when it detects TIME_LIMIT_SECS approaching (5 min buffer)
# Outer timeout is a safety net in case AIDE doesn't exit on time
timeout $OUTER_TIMEOUT aide data_dir="/home/data/" desc_file="${AGENT_DIR}/full_instructions.txt" \
  exp_name="exp" \
  agent.code.model="${CODE_MODEL}" \
  agent.feedback.model="${FEEDBACK_MODEL}" \
  agent.steps="${AGENT_STEPS}" \
  exec.time_limit_secs=$TIME_LIMIT_SECS \
  $@ 2>&1 | tee -a "${AIDE_LOG_FILE}" # forward the bash arguments to aide
if [ $? -eq 124 ]; then
  echo "Outer timeout after $TIME_LIMIT (outer timeout: $OUTER_TIMEOUT secs)"
  echo "Outer timeout after $TIME_LIMIT (outer timeout: $OUTER_TIMEOUT secs)" >> "${AIDE_LOG_FILE}"
fi

# AIDE saves outputs to $AGENT_DIR/logs/0-exp/ but mlebench expects them at $LOGS_DIR
# Copy journal.json and other outputs to LOGS_DIR for mlebench extraction
if [ -d "${AGENT_DIR}/logs/0-exp" ]; then
  echo "Copying AIDE outputs from agent logs to LOGS_DIR..."
  cp -v "${AGENT_DIR}/logs/0-exp"/* "${LOGS_DIR}/" 2>/dev/null || true
  echo "Done copying outputs"
fi


