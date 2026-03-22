#!/bin/bash
# Generic Miro agent wrapper for AutoRL-Bench

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Miro Generic Agent ==="
echo "Task: $TASK"
echo "Model: $BASE_MODEL"
echo "Workspace: $WORKSPACE"
echo "Grading Server: $GRADING_SERVER_URL"
echo "Output Dir: $OUTPUT_DIR"

# Load repository-level .env when available.
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
    echo "Loaded .env"
fi

MIRO_MODE="${MIRO_MODE:-command}"
MIRO_ENTRYPOINT="${MIRO_ENTRYPOINT:-}"
MIRO_TIMEOUT="${MIRO_TIMEOUT:-36000}"
MIRO_SYSTEM="${MIRO_SYSTEM:-mirothinker}"
START_EPOCH=$(date +%s)

echo "Miro Mode: $MIRO_MODE"
echo "Miro System: $MIRO_SYSTEM"
echo "Miro Entrypoint: ${MIRO_ENTRYPOINT:-<unset>}"

if [ ! -d "$WORKSPACE" ]; then
    echo "ERROR: WORKSPACE does not exist: $WORKSPACE"
    exit 2
fi

# Generate timer helper for the delegated agent.
cat > "$WORKSPACE/timer.sh" << TIMER
#!/bin/bash
DEADLINE=$((START_EPOCH + MIRO_TIMEOUT))
NOW=\$(date +%s)
REMAINING=\$((DEADLINE - NOW))
if [ \$REMAINING -le 0 ]; then
    echo "Timer expired!"
else
    HOURS=\$((REMAINING / 3600))
    MINUTES=\$(((REMAINING % 3600) / 60))
    printf "Remaining: %d:%02d\n" \$HOURS \$MINUTES
fi
TIMER
chmod +x "$WORKSPACE/timer.sh"

INSTRUCTIONS=$(cat "$WORKSPACE/instructions.md" 2>/dev/null || echo "")
DESCRIPTION=$(cat "$WORKSPACE/description.md" 2>/dev/null || echo "")
RUN_META=$(cat "$WORKSPACE/run_meta.json" 2>/dev/null || echo "{}")
WORKSPACE_LS=$(ls -la "$WORKSPACE" 2>/dev/null || echo "")
DATA_SAMPLE=$(head -5 "$WORKSPACE/data/"*.jsonl 2>/dev/null || head -5 "$WORKSPACE/data/"*.json 2>/dev/null || echo "No data files found")

PROMPT_FILE="$WORKSPACE/miro_prompt.md"
CONTEXT_FILE="$WORKSPACE/miro_context.env"
JSONL_LOG="$WORKSPACE/agent.jsonl"

cat > "$PROMPT_FILE" << EOF
You are an external agent delegated by AutoRL-Bench.

Your job is to complete the benchmark task autonomously inside the current workspace.

## Task
- TASK: ${TASK}
- BASE_MODEL: ${BASE_MODEL}
- MODEL_PATH: ${MODEL_PATH}
- DATA_PATH: ${DATA_PATH}
- OUTPUT_DIR: ${OUTPUT_DIR}
- GRADING_SERVER_URL: ${GRADING_SERVER_URL}

## Task Description
${DESCRIPTION}

## AutoRL-Bench Instructions
${INSTRUCTIONS}

## run_meta.json
\`\`\`json
${RUN_META}
\`\`\`

## Workspace Contents
\`\`\`
${WORKSPACE_LS}
\`\`\`

## Data Sample
\`\`\`
${DATA_SAMPLE}
\`\`\`

## Required Outcome
1. Work only inside the workspace.
2. Write any self-authored code under ./code.
3. Save trained or generated model artifacts under ./output.
4. Submit results to the grading server with:
   curl -X POST "\$GRADING_SERVER_URL/submit" -H "Content-Type: application/json" -d '{"model_path":"./output/v1"}'
5. Iterate if useful until time runs out.

## Helper Files
- ./timer.sh : check remaining time
- ./description.md : benchmark-specific task description
- ./instructions.md : AutoRL-Bench general instructions
- ./run_meta.json : current time budget state
EOF

cat > "$CONTEXT_FILE" << EOF
export TASK="${TASK}"
export BASE_MODEL="${BASE_MODEL}"
export WORKSPACE="${WORKSPACE}"
export MODEL_PATH="${MODEL_PATH}"
export DATA_PATH="${DATA_PATH}"
export OUTPUT_DIR="${OUTPUT_DIR}"
export GRADING_SERVER_URL="${GRADING_SERVER_URL}"
export MIRO_PROMPT_FILE="${PROMPT_FILE}"
EOF

run_command_mode() {
    if [ -z "$MIRO_ENTRYPOINT" ]; then
        echo "ERROR: MIRO_ENTRYPOINT is required when MIRO_MODE=command"
        echo "Example:"
        echo '  export MIRO_ENTRYPOINT='\''python path/to/runner.py --workspace "$WORKSPACE" --prompt-file "$MIRO_PROMPT_FILE"'\'''
        return 2
    fi

    echo "Launching external Miro entrypoint..."
    (
        cd "$WORKSPACE"
        export MIRO_PROMPT_FILE="$PROMPT_FILE"
        timeout "$MIRO_TIMEOUT" bash -lc "$MIRO_ENTRYPOINT"
    ) 2>&1 | tee "$JSONL_LOG"
}

run_mirothinker_benchmark_mode() {
    local project_root app_dir dataset_dir run_dir
    local llm_config llm_provider llm_model llm_base_url llm_api_key llm_max_tokens
    local judge_api_key judge_base_url
    local local_proxy_port local_proxy_pid local_proxy_base_url local_proxy_config
    local local_driver_alias local_proxy_log litellm_bin exit_code
    local judge_upstream_model
    local benchmark_name tool_overrides

    project_root="${MIRO_PROJECT_ROOT:-/root/cwy/projects/MiroThinker}"
    app_dir="${MIRO_APP_DIR:-$project_root/apps/miroflow-agent}"
    dataset_dir="$WORKSPACE/miro_dataset"
    run_dir="${MIRO_HYDRA_RUN_DIR:-$WORKSPACE/miro_runs/${MIRO_SYSTEM}_$(date +%Y%m%d_%H%M%S)}"
    benchmark_name="${MIRO_BENCHMARK_NAME:-deepsearchqa}"
    llm_config="${MIRO_LLM_CONFIG:-qwen-3}"
    llm_provider="${MIRO_LLM_PROVIDER:-openai}"
    llm_model="${MIRO_LLM_MODEL:-openrouter/openai/gpt-5.2}"
    llm_base_url="${MIRO_LLM_BASE_URL:-http://10.100.193.46:4004/v1}"
    llm_api_key="${MIRO_LLM_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_API_KEY:-}}}"
    llm_max_tokens="${MIRO_LLM_MAX_TOKENS:-1024}"
    judge_upstream_model="${MIRO_JUDGE_UPSTREAM_MODEL:-openrouter/openai/gpt-4o}"
    judge_api_key="${MIRO_JUDGE_API_KEY:-$llm_api_key}"
    judge_base_url="${MIRO_JUDGE_BASE_URL:-$llm_base_url}"
    litellm_bin="${MIRO_LITELLM_BIN:-/root/cwy/.venv/bin/litellm}"
    local_driver_alias="${MIRO_LOCAL_MODEL_ALIAS:-${llm_model##*/}}"

    if [ ! -d "$app_dir" ]; then
        echo "ERROR: MiroThinker app dir not found: $app_dir"
        return 2
    fi
    if [ -z "$llm_api_key" ]; then
        echo "ERROR: MIRO_LLM_API_KEY is required for mirothinker_benchmark mode"
        return 2
    fi

    python3 "$SCRIPT_DIR/bridge.py" prepare-benchmark \
        --workspace "$WORKSPACE" \
        --output-dir "$dataset_dir" \
        --task "$TASK" \
        --base-model "$BASE_MODEL" >/dev/null

    mkdir -p "$run_dir"

    local_proxy_port="$(
        python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    )"
    local_proxy_base_url="http://127.0.0.1:${local_proxy_port}"
    local_proxy_config="$WORKSPACE/miro_local_proxy.yaml"
    local_proxy_log="$WORKSPACE/miro_local_proxy.log"

    python3 "$SCRIPT_DIR/bridge.py" write-proxy-config \
        --output-file "$local_proxy_config" \
        --driver-alias "$local_driver_alias" \
        --upstream-model "$llm_model" \
        --judge-upstream-model "$judge_upstream_model" \
        --upstream-api-base "$llm_base_url" \
        --upstream-api-key "$llm_api_key" >/dev/null

    env -u DEBUG "$litellm_bin" \
        --config "$local_proxy_config" \
        --port "$local_proxy_port" \
        --host 127.0.0.1 >"$local_proxy_log" 2>&1 &
    local_proxy_pid=$!

    for _ in $(seq 1 30); do
        if curl -sf "$local_proxy_base_url/health" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if ! curl -sf "$local_proxy_base_url/health" >/dev/null 2>&1; then
        echo "ERROR: Local LiteLLM proxy failed to start"
        echo "See log: $local_proxy_log"
        kill "$local_proxy_pid" 2>/dev/null || true
        return 2
    fi

    llm_model="$local_driver_alias"
    llm_base_url="$local_proxy_base_url"
    llm_api_key="${MIRO_LOCAL_PROXY_API_KEY:-local-miro-key}"
    judge_api_key="$llm_api_key"
    judge_base_url="$llm_base_url"

    tool_overrides=(
        "agent=single_agent_keep5"
        "agent.main_agent.tools=[]"
        "agent.main_agent.max_turns=20"
        "agent.keep_tool_result=0"
        "agent.context_compress_limit=0"
        "benchmark=$benchmark_name"
        "benchmark.data.data_dir=$dataset_dir"
        "benchmark.data.metadata_file=standardized_data.jsonl"
        "benchmark.execution.max_tasks=1"
        "benchmark.execution.max_concurrent=1"
        "benchmark.execution.pass_at_k=1"
        "llm=$llm_config"
        "llm.provider=$llm_provider"
        "llm.model_name=$llm_model"
        "llm.base_url=$llm_base_url"
        "llm.api_key=$llm_api_key"
        "llm.max_tokens=$llm_max_tokens"
        "llm.async_client=true"
        "hydra.run.dir=$run_dir"
    )

    echo "Launching MiroThinker benchmark runner..."
    exit_code=0
    (
        cd "$app_dir"
        export OPENAI_API_KEY="$judge_api_key"
        export OPENAI_BASE_URL="$judge_base_url"
        timeout "$MIRO_TIMEOUT" uv run python benchmarks/common_benchmark.py "${tool_overrides[@]}"
    ) 2>&1 | tee "$JSONL_LOG" || exit_code=$?

    kill "$local_proxy_pid" 2>/dev/null || true
    wait "$local_proxy_pid" 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        return "$exit_code"
    fi

    python3 "$SCRIPT_DIR/bridge.py" extract-result \
        --log-dir "$run_dir" \
        --output-file "$WORKSPACE/summary.md" || true
}

run_mirothinker_single_task_mode() {
    local project_root app_dir run_dir output_json
    local llm_config llm_provider llm_model llm_base_url llm_api_key llm_max_tokens
    local local_proxy_port local_proxy_pid local_proxy_base_url local_proxy_config
    local local_driver_alias local_proxy_log litellm_bin exit_code
    local judge_upstream_model

    project_root="${MIRO_PROJECT_ROOT:-/root/cwy/projects/MiroThinker}"
    app_dir="${MIRO_APP_DIR:-$project_root/apps/miroflow-agent}"
    run_dir="${MIRO_HYDRA_RUN_DIR:-$WORKSPACE/miro_runs/${MIRO_SYSTEM}_$(date +%Y%m%d_%H%M%S)}"
    output_json="$WORKSPACE/miro_single_task_result.json"
    llm_config="${MIRO_LLM_CONFIG:-qwen-3}"
    llm_provider="${MIRO_LLM_PROVIDER:-openai}"
    llm_model="${MIRO_LLM_MODEL:-openrouter/openai/gpt-5.2}"
    llm_base_url="${MIRO_LLM_BASE_URL:-http://10.100.193.46:4004/v1}"
    llm_api_key="${MIRO_LLM_API_KEY:-${OPENAI_API_KEY:-${ANTHROPIC_API_KEY:-}}}"
    llm_max_tokens="${MIRO_LLM_MAX_TOKENS:-1024}"
    judge_upstream_model="${MIRO_JUDGE_UPSTREAM_MODEL:-openrouter/openai/gpt-4o}"
    litellm_bin="${MIRO_LITELLM_BIN:-/root/cwy/.venv/bin/litellm}"
    local_driver_alias="${MIRO_LOCAL_MODEL_ALIAS:-${llm_model##*/}}"

    if [ ! -d "$app_dir" ]; then
        echo "ERROR: MiroThinker app dir not found: $app_dir"
        return 2
    fi
    if [ -z "$llm_api_key" ]; then
        echo "ERROR: MIRO_LLM_API_KEY is required for mirothinker_single_task mode"
        return 2
    fi

    mkdir -p "$run_dir"

    local_proxy_port="$(
        python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    )"
    local_proxy_base_url="http://127.0.0.1:${local_proxy_port}"
    local_proxy_config="$WORKSPACE/miro_local_proxy.yaml"
    local_proxy_log="$WORKSPACE/miro_local_proxy.log"

    python3 "$SCRIPT_DIR/bridge.py" write-proxy-config \
        --output-file "$local_proxy_config" \
        --driver-alias "$local_driver_alias" \
        --upstream-model "$llm_model" \
        --judge-upstream-model "$judge_upstream_model" \
        --upstream-api-base "$llm_base_url" \
        --upstream-api-key "$llm_api_key" >/dev/null

    env -u DEBUG "$litellm_bin" \
        --config "$local_proxy_config" \
        --port "$local_proxy_port" \
        --host 127.0.0.1 >"$local_proxy_log" 2>&1 &
    local_proxy_pid=$!

    for _ in $(seq 1 30); do
        if curl -sf "$local_proxy_base_url/health" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if ! curl -sf "$local_proxy_base_url/health" >/dev/null 2>&1; then
        echo "ERROR: Local LiteLLM proxy failed to start"
        echo "See log: $local_proxy_log"
        kill "$local_proxy_pid" 2>/dev/null || true
        return 2
    fi

    exit_code=0
    (
        cd "$app_dir"
        uv run python "$SCRIPT_DIR/mirothinker_single_task.py" \
            --app-dir "$app_dir" \
            --task-id "autorl_${TASK}" \
            --task-description "$(cat "$PROMPT_FILE")" \
            --log-dir "$run_dir" \
            --output-file "$output_json" \
            --llm-provider "$llm_provider" \
            --llm-model "$local_driver_alias" \
            --llm-base-url "$local_proxy_base_url" \
            --llm-api-key local-miro-key \
            --llm-max-tokens "$llm_max_tokens"
    ) 2>&1 | tee "$JSONL_LOG" || exit_code=$?

    kill "$local_proxy_pid" 2>/dev/null || true
    wait "$local_proxy_pid" 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        return "$exit_code"
    fi

    python3 - <<'PY' "$output_json" "$WORKSPACE/summary.md"
import json
import sys
from pathlib import Path

result_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
result = json.loads(result_path.read_text(encoding="utf-8"))

lines = ["# Miro Result", ""]
boxed = result.get("final_boxed_answer") or ""
summary = result.get("final_summary") or ""
log_file = result.get("log_file_path") or ""
if boxed:
    lines.extend(["## Boxed Answer", "", boxed.strip(), ""])
if summary:
    lines.extend(["## Summary", "", summary.strip(), ""])
if log_file:
    lines.extend(["## Log File", "", str(log_file), ""])
summary_path.write_text("\n".join(lines), encoding="utf-8")
PY
}

case "$MIRO_MODE" in
    command)
        run_command_mode
        EXIT_CODE=$?
        ;;
    mirothinker_benchmark)
        run_mirothinker_benchmark_mode
        EXIT_CODE=$?
        ;;
    mirothinker_single_task)
        run_mirothinker_single_task_mode
        EXIT_CODE=$?
        ;;
    *)
        echo "ERROR: Unsupported MIRO_MODE: $MIRO_MODE"
        echo "Supported modes: command, mirothinker_benchmark, mirothinker_single_task"
        exit 2
        ;;
esac

echo ""
echo "--- DIAGNOSTICS ---"
echo "exit_code: $EXIT_CODE"
END_EPOCH=$(date +%s)
ELAPSED=$(( END_EPOCH - START_EPOCH ))
printf "elapsed: %02d:%02d:%02d\n" $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60))
echo "prompt_file: $PROMPT_FILE"
echo "context_file: $CONTEXT_FILE"
echo "model_files: $(ls "$OUTPUT_DIR/" 2>/dev/null | wc -l) dirs in output/"
echo "code_files: $(ls "$WORKSPACE/code/" 2>/dev/null | wc -l) files in code/"
echo "summary_exists: $([ -f "$WORKSPACE/summary.md" ] && echo yes || echo no)"
echo "--- END DIAGNOSTICS ---"

echo "Miro generic agent exited with code: $EXIT_CODE"
exit $EXIT_CODE
