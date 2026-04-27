#!/usr/bin/env bash
# =============================================================================
# LMBench Container - Environment Setup (setup_env.sh)
#
# Generates run-bench.yaml and custom spec YAML files from container
# environment variables. Called by entrypoint.sh before benchmark execution.
#
# If CUSTOM_RUN_BENCH_YAML is set (base64), decodes it directly.
# If LMBENCH_SUITE != "custom", uses the named spec file as-is.
# If LMBENCH_SUITE == "custom", builds spec from LMBENCH_* and workload vars.
# =============================================================================

source /opt/cms-utils/cms_common.sh 2>/dev/null || true

LMBENCH_DIR="/opt/lmbench"
cd "${LMBENCH_DIR}"

# -------------------------------------------------------------------------
# 1. Handle direct YAML override
# -------------------------------------------------------------------------
if [ -n "${CUSTOM_RUN_BENCH_YAML:-}" ]; then
    cms_log_info "Using custom run-bench.yaml from CUSTOM_RUN_BENCH_YAML env var"
    echo "${CUSTOM_RUN_BENCH_YAML}" | base64 -d > "${LMBENCH_DIR}/run-bench.yaml"
    cms_log_info "Decoded custom run-bench.yaml ($(wc -l < run-bench.yaml) lines)"
    return 0 2>/dev/null || exit 0
fi

# -------------------------------------------------------------------------
# 2. Build run-bench.yaml
# -------------------------------------------------------------------------
INFRASTRUCTURE="${LMBENCH_INFRASTRUCTURE:-Local-Flat}"
SUITE="${LMBENCH_SUITE:-custom}"

if [ "${SUITE}" = "custom" ]; then
    SPEC_FILE="custom/ocp-cms-spec.yaml"
else
    SPEC_FILE="${SUITE}"
fi

cat > "${LMBENCH_DIR}/run-bench.yaml" << YAML
0-bench-specs:
  - ${SPEC_FILE}

1-infrastructure:
  Location: ${INFRASTRUCTURE}
YAML

cms_log_info "Generated run-bench.yaml: suite=${SPEC_FILE}, infra=${INFRASTRUCTURE}"

# -------------------------------------------------------------------------
# 3. If not custom, we're done — the named spec already exists
# -------------------------------------------------------------------------
if [ "${SUITE}" != "custom" ]; then
    if [ ! -f "${LMBENCH_DIR}/0-bench-specs/${SUITE}" ]; then
        cms_log_warn "Spec file not found: 0-bench-specs/${SUITE}"
        cms_log_warn "Available specs:"
        find "${LMBENCH_DIR}/0-bench-specs" -name "*.yaml" -type f | head -20
    fi
    return 0 2>/dev/null || exit 0
fi

# -------------------------------------------------------------------------
# 4. Build custom spec YAML from environment variables
# -------------------------------------------------------------------------
SUITE_NAME="${LMBENCH_SUITE_NAME:-ocp-cms-lmbench}"
BASELINE_TYPE="${LMBENCH_BASELINE_TYPE:-Flat}"
MODEL_URL="${LMBENCH_MODEL_URL:-meta-llama/Llama-3.1-8B-Instruct}"
API_TYPE="${LMBENCH_API_TYPE:-completions}"

mkdir -p "${LMBENCH_DIR}/0-bench-specs/custom"
SPEC_PATH="${LMBENCH_DIR}/0-bench-specs/custom/ocp-cms-spec.yaml"

# -- Serving block --
_serving_block=""
case "${BASELINE_TYPE}" in
    Flat)
        FLAT_CONFIG="${LMBENCH_FLAT_CONFIG:-basic-vllm/run-llama8B.sh}"
        _serving_block="  - Flat:
      configSelection: ${FLAT_CONFIG}
      modelURL: ${MODEL_URL}
      apiType: ${API_TYPE}"
        ;;
    SGLang)
        SGLANG_SCRIPT="${LMBENCH_SGLANG_SCRIPT:-comparison-baseline.sh}"
        _serving_block="  - SGLang:
      scriptName: ${SGLANG_SCRIPT}
      modelURL: ${MODEL_URL}
      apiType: ${API_TYPE}"
        ;;
    Dynamo)
        DYNAMO_CONFIG="${LMBENCH_DYNAMO_CONFIG:-comparison-baseline.yaml}"
        _serving_block="  - Dynamo:
      configSelection: ${DYNAMO_CONFIG}
      modelURL: ${MODEL_URL}
      apiType: ${API_TYPE}"
        ;;
    *)
        cms_log_error "Unknown LMBENCH_BASELINE_TYPE: ${BASELINE_TYPE}"
        cms_log_error "Valid: Flat, SGLang, Dynamo"
        exit 1
        ;;
esac

# -- Workload block --
WORKLOADS="${LMBENCH_WORKLOADS:-synthetic}"
_workload_block=""

# Parse comma-separated workload list
IFS=',' read -ra _wl_array <<< "${WORKLOADS}"
for _wl in "${_wl_array[@]}"; do
    _wl=$(echo "${_wl}" | tr -d ' ')
    case "${_wl}" in
        synthetic)
            # Parse QPS as potentially comma-separated list → YAML list
            _qps_yaml=$(echo "${SYNTHETIC_QPS:-0.7}" | sed 's/,/, /g')
            _workload_block="${_workload_block}
  LMCacheSynthetic:
    - NUM_USERS_WARMUP: ${SYNTHETIC_NUM_USERS_WARMUP:-650}
      NUM_USERS: ${SYNTHETIC_NUM_USERS:-350}
      NUM_ROUNDS: ${SYNTHETIC_NUM_ROUNDS:-20}
      SYSTEM_PROMPT: ${SYNTHETIC_SYSTEM_PROMPT:-0}
      CHAT_HISTORY: ${SYNTHETIC_CHAT_HISTORY:-20000}
      ANSWER_LEN: ${SYNTHETIC_ANSWER_LEN:-1000}
      QPS: [${_qps_yaml}]
      USE_SHAREGPT: ${SYNTHETIC_USE_SHAREGPT:-false}"
            ;;
        sharegpt)
            _qps_yaml=$(echo "${SHAREGPT_QPS:-1.34}" | sed 's/,/, /g')
            _workload_block="${_workload_block}
  ShareGPT:
    - LIMIT: ${SHAREGPT_LIMIT:-1000}
      MIN_ROUNDS: ${SHAREGPT_MIN_ROUNDS:-10}
      START_ROUND: ${SHAREGPT_START_ROUND:-0}
      QPS: [${_qps_yaml}]"
            ;;
        agentic)
            _intervals_yaml=$(echo "${AGENTIC_NEW_USER_INTERVALS:-1}" | sed 's/,/, /g')
            _workload_block="${_workload_block}
  Agentic:
    - NUM_USERS_WARMUP: ${AGENTIC_NUM_USERS_WARMUP:-100}
      NUM_AGENTS: ${AGENTIC_NUM_AGENTS:-10}
      NUM_ROUNDS: ${AGENTIC_NUM_ROUNDS:-20}
      SYSTEM_PROMPT: ${AGENTIC_SYSTEM_PROMPT:-0}
      CHAT_HISTORY: ${AGENTIC_CHAT_HISTORY:-256}
      ANSWER_LEN: ${AGENTIC_ANSWER_LEN:-20}
      NEW_USER_INTERVALS: [${_intervals_yaml}]"
            ;;
        random)
            _qps_yaml=$(echo "${RANDOM_QPS:-1.0}" | sed 's/,/, /g')
            _workload_block="${_workload_block}
  Random:
    - NUM_USERS: ${RANDOM_NUM_USERS:-100}
      NUM_ROUNDS: ${RANDOM_NUM_ROUNDS:-10}
      PROMPT_LEN: ${RANDOM_PROMPT_LEN:-200}
      ANSWER_LEN: ${RANDOM_ANSWER_LEN:-100}
      QPS: [${_qps_yaml}]"
            ;;
        vllm_benchmark)
            _rates_yaml=$(echo "${VLLM_BENCH_REQUEST_RATES:-1.0}" | sed 's/,/, /g')
            _workload_block="${_workload_block}
  VLLMBenchmark:
    - BACKEND: ${VLLM_BENCH_BACKEND:-vllm}
      DATASET_NAME: ${VLLM_BENCH_DATASET_NAME:-random}
      DATASET_PATH: \"${VLLM_BENCH_DATASET_PATH:-}\"
      NUM_PROMPTS: ${VLLM_BENCH_NUM_PROMPTS:-100}
      REQUEST_RATES: [${_rates_yaml}]
      TEMPERATURE: ${VLLM_BENCH_TEMPERATURE:-0.0}
      TOP_P: ${VLLM_BENCH_TOP_P:-0.9}
      TOP_K: ${VLLM_BENCH_TOP_K:-50}
      MAX_TOKENS: ${VLLM_BENCH_MAX_TOKENS:-256}
      BURSTINESS: ${VLLM_BENCH_BURSTINESS:-1.0}
      SEED: ${VLLM_BENCH_SEED:-0}
      DISABLE_TQDM: ${VLLM_BENCH_DISABLE_TQDM:-true}
      IGNORE_EOS: ${VLLM_BENCH_IGNORE_EOS:-false}
      RANDOM_INPUT_LEN: ${VLLM_BENCH_RANDOM_INPUT_LEN:-1024}
      RANDOM_OUTPUT_LEN: ${VLLM_BENCH_RANDOM_OUTPUT_LEN:-128}
      RANDOM_RANGE_RATIO: ${VLLM_BENCH_RANDOM_RANGE_RATIO:-0.0}"
            ;;
        strict_synthetic)
            _time_yaml=$(echo "${STRICT_TIME_BETWEEN_REQUESTS:-10}" | sed 's/,/, /g')
            _workload_block="${_workload_block}
  StrictSynthetic:
    - NUM_CONCURRENT_USERS: ${STRICT_NUM_CONCURRENT_USERS:-10}
      NUM_ROUNDS_PER_USER: ${STRICT_NUM_ROUNDS_PER_USER:-5}
      TIME_BETWEEN_REQUESTS_PER_USER: [${_time_yaml}]
      SHARED_SYSTEM_PROMPT_LEN: ${STRICT_SHARED_SYSTEM_PROMPT_LEN:-100}
      FIRST_PROMPT_LEN: ${STRICT_FIRST_PROMPT_LEN:-200}
      FOLLOW_UP_PROMPTS_LEN: ${STRICT_FOLLOW_UP_PROMPTS_LEN:-100}
      ANSWER_LEN: ${STRICT_ANSWER_LEN:-150}
      KV_REUSE_RATIO: ${STRICT_KV_REUSE_RATIO:-1.0}"
            ;;
        trace_replayer)
            _trace_block="    - TRACE_FILE: ${TRACE_FILE:-traces/gmi_trace.jsonl}"
            [ -n "${TRACE_START_TIME:-}" ] && _trace_block="${_trace_block}
      START_TIME: ${TRACE_START_TIME}"
            _dur="${TRACE_DURATION:-full}"
            if [ "${_dur}" = "full" ]; then
                _trace_block="${_trace_block}
      DURATION: full"
            else
                _trace_block="${_trace_block}
      DURATION: ${_dur}"
            fi
            _trace_block="${_trace_block}
      PRESERVE_TIMING: ${TRACE_PRESERVE_TIMING:-true}
      SPEED_UP: ${TRACE_SPEED_UP:-1.0}"
            [ -n "${TRACE_MAX_DELAY:-}" ] && _trace_block="${_trace_block}
      MAX_DELAY: ${TRACE_MAX_DELAY}"
            if [ -n "${TRACE_QPS:-}" ]; then
                _qps_yaml=$(echo "${TRACE_QPS}" | sed 's/,/, /g')
                _trace_block="${_trace_block}
      QPS: [${_qps_yaml}]"
            fi
            _workload_block="${_workload_block}
  TraceReplayer:
${_trace_block}"
            ;;
        *)
            cms_log_warn "Unknown workload type: ${_wl} — skipping"
            ;;
    esac
done

# -- Write spec YAML --
cat > "${SPEC_PATH}" << SPECEOF
Name: ${SUITE_NAME}

Serving:
${_serving_block}

Workload:
${_workload_block}
SPECEOF

cms_log_info "Generated custom spec: ${SPEC_PATH}"
cms_log_info "  Baseline: ${BASELINE_TYPE} / ${MODEL_URL}"
cms_log_info "  Workloads: ${WORKLOADS}"

if [ "${CMS_VERBOSITY:-0}" -ge 1 ]; then
    cms_log_debug "=== Generated run-bench.yaml ==="
    cat "${LMBENCH_DIR}/run-bench.yaml"
    cms_log_debug "=== Generated spec YAML ==="
    cat "${SPEC_PATH}"
fi
