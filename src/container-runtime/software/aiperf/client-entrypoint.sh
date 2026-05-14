#!/usr/bin/env bash
# =============================================================================
# AIPerf Client Entrypoint
#
# Waits for the lmcache-server to be ready on localhost:30080, then runs
# AIPerf profile against it. Produces CMS-format JSON/CSV + HTML report.
# =============================================================================

# Source CMS common library
if [ -f /opt/cms-utils/cms_common.sh ]; then
    source /opt/cms-utils/cms_common.sh
else
    echo "[ERROR] CMS common library not found"
    exit 1
fi

CMS_SCRIPT_NAME="aiperf-client"
CMS_VERSION="1.0.0"

RESULTS_MOUNT="/opt/aiperf-bench/container_results"
AIPERF_DIR="/opt/aiperf-bench"
SUITE_NAME="${AIPERF_SUITE_NAME:-ocp-cms-aiperf}"

CMS_OUTPUT_PATH="${RESULTS_MOUNT}"
mkdir -p "${CMS_OUTPUT_PATH}"

# Archive previous run
_existing=$(find "${CMS_OUTPUT_PATH}" -mindepth 1 -maxdepth 1 -not -name "previous_runs" 2>/dev/null)
if [ -n "${_existing}" ]; then
    _ts=$(date '+%Y%m%d-%H%M%S')
    _archive="${CMS_OUTPUT_PATH}/previous_runs/${_ts}"
    mkdir -p "${_archive}"
    for _item in "${CMS_OUTPUT_PATH}"/*; do
        [ "$(basename "${_item}")" = "previous_runs" ] && continue
        mv "${_item}" "${_archive}/" 2>/dev/null || true
    done
fi

cms_trap_ctrlc
cms_log_stdout_stderr "${CMS_OUTPUT_PATH}"
cms_display_start_info "aiperf-client ${SUITE_NAME}"

cms_log_info "SUITE_NAME       : ${SUITE_NAME}"
cms_log_info "LMCACHE_BACKEND  : ${LMCACHE_BACKEND:-cpu_offload}"
cms_log_info "MODEL            : ${AIPERF_MODEL:-meta-llama/Llama-3.1-8B-Instruct}"
cms_log_info "ENDPOINT_TYPE    : ${AIPERF_ENDPOINT_TYPE:-chat}"
cms_log_info "CONCURRENCY      : ${AIPERF_CONCURRENCY:-10}"
cms_log_info "REQUEST_COUNT    : ${AIPERF_REQUEST_COUNT:-100}"

# -------------------------------------------------------------------------
# Collect system BOM
# -------------------------------------------------------------------------
cms_log_info "Collecting system information..."
cms_collect_sysinfo "${RESULTS_MOUNT}/sysinfo"
cms_query_topology

# -------------------------------------------------------------------------
# Install extra packages
# -------------------------------------------------------------------------
if [ -n "${EXTRA_PIP_PACKAGES:-}" ]; then
    pip install ${EXTRA_PIP_PACKAGES} || true
fi

# -------------------------------------------------------------------------
# Resolve serving endpoint URL
# -------------------------------------------------------------------------
SERVER_URL="${AIPERF_SERVER_URL:-http://localhost:30080}"
cms_log_info "SERVER_URL       : ${SERVER_URL}"

# -------------------------------------------------------------------------
# Wait for serving endpoint to be ready
# -------------------------------------------------------------------------
TIMEOUT=900
ELAPSED=0

cms_log_info "Waiting for serving endpoint: ${SERVER_URL}/v1/models"

while [ ${ELAPSED} -lt ${TIMEOUT} ]; do
    if curl -s "${SERVER_URL}/v1/models" > /dev/null 2>&1; then
        cms_log_info "Server is ready! (waited ${ELAPSED}s)"
        MODEL_RESPONSE=$(curl -s "${SERVER_URL}/v1/models")
        cms_log_info "Available models: ${MODEL_RESPONSE}"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        cms_log_info "Still waiting for server... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
done

if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
    cms_log_error "Timed out waiting for serving endpoint (${TIMEOUT}s)"
    cms_log_error "Is the lmcache-server container running?"
    exit 1
fi

# -------------------------------------------------------------------------
# Extract model name from server
# -------------------------------------------------------------------------
MODEL_KEY=$(curl -s "${SERVER_URL}/v1/models" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data['data'][0]['id'])
except:
    print('${AIPERF_MODEL:-meta-llama/Llama-3.1-8B-Instruct}')
" 2>/dev/null)
cms_log_info "Model key: ${MODEL_KEY}"

# -------------------------------------------------------------------------
# Build AIPerf command
# -------------------------------------------------------------------------
ARTIFACT_DIR="${RESULTS_MOUNT}/aiperf_results"
mkdir -p "${ARTIFACT_DIR}"

MODEL="${AIPERF_MODEL:-${MODEL_KEY}}"
ENDPOINT_TYPE="${AIPERF_ENDPOINT_TYPE:-chat}"
CONCURRENCY="${AIPERF_CONCURRENCY:-10}"
REQUEST_COUNT="${AIPERF_REQUEST_COUNT:-100}"
STREAMING="${AIPERF_STREAMING:-true}"
ISL="${AIPERF_ISL:-}"
OSL="${AIPERF_OSL:-}"
REQUEST_RATE="${AIPERF_REQUEST_RATE:-}"
WARMUP_COUNT="${AIPERF_WARMUP_REQUEST_COUNT:-5}"
TOKENIZER="${AIPERF_TOKENIZER:-}"
NUM_PROFILE_RUNS="${AIPERF_NUM_PROFILE_RUNS:-1}"

# Strip protocol/port to get just host:port for --url
AIPERF_URL=$(echo "${SERVER_URL}" | sed 's|^https\?://||')

AIPERF_ARGS=(
    profile
    --model "${MODEL}"
    --endpoint-type "${ENDPOINT_TYPE}"
    --url "${AIPERF_URL}"
    --artifact-dir "${ARTIFACT_DIR}"
    --warmup-request-count "${WARMUP_COUNT}"
)

# Streaming
if [ "${STREAMING}" = "true" ]; then
    AIPERF_ARGS+=(--streaming)
fi

# Concurrency vs request-rate mode
if [ -n "${REQUEST_RATE}" ]; then
    AIPERF_ARGS+=(--request-rate "${REQUEST_RATE}" --request-count "${REQUEST_COUNT}")
else
    AIPERF_ARGS+=(--concurrency "${CONCURRENCY}" --request-count "${REQUEST_COUNT}")
fi

# Input/output sequence lengths
[ -n "${ISL}" ] && AIPERF_ARGS+=(--isl "${ISL}")
[ -n "${OSL}" ] && AIPERF_ARGS+=(--osl "${OSL}")

# Tokenizer
[ -n "${TOKENIZER}" ] && AIPERF_ARGS+=(--tokenizer "${TOKENIZER}")

# Multi-run confidence
[ "${NUM_PROFILE_RUNS}" -gt 1 ] 2>/dev/null && AIPERF_ARGS+=(--num-profile-runs "${NUM_PROFILE_RUNS}")

# Public dataset
if [ -n "${AIPERF_PUBLIC_DATASET:-}" ]; then
    AIPERF_ARGS+=(--public-dataset "${AIPERF_PUBLIC_DATASET}")
fi

# Input file (custom prompts / trace)
if [ -n "${AIPERF_INPUT_FILE:-}" ]; then
    AIPERF_ARGS+=(--input-file "${AIPERF_INPUT_FILE}")
    [ -n "${AIPERF_CUSTOM_DATASET_TYPE:-}" ] && \
        AIPERF_ARGS+=(--custom-dataset-type "${AIPERF_CUSTOM_DATASET_TYPE}")
fi

# Fixed schedule (trace replay)
if [ "${AIPERF_FIXED_SCHEDULE:-false}" = "true" ]; then
    AIPERF_ARGS+=(--fixed-schedule)
fi

# Goodput SLOs
[ -n "${AIPERF_GOODPUT_TTFT:-}" ] && AIPERF_ARGS+=(--goodput "ttft:${AIPERF_GOODPUT_TTFT}")
[ -n "${AIPERF_GOODPUT_LATENCY:-}" ] && AIPERF_ARGS+=(--goodput "request_latency:${AIPERF_GOODPUT_LATENCY}")

# Extra args passthrough
if [ -n "${AIPERF_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    AIPERF_ARGS+=(${AIPERF_EXTRA_ARGS})
fi

# -------------------------------------------------------------------------
# Run AIPerf
# -------------------------------------------------------------------------
cms_log_info "Starting AIPerf benchmark..."
cms_log_info "Command: aiperf ${AIPERF_ARGS[*]}"

BENCH_EXIT=0
cd "${AIPERF_DIR}"

export HF_TOKEN="${HF_TOKEN:-}"

aiperf "${AIPERF_ARGS[@]}" 2>&1 || BENCH_EXIT=$?

if [ ${BENCH_EXIT} -ne 0 ]; then
    cms_log_error "AIPerf exited with code ${BENCH_EXIT}"
fi

# -------------------------------------------------------------------------
# Record backend metadata
# -------------------------------------------------------------------------
mkdir -p "${RESULTS_MOUNT}/config"
cat > "${RESULTS_MOUNT}/config/lmcache_backend_info.json" << EOF
{
    "backend": "${LMCACHE_BACKEND:-cpu_offload}",
    "model": "${MODEL}",
    "max_model_len": "${VLLM_MAX_MODEL_LEN:-4096}",
    "endpoint_type": "${ENDPOINT_TYPE}",
    "concurrency": "${CONCURRENCY}",
    "request_count": "${REQUEST_COUNT}",
    "request_rate": "${REQUEST_RATE:-null}",
    "streaming": ${STREAMING}
}
EOF

# -------------------------------------------------------------------------
# Parse results into CMS format
# -------------------------------------------------------------------------
cms_log_info "Parsing results..."
python3 "${AIPERF_DIR}/parse_results.py" "${RESULTS_MOUNT}" "${SUITE_NAME}" || \
    cms_log_warn "Parser returned non-zero"

# -------------------------------------------------------------------------
# Generate HTML report + tarball
# -------------------------------------------------------------------------
cms_generate_report "${RESULTS_MOUNT}" "aiperf-${SUITE_NAME}" || true
cms_display_end_info
cms_package_results "${RESULTS_MOUNT}" || true

exit ${BENCH_EXIT}
