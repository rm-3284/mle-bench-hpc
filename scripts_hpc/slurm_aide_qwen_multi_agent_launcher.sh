#!/bin/bash
#SBATCH --job-name=aide-qwen-multi-agent
#SBATCH --nodes=1
#SBATCH --partition=ailab
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=16
#SBATCH --mem=128G
#SBATCH --time=24:00:00

# file2: multi-agent launcher

# Usage: sbatch slurm_aide_qwen_multi_agent_launcher.sh <vllm_server_job_id> <TIME_LIMIT_SEC> <STEP_LIMIT> <AIDE_LOG_LEVEL> <code_model> <feedback_model> <competition1> <competition2> ... <grading_server_url1> <grading_server_url2>

set -eo pipefail
module load proxy/default


VLLM_SERVER_JOB_ID="$1"
time_limit="${2:-21600}"
step_limit="${3:-500}"
AIDE_LOG_LEVEL="${4:-INFO}"
CODE_MODEL="${5:-qwen3-30b}"
FEEDBACK_MODEL="${6:-gpt-4o-mini}"
shift 6
competitions=()
grading_servers=()
# Assume competitions and grading_servers are passed in order
for arg in "$@"; do
    if [[ $arg =~ ^http ]]; then
        grading_servers+=("$arg")
    else
        competitions+=("$arg")
    fi
done


echo "=============================================="
echo "AIDE Multi-Agent Launcher"
echo "=============================================="
echo "Job ID:          $SLURM_JOB_ID"
echo "Node:            $SLURM_NODELIST"
echo "VLLM Server Job: $VLLM_SERVER_JOB_ID"
echo "Competitions:    ${competitions[*]}"
echo "Grading Servers: ${grading_servers[*]}"
echo "Code Model:      $CODE_MODEL"
echo "Feedback Model:  $FEEDBACK_MODEL"
echo "Time Limit:      $time_limit seconds"
echo "Step Limit:      $step_limit steps"
echo "Log Level:       $AIDE_LOG_LEVEL"
echo "=============================================="


# Resource partitioning


# Use SLURM-assigned CPU list for partitioning (robust, even split)
#cpu_list_str="${SLURM_TASK_CPU_LIST:-$(seq -s, 0 $((SLURM_CPUS_PER_TASK-1)))}"
# 1. Get the actual cores allowed for THIS job allocation
raw_allowed_cores=$(taskset -pc $$ | awk -F': ' '{print $2}')

# 2. Expand ranges (e.g., "0-3,8" -> "0,1,2,3,8")
cpu_list_str=$(python3 -c "
import sys
parts = '$raw_allowed_cores'.split(',')
expanded = []
for p in parts:
    if '-' in p:
        start, end = map(int, p.split('-'))
        expanded.extend(range(start, end + 1))
    else:
        expanded.append(int(p))
print(','.join(map(str, expanded)))
")

### PATCH END
IFS=',' read -r -a cpu_list <<< "$cpu_list_str"
num_agents=${#competitions[@]}
total_cpus=${#cpu_list[@]}
base_cpus_per_agent=$(( total_cpus / num_agents ))
extra_cpus=$(( total_cpus % num_agents ))
declare -a agent_cpu_lists
cpu_idx=0
for ((i=0; i<num_agents; i++)); do
    n_cpus=$base_cpus_per_agent
    if (( i < extra_cpus )); then
        n_cpus=$((n_cpus + 1))
    fi
    agent_cpu_lists[$i]=$(printf "%s," "${cpu_list[@]:$cpu_idx:$n_cpus}" | sed 's/,$//')
    cpu_idx=$((cpu_idx + n_cpus))
done

echo "=============================================="
echo "Available CPUs: $(printf "%s," "${cpu_list[@]}" | sed 's/,$//')"
for ((i=0; i<num_agents; i++)); do
    echo "Agent $i (${competitions[$i]}) assigned CPUs: ${agent_cpu_lists[$i]}"
done
echo "=============================================="

# GPU MPS partitioning
MPS_THREAD_PCT=$(( 100 / ${#competitions[@]} ))
# Slurm reports mem-per-cpu in MB. Fallback keeps behavior predictable if unset.
MEM_PER_CPU_MB="${SLURM_MEM_PER_CPU:-8192}"
PYTORCH_ALLOC_CONF="expandable_segments:True,max_split_size_mb:512,garbage_collection_threshold:0.8"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S-UTC")
RUN_GROUP_DIR="runs/${TIMESTAMP}_run-group_aide"
mkdir -p "$RUN_GROUP_DIR"

declare -a ALL_TUNNEL_PIDS
GRADING_CLEANUP_DONE=0

cleanup_grading_servers() {
    if [[ "${GRADING_CLEANUP_DONE}" -eq 1 ]]; then
        return
    fi

    declare -a grading_job_ids_to_cancel=()
    declare -A seen_job_ids=()

    # Accept comma/space/newline separated ids from upstream launcher.
    if [[ -n "${GRADING_SERVER_JOB_IDS:-}" ]]; then
        while read -r grading_job_id; do
            if [[ -n "$grading_job_id" && -z "${seen_job_ids[$grading_job_id]:-}" ]]; then
                seen_job_ids[$grading_job_id]=1
                grading_job_ids_to_cancel+=("$grading_job_id")
            fi
        done < <(echo "$GRADING_SERVER_JOB_IDS" | tr ', ' '\n' | sed '/^$/d')
    fi

    # Fallback: resolve grading job ids from known grading URLs via address files.
    if [[ ${#grading_job_ids_to_cancel[@]} -eq 0 ]]; then
        ADDR_DIR="$HOME/.mlebench_addresses"
        for server_url in "${grading_servers[@]}"; do
            if [[ -d "$ADDR_DIR" ]]; then
                for addr_file in "$ADDR_DIR"/grading_server_*; do
                    [[ -f "$addr_file" ]] || continue
                    if grep -Fxq "$server_url" "$addr_file" 2>/dev/null; then
                        grading_job_id="${addr_file##*_}"
                        if [[ -n "$grading_job_id" && -z "${seen_job_ids[$grading_job_id]:-}" ]]; then
                            seen_job_ids[$grading_job_id]=1
                            grading_job_ids_to_cancel+=("$grading_job_id")
                        fi
                    fi
                done
            fi
        done
    fi

    if [[ ${#grading_job_ids_to_cancel[@]} -gt 0 ]]; then
        echo "Cleaning up grading server jobs: ${grading_job_ids_to_cancel[*]}"
        for grading_job_id in "${grading_job_ids_to_cancel[@]}"; do
            scancel "$grading_job_id" 2>/dev/null || true
            echo "  Requested cancel for grading server job: $grading_job_id"
        done
    else
        echo "No grading server jobs found to clean up."
    fi

    GRADING_CLEANUP_DONE=1
}

cleanup_all_tunnels() {
    echo "Cleaning up all SSH tunnels..."
    for pid in "${ALL_TUNNEL_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            echo "  Terminated tunnel PID $pid"
        fi
    done
    cleanup_grading_servers
    rm -rf "$LOCAL_DATA_BASE" 2>/dev/null || true
}
trap cleanup_all_tunnels EXIT

# Compute vLLM/code/feedback model and port setup once (shared across agents)
PYHOOK_SHARED_DIR="$RUN_GROUP_DIR/shared_pyhook"
mkdir -p "$PYHOOK_SHARED_DIR"
cat > "$PYHOOK_SHARED_DIR/sitecustomize.py" << 'PY'
import logging
import os
level_name = os.getenv("AIDE_LOG_LEVEL", "INFO").upper()
level = getattr(logging, level_name, logging.INFO)
logging.getLogger().setLevel(level)
logging.getLogger("aide").setLevel(level)
PY
if [[ "$CODE_MODEL" == *coder* ]]; then
    VLLM_PORT=8002
    AGENT_LOCAL_PORT_BASE=18002
elif [[ "$CODE_MODEL" == *80b* ]]; then
    VLLM_PORT=8001
    AGENT_LOCAL_PORT_BASE=18001
else
    VLLM_PORT=8000
    AGENT_LOCAL_PORT_BASE=18000
fi
VLLM_API_BASE_BASE="http://localhost:${AGENT_LOCAL_PORT_BASE}/v1"
AIDE_CODE_MODEL="$CODE_MODEL"
FEEDBACK_MODEL="$FEEDBACK_MODEL"
if [[ "$FEEDBACK_MODEL" == qwen* ]]; then
    FEEDBACK_API_BASE="$VLLM_API_BASE_BASE"
else
    FEEDBACK_API_BASE="https://api.openai.com/v1"
fi

DATA_DIR="/scratch/gpfs/KARTHIKN/rm4411/mle-cache/data"

# Ensure host-side MPS bind source exists before container launch.
MPS_HOST_DIR="/tmp/nvidia-mps"
mkdir -p "$MPS_HOST_DIR"

LOCAL_DATA_BASE="/tmp/${SLURM_JOB_ID}_data"
mkdir -p "$LOCAL_DATA_BASE"
echo "=============================================="
echo "Staging data to $LOCAL_DATA_BASE"
for comp in "${competitions[@]}"; do
    src="$DATA_DIR/${comp}/prepared/public"
    dst="$LOCAL_DATA_BASE/${comp}"
    if [ -d "$src" ]; then
        echo "Copying $comp ..."
        mkdir -p "$dst"
        rsync -rlt --no-perms "$src/" "$dst/" &
    else
        echo "Source not found for $comp: $src"
    fi
done
wait
echo "Data staging done."
echo "=============================================="

# --- vLLM server connectivity check (before launching agents) ---
QWEN_NODE=$(squeue -j "$VLLM_SERVER_JOB_ID" -h -o "%N" 2>/dev/null || true)
VLLM_SERVER_CHECK_PORT=${VLLM_PORT:-8000}
echo "Checking vLLM server connectivity on $QWEN_NODE:$VLLM_SERVER_CHECK_PORT ..."
max_server_retries=60
for ((retry=1; retry<=max_server_retries; retry++)); do
    if ssh -o ConnectTimeout=5 "$QWEN_NODE" "nc -z localhost $VLLM_SERVER_CHECK_PORT"; then
        echo "  ✓ vLLM server is reachable on $QWEN_NODE:$VLLM_SERVER_CHECK_PORT"
        break
    else
        echo "  Waiting for vLLM server (attempt $retry/$max_server_retries)..."
        sleep 5
    fi
    if (( retry == max_server_retries )); then
        echo "  ✗ ERROR: vLLM server not reachable on $QWEN_NODE:$VLLM_SERVER_CHECK_PORT after $max_server_retries attempts. Exiting."
        exit 1
    fi
done

for ((i=0; i<num_agents; i++)); do
    comp="${competitions[$i]}"
    server="${grading_servers[$i]}"
    cpu_range="${agent_cpu_lists[$i]}"
    out_dir="${RUN_GROUP_DIR}/${comp}_agent${i}_${SLURM_JOB_ID}"
    mkdir -p "$out_dir/submission" "$out_dir/code" "$out_dir/workspaces" "$out_dir/overlay" "$out_dir/logs"
    PYHOOK_DIR="$PYHOOK_SHARED_DIR"
    AGENT_LOG_OUT="${RUN_GROUP_DIR}/agent_${comp}_agent${i}_${SLURM_JOB_ID}.out"
    AGENT_LOG_ERR="${RUN_GROUP_DIR}/agent_${comp}_agent${i}_${SLURM_JOB_ID}.err"
    # Resource monitor log file
    AGENT_MONITOR_LOG="${RUN_GROUP_DIR}/agent_${comp}_agent${i}_${SLURM_JOB_ID}_resource_monitor.log"
    HOST_TMPDIR="/scratch/gpfs/KARTHIKN/rm4411/tmp"
    HOST_CACHEDIR="/scratch/gpfs/KARTHIKN/rm4411/cache"
    SIF_IMAGE="$(pwd)/containers/aide-qwen-minimal.sif"
    DOTENV_FILE="$(pwd)/.env"
    AGENT_LOCAL_PORT=$((AGENT_LOCAL_PORT_BASE + i))
    VLLM_API_BASE="http://localhost:${AGENT_LOCAL_PORT}/v1"
    ENV_BIND=""
    echo "[DEBUG][Agent $i] Setup variables complete."
    if [ -f "$DOTENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$DOTENV_FILE"
        set +a
        ENV_BIND="--bind ${DOTENV_FILE}:/home/agent/.env:ro"
        echo "[DEBUG][Agent $i] Loaded .env file."
    fi
    # Proxy bypass
    QWEN_NODE=$(squeue -j "$VLLM_SERVER_JOB_ID" -h -o "%N" 2>/dev/null || true)
    GRADING_HOST=$(echo "$server" | sed 's|^https\?://||' | cut -d: -f1)
    export no_proxy="localhost,127.0.0.1,${QWEN_NODE},${GRADING_HOST}"
    export NO_PROXY="$no_proxy"
    echo "--- Agent $i ($comp) setup ---"
    echo "  Grading server: $server"
    echo "  Qwen node:      $QWEN_NODE"
    echo "  Grading host:   $GRADING_HOST"
    echo "  no_proxy:       $no_proxy"
    echo "  Output dir:     $out_dir"
    echo "  CPU range:      $cpu_range"
    echo "  Agent log out:  $AGENT_LOG_OUT"
    echo "  Agent log err:  $AGENT_LOG_ERR"
    echo "[DEBUG][Agent $i] Overlay and instructions setup starting."
    # Overlay preparation (minimal)
    OVERLAY_DIR="$out_dir/overlay"
    mkdir -p "$OVERLAY_DIR"
    cp "$(pwd)/environment/instructions.txt" "$OVERLAY_DIR/instructions.txt"
    sed -i "s|http://localhost:5000|${server}|g" "$OVERLAY_DIR/instructions.txt"
    cp "$(pwd)/environment/instructions_obfuscated.txt" "$OVERLAY_DIR/instructions_obfuscated.txt"
    sed -i "s|http://localhost:5000|${server}|g" "$OVERLAY_DIR/instructions_obfuscated.txt"
    cp "$(pwd)/environment/validate_submission.sh" "$OVERLAY_DIR/validate_submission.sh"
    sed -i "s|http://localhost:5000|${server}|g" "$OVERLAY_DIR/validate_submission.sh"
    chmod +x "$OVERLAY_DIR/validate_submission.sh"
    cp "$(pwd)/agents/aide/additional_notes.txt" "$OVERLAY_DIR/additional_notes.txt"
    sed -i "s|http://localhost:5000|${server}|g" "$OVERLAY_DIR/additional_notes.txt"

    # --- SSH tunnel setup for vLLM server ---
    echo "[DEBUG][Agent $i] Checking and cleaning up port $AGENT_LOCAL_PORT if needed."
    if nc -z 127.0.0.1 "$AGENT_LOCAL_PORT"; then
        echo "⚠ Port $AGENT_LOCAL_PORT is already in use. Attempting cleanup..."
        if command -v fuser &> /dev/null; then
            fuser -k "${AGENT_LOCAL_PORT}/tcp" 2>/dev/null || true
            echo "[DEBUG][Agent $i] Ran fuser to kill port $AGENT_LOCAL_PORT."
            sleep 1
        fi
        if nc -z 127.0.0.1 "$AGENT_LOCAL_PORT"; then
            echo "  ✗ Failed to free port $AGENT_LOCAL_PORT"
            echo "[DEBUG][Agent $i] Port $AGENT_LOCAL_PORT still in use after cleanup."
            continue 2
        fi
        echo "  ✓ Port $AGENT_LOCAL_PORT freed"
        echo "[DEBUG][Agent $i] Port $AGENT_LOCAL_PORT successfully freed."
    fi
    echo "[DEBUG][Agent $i] Creating SSH tunnel to ${QWEN_NODE}:${VLLM_PORT} (local port ${AGENT_LOCAL_PORT})..."
    ssh -N -L "${AGENT_LOCAL_PORT}:localhost:${VLLM_PORT}" "${QWEN_NODE}" &
    TUNNEL_PID=$!
    ALL_TUNNEL_PIDS+=("$TUNNEL_PID")

    sleep 2  # Give SSH tunnel time to establish

    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo "✗ SSH tunnel process died immediately. Check SSH connectivity."
        echo "[DEBUG][Agent $i] SSH tunnel process died immediately after creation."
        continue 2
    fi
    echo "✓ SSH tunnel established (PID $TUNNEL_PID)"
    echo "[DEBUG][Agent $i] SSH tunnel established."

    # --- vLLM API reachability check ---
    echo "[DEBUG][Agent $i] Checking vLLM API reachability for agent $i ($comp) at $VLLM_API_BASE ..."
    max_retries=30
    for ((retry=1; retry<=max_retries; retry++)); do
        if curl -s -f "${VLLM_API_BASE}/models" > /dev/null 2>&1; then
            echo "  ✓ vLLM API reachable for agent $i ($comp)"
            echo "[DEBUG][Agent $i] vLLM API reachable."
            break
        else
            echo "  Waiting for vLLM API (attempt $retry/$max_retries)..."
            echo "[DEBUG][Agent $i] vLLM API not reachable, attempt $retry/$max_retries."
            sleep 2
        fi
        if (( retry == max_retries )); then
            echo "  ✗ ERROR: vLLM API not reachable for agent $i ($comp) after $max_retries attempts. Skipping launch."
            echo "[DEBUG][Agent $i] vLLM API not reachable after $max_retries attempts. Skipping launch."
            continue 2
        fi
    done

    # cpu_per_agent
    current_agent_cpu_count=$(echo "${agent_cpu_lists[$i]}" | tr -cd ',' | wc -c)
    current_agent_cpu_count=$((current_agent_cpu_count + 1))
    agent_mem_mb=$(( current_agent_cpu_count * MEM_PER_CPU_MB ))
    GPU_MEM_PER_AGENT="${agent_mem_mb}M"
    MPS_MEM_LIMIT="0=${GPU_MEM_PER_AGENT}"
    echo "  Agent mem limit: $GPU_MEM_PER_AGENT (${current_agent_cpu_count} CPUs x ${MEM_PER_CPU_MB}MB)"

        # Launch agent using srun and capture job step id
        echo "Launching agent $i ($comp) on cores $cpu_range with grading server $server..."
        echo "  Launch command: srun --cpu-bind=map_cpu:$cpu_range apptainer exec ..."
        echo "[DEBUG][Agent $i] Launching agent subprocess."
        (
            # Launch agent as a Slurm Job Step
            echo "[DEBUG][Agent $i] [subprocess] Launching parallel srun step."
            
            # We use --exact and --overlap to allow multiple steps on one GPU
            srun --ntasks=1 \
                --exact \
                --overlap \
                --cpus-per-task="$current_agent_cpu_count" \
                --mem="${GPU_MEM_PER_AGENT}" \
                --gres=gpu:1 \
                --job-name="${comp}" \
                --output="$AGENT_LOG_OUT" \
                --error="$AGENT_LOG_ERR" \
                apptainer exec \
                    --contain \
                    --cleanenv \
                    --writable-tmpfs \
                    --nv \
                    --env CUDA_MPS_ACTIVE_THREAD_PERCENTAGE="$MPS_THREAD_PCT" \
                    --env CUDA_MPS_PINNED_DEVICE_MEM_LIMIT="$MPS_MEM_LIMIT" \
                    --env PYTORCH_CUDA_ALLOC_CONF="$PYTORCH_ALLOC_CONF" \
                    --env OMP_NUM_THREADS="$current_agent_cpu_count" \
                    --env MKL_NUM_THREADS="$current_agent_cpu_count" \
                    --env NUMEXPR_NUM_THREADS="$current_agent_cpu_count" \
                    --env XDG_CACHE_HOME="$HOST_CACHEDIR" \
                    --env TMPDIR="$HOST_TMPDIR" \
                    --env APPTAINER_CACHEDIR="$HOST_CACHEDIR" \
                    --env APPTAINER_TMPDIR="$HOST_TMPDIR" \
                    --env COMPETITION_ID="$comp" \
                    --env GRADING_SERVER="$server" \
                    --env TIME_LIMIT_SECS="$time_limit" \
                    --env STEP_LIMIT="$step_limit" \
                    --env OPENAI_API_KEY="${OPENAI_API_KEY}" \
                    --env AIDE_CODE_MODEL="$AIDE_CODE_MODEL" \
                    --env AIDE_CODE_API_BASE="$VLLM_API_BASE" \
                    --env AIDE_FEEDBACK_MODEL="$FEEDBACK_MODEL" \
                    --env AIDE_FEEDBACK_API_BASE="$FEEDBACK_API_BASE" \
                    --env AIDE_LOG_LEVEL="$AIDE_LOG_LEVEL" \
                    --env AIDE_AGENT_STEPS="$step_limit" \
                    --env AIDE_PROVIDER="${AIDE_PROVIDER}" \
                    --env AIDE_CODE_PROVIDER="${AIDE_CODE_PROVIDER}" \
                    --env AIDE_FEEDBACK_PROVIDER="${AIDE_FEEDBACK_PROVIDER}" \
                    --env no_proxy="$no_proxy" \
                    --env NO_PROXY="$no_proxy" \
                    --env PYTHONPATH="/home/agent/pyhook${PYTHONPATH:+:${PYTHONPATH}}" \
                    --bind "$LOCAL_DATA_BASE/${comp}:/home/data:ro" \
                    --bind "$out_dir/submission:/home/submission" \
                    --bind "$out_dir/logs:/home/logs" \
                    --bind "$out_dir/code:/home/code" \
                    --bind "$out_dir/workspaces:/home/agent/workspaces" \
                    --bind "$OVERLAY_DIR/instructions.txt:/home/instructions.txt:ro" \
                    --bind "$OVERLAY_DIR/instructions_obfuscated.txt:/home/instructions_obfuscated.txt:ro" \
                    --bind "$OVERLAY_DIR/validate_submission.sh:/home/validate_submission.sh:ro" \
                    --bind "$OVERLAY_DIR/additional_notes.txt:/home/agent/additional_notes.txt:ro" \
                    --bind "$PYHOOK_SHARED_DIR:/home/agent/pyhook:ro" \
                    --bind "$HOST_TMPDIR:/tmp" \
                    --bind "/tmp/nvidia-mps:/tmp/nvidia-mps" \
                    --bind "$HOST_CACHEDIR:/scratch/gpfs/KARTHIKN/rm4411/cache" \
                    --bind "$(pwd)/scripts_hpc/aide_start_qwen.sh:/home/agent/start.sh:ro" \
                    $ENV_BIND \
                    "$SIF_IMAGE" \
                    bash /home/agent/start.sh
                    
            AGENT_EXIT_CODE=$?
            echo "[DEBUG][Agent $i] Agent exited with code $AGENT_EXIT_CODE."
            exit $AGENT_EXIT_CODE
        ) &
        AGENT_SRUN_PIDS[$i]=$!
        AGENT_LAUNCH_TS[$i]=$(date +%s)
        # Wait a moment for srun to start and get job step id
        sleep 5
        echo "[DEBUG][Agent $i] Waiting for agent step ID."
        # Robust agent step ID logic: match by job name and command
        AGENT_STEP_ID=""
        for try in {1..30}; do
            echo "[DEBUG][Agent $i] sacct output (try $try):"
            sacct -j "$SLURM_JOB_ID" --format=JobID,JobName%100,State -n
            AGENT_STEP_ID=$(sacct -j "$SLURM_JOB_ID" --format=JobID,JobName%100,State -n |
                awk -v comp="${comp}" '$2==comp {split($1,a,"."); print a[2]}' |
                head -n1 |
                tr -d ' ' || true)
            if [[ -n "$AGENT_STEP_ID" ]]; then
                echo "[DEBUG][Agent $i] Found agent step ID: $AGENT_STEP_ID."
                break
            fi
            echo "[DEBUG][Agent $i] Agent step ID not found, try $try."
            sleep 2
        done
        AGENT_STEP_IDS[$i]="$AGENT_STEP_ID"
        echo "  Agent $i launch submitted. SRUN PID: ${AGENT_SRUN_PIDS[$i]}, Step ID: $AGENT_STEP_ID"
        echo "[DEBUG][Agent $i] Agent launch submitted."

        # Start resource monitor for this agent using sstat and job step id
        (
            prev_cpu_secs=""
            prev_wall_ts=""
            while true; do
                now=$(date +"%Y-%m-%dT%H:%M:%S")
                if [[ -n "$AGENT_STEP_ID" ]]; then
                    row=$(sstat -j "${SLURM_JOB_ID}.${AGENT_STEP_ID}" --noconvert --format=JobID,AveCPU,MaxRSS,AveRSS,MaxVMSize,AveVMSize,MaxDiskRead,MaxDiskWrite,TRESUsageInAve,TRESUsageInMax -P -n 2>/dev/null | head -n1 || true)
                    if [[ -n "$row" ]]; then
                        ave_cpu=$(echo "$row" | cut -d'|' -f2)
                        cpu_secs=$(echo "$ave_cpu" | awk '
                            function tosec(h,m,s){ return h*3600 + m*60 + s }
                            {
                                t=$1
                                d=0
                                if (index(t,"-")>0) { split(t,a,"-"); d=a[1]; t=a[2] }
                                n=split(t,b,":")
                                if (n==3)      sec=tosec(b[1],b[2],b[3])
                                else if (n==2) sec=tosec(0,b[1],b[2])
                                else           sec=t
                                print d*86400 + sec
                            }
                        ')
                        wall_ts=$(date +%s)
                        cpu_util_pct="NA"
                        if [[ -n "$prev_cpu_secs" && -n "$prev_wall_ts" ]] && (( wall_ts > prev_wall_ts )) && (( cpu_secs >= prev_cpu_secs )); then
                            delta_cpu=$((cpu_secs - prev_cpu_secs))
                            delta_wall=$((wall_ts - prev_wall_ts))
                            if (( delta_wall > 0 && current_agent_cpu_count > 0 )); then
                                cpu_util_pct=$(awk -v dc="$delta_cpu" -v dw="$delta_wall" -v ncpu="$current_agent_cpu_count" 'BEGIN { printf "%.2f", (100.0 * dc) / (dw * ncpu) }')
                            fi
                        fi
                        prev_cpu_secs="$cpu_secs"
                        prev_wall_ts="$wall_ts"
                        echo "$now|sstat|$row|cpu_util_pct=$cpu_util_pct"
                    fi
                fi
                sleep 10
            done
        ) > "$AGENT_MONITOR_LOG" 2>&1 &
        AGENT_MONITOR_PIDS[$i]=$!
done

SRUN_FORCE_TIMEOUT_SECS="${SRUN_FORCE_TIMEOUT_SECS:-$((time_limit + 900))}"
declare -a AGENT_EXIT_CODES
for i in "${!competitions[@]}"; do
    pid="${AGENT_SRUN_PIDS[$i]}"
    step_id="${AGENT_STEP_IDS[$i]}"
    launch_ts="${AGENT_LAUNCH_TS[$i]}"
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
        if [[ -z "$launch_ts" || ! "$launch_ts" =~ ^[0-9]+$ ]]; then
            launch_ts=$(date +%s)
        fi
        while true; do
            pid_alive=0
            if kill -0 "$pid" 2>/dev/null; then
                pid_alive=1
            fi

            step_active=1
            if [[ -n "$step_id" ]]; then
                if ! sstat -j "${SLURM_JOB_ID}.${step_id}" --format=JobID -n 2>/dev/null | grep -q .; then
                    step_active=0
                fi
            fi

            if [[ -n "$step_id" && "$step_active" -eq 0 ]]; then
                if [[ "$pid_alive" -eq 1 ]]; then
                    echo "[DEBUG][Agent $i] Step ${SLURM_JOB_ID}.${step_id} no longer active; stopping lingering SRUN PID $pid."
                    kill "$pid" 2>/dev/null || true
                    sleep 2
                    kill -9 "$pid" 2>/dev/null || true
                fi
                break
            fi

            if [[ "$pid_alive" -eq 0 ]]; then
                break
            fi

            now_ts=$(date +%s)
            elapsed_ts=$((now_ts - launch_ts))
            if (( elapsed_ts >= SRUN_FORCE_TIMEOUT_SECS )); then
                echo "[WARN][Agent $i] SRUN PID $pid exceeded ${SRUN_FORCE_TIMEOUT_SECS}s. Attempting forced cleanup."
                if [[ -n "$step_id" ]]; then
                    scancel "${SLURM_JOB_ID}.${step_id}" 2>/dev/null || true
                fi
                kill "$pid" 2>/dev/null || true
                sleep 2
                kill -9 "$pid" 2>/dev/null || true
                break
            fi
            sleep 5
        done
        if wait "$pid"; then
            AGENT_EXIT_CODES[$i]=0
        else
            AGENT_EXIT_CODES[$i]=$?
        fi
    else
        AGENT_EXIT_CODES[$i]="N/A"
    fi
done

echo "All agents finished."
echo "=============================================="
echo "Agent completion summary:"
for i in "${!competitions[@]}"; do
    comp="${competitions[$i]}"
    pid="${AGENT_SRUN_PIDS[$i]}"
    log_out="${RUN_GROUP_DIR}/agent_${comp}_agent${i}_${SLURM_JOB_ID}.out"
    log_err="${RUN_GROUP_DIR}/agent_${comp}_agent${i}_${SLURM_JOB_ID}.err"
    # Kill resource monitor for this agent
    monitor_pid="${AGENT_MONITOR_PIDS[$i]}"
    if [[ -n "$monitor_pid" && "$monitor_pid" =~ ^[0-9]+$ ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
    fi
    exit_code="${AGENT_EXIT_CODES[$i]}"
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
        echo "Agent $i ($comp): PID $pid, exit code $exit_code"
    else
        echo "Agent $i ($comp): No valid PID (skipped or failed to launch)"
    fi
    echo "  Log out: $log_out"
    echo "  Log err: $log_err"
done
echo "=============================================="

cleanup_grading_servers

# Organize all agent error logs into a summary file
SUMMARY_ERR_LOG="${RUN_GROUP_DIR}/all_agents_error_summary_${SLURM_JOB_ID}.log"
echo "==== All Agent Error Log Summary (Job $SLURM_JOB_ID) ====" > "$SUMMARY_ERR_LOG"
for i in "${!competitions[@]}"; do
    comp="${competitions[$i]}"
    pid="${AGENT_SRUN_PIDS[$i]}"
    log_err="${RUN_GROUP_DIR}/agent_${comp}_agent${i}_${SLURM_JOB_ID}.err"
    echo "\n--- Agent $i ($comp) | PID: $pid ---" >> "$SUMMARY_ERR_LOG"
    if [ -s "$log_err" ]; then
        cat "$log_err" >> "$SUMMARY_ERR_LOG"
    else
        echo "[No error output]" >> "$SUMMARY_ERR_LOG"
    fi
done
echo "==== End of Error Log Summary ====" >> "$SUMMARY_ERR_LOG"
echo "Error summary written to: $SUMMARY_ERR_LOG"
