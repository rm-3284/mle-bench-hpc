#!/bin/bash

# User can specify these, or use defaults
CPUS_PER_AGENT=${CPUS_PER_AGENT:-2}
MEM_PER_CPU=${MEM_PER_CPU:-16G}


# file1: grading server launcher
# Usage: ./file1.sh <vllm_server_job_id> <TIME_LIMIT_SEC> <STEP_LIMIT> <AIDE_LOG_LEVEL> <code_model> <feedback_model> <competition1> <competition2> ...



VLLM_SERVER_JOB_ID="$1"
TIME_LIMIT_SEC="${2:-21600}"
STEP_LIMIT="${3:-500}"
AIDE_LOG_LEVEL="${4:-INFO}"
CODE_MODEL="${5:-qwen3-coder}"
FEEDBACK_MODEL="${6:-gpt-5-mini-2025-08-07}"
shift 6
competitions=("$@")

# Create log directory for this run
RUN_TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S-UTC")
RUN_LOG_DIR="/scratch/gpfs/KARTHIKN/rm4411/mle-bench-hpc/logs/${RUN_TIMESTAMP}_run-group"
mkdir -p "$RUN_LOG_DIR"
echo "Logs will be stored in $RUN_LOG_DIR"


# Assign unique ports and launch grading servers for each competition
server_job_ids=()
declare -A grading_log_map
declare -a grading_ports
BASE_PORT=5000
for idx in "${!competitions[@]}"; do
    comp="${competitions[$idx]}"
    port=$((BASE_PORT + idx))
    grading_ports+=("$port")
    echo "Submitting grading server for $comp on port $port..."
    job_id=$(sbatch --parsable --output="$RUN_LOG_DIR/grading_server_${comp}_%j.out" --error="$RUN_LOG_DIR/grading_server_${comp}_%j.err" scripts_hpc/slurm_grading_server_ports.sh "$comp" "$port")
    server_job_ids+=("$job_id")
    grading_log_map["$comp"]="$RUN_LOG_DIR/grading_server_${comp}_${job_id}.out,$RUN_LOG_DIR/grading_server_${comp}_${job_id}.err"
    echo "Grading server job ID for $comp: $job_id (port $port)"
done

# Wait for grading server address files
server_urls=()
for job_id in "${server_job_ids[@]}"; do
    addr_file="$HOME/.mlebench_addresses/grading_server_${job_id}"
    echo "Waiting for grading server address file: $addr_file"
    while [ ! -f "$addr_file" ]; do sleep 5; done
    url=$(<"$addr_file")
    server_urls+=("$url")
    echo "Grading server URL: $url"
done

# Launch multi-agent job (file2)



# Launch multi-agent job (file2)
NUM_COMPETITIONS=${#competitions[@]}
TOTAL_CPUS=$((CPUS_PER_AGENT * NUM_COMPETITIONS))
TOTAL_MEM=$((CPUS_PER_AGENT * NUM_COMPETITIONS))
# Convert MEM_PER_CPU to integer (strip G if present)
MEM_PER_CPU_INT=$(echo $MEM_PER_CPU | sed 's/G//')
TOTAL_MEM_G=$((MEM_PER_CPU_INT * CPUS_PER_AGENT * NUM_COMPETITIONS))
TOTAL_MEM_STR="${TOTAL_MEM_G}G"

echo "Launching multi-agent job with $TOTAL_CPUS CPUs and $TOTAL_MEM_STR memory..."
GRADING_SERVER_JOB_IDS=$(IFS=,; echo "${server_job_ids[*]}")
export CPUS_PER_AGENT MEM_PER_CPU
agent_job_id=$(sbatch --cpus-per-task=$TOTAL_CPUS --mem=$TOTAL_MEM_STR --output="$RUN_LOG_DIR/agent_multi_%j.out" --error="$RUN_LOG_DIR/agent_multi_%j.err" \
    --export=ALL,GRADING_SERVER_JOB_IDS="$GRADING_SERVER_JOB_IDS",CPUS_PER_AGENT="$CPUS_PER_AGENT",MEM_PER_CPU="$MEM_PER_CPU" \
    scripts_hpc/slurm_aide_qwen_multi_agent_launcher.sh "$VLLM_SERVER_JOB_ID" "$TIME_LIMIT_SEC" "$STEP_LIMIT" "$AIDE_LOG_LEVEL" "$CODE_MODEL" "$FEEDBACK_MODEL" "${competitions[@]}" "${server_urls[@]}")
agent_log_out="$RUN_LOG_DIR/agent_multi_${agent_job_id}.out"
agent_log_err="$RUN_LOG_DIR/agent_multi_${agent_job_id}.err"

# Create log mapping file
LOG_MAP_FILE="$RUN_LOG_DIR/log_map.txt"
echo "# Log mapping for this run" > "$LOG_MAP_FILE"
for comp in "${competitions[@]}"; do
    job_id="${server_job_ids[$((i++))]}"
    echo "grading_server_${comp}_out: $RUN_LOG_DIR/grading_server_${comp}_${job_id}.out" >> "$LOG_MAP_FILE"
    echo "grading_server_${comp}_err: $RUN_LOG_DIR/grading_server_${comp}_${job_id}.err" >> "$LOG_MAP_FILE"
done
echo "agent_multi_out: $agent_log_out" >> "$LOG_MAP_FILE"
echo "agent_multi_err: $agent_log_err" >> "$LOG_MAP_FILE"
echo "Log mapping file created at $LOG_MAP_FILE"
