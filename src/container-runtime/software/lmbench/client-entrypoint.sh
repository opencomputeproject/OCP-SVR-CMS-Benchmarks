#!/usr/bin/env bash
# =============================================================================
# LMBench Client Entrypoint
#
# Waits for the lmcache-server to be ready on localhost:30080, then runs
# LMBench workloads via run-bench.py --start-from 3 (skip infra + baseline
# setup, go straight to workload execution).
#
# Produces CMS-format JSON/CSV + HTML report.
# =============================================================================

# Source CMS common library
if [ -f /opt/cms-utils/cms_common.sh ]; then
    source /opt/cms-utils/cms_common.sh
else
    echo "[ERROR] CMS common library not found"
    exit 1
fi

CMS_SCRIPT_NAME="lmbench-client"
CMS_VERSION="1.0.0"

RESULTS_MOUNT="/opt/lmbench/container_results"
LMBENCH_DIR="/opt/lmbench"
SUITE_NAME="${LMBENCH_SUITE_NAME:-ocp-cms-lmbench}"
WORKLOADS="${LMBENCH_WORKLOADS:-synthetic}"

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
cms_display_start_info "lmbench-client ${SUITE_NAME} ${WORKLOADS}"

cms_log_info "SUITE_NAME     : ${SUITE_NAME}"
cms_log_info "WORKLOADS      : ${WORKLOADS}"
cms_log_info "LMCACHE_BACKEND: ${LMCACHE_BACKEND:-cpu_offload}"
cms_log_info "MODEL          : ${LMBENCH_MODEL_URL:-meta-llama/Llama-3.1-8B-Instruct}"

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
# Generate LMBench spec from env vars
# -------------------------------------------------------------------------
cd "${LMBENCH_DIR}"
source "${LMBENCH_DIR}/setup_env.sh"

# -------------------------------------------------------------------------
# Resolve serving endpoint URL
# -------------------------------------------------------------------------
# Default: localhost:30080 (same-machine / shared network namespace)
# Override: set LMBENCH_SERVER_URL=http://<remote-host>:30080 for split mode
SERVER_URL="${LMBENCH_SERVER_URL:-http://localhost:30080}"

cms_log_info "SERVER_URL     : ${SERVER_URL}"

# Patch run-bench.py to use the configured endpoint instead of hardcoded localhost
if [ "${SERVER_URL}" != "http://localhost:30080" ]; then
    cms_log_info "Patching run-bench.py: localhost:30080 → ${SERVER_URL}"
    sed -i "s|http://localhost:30080|${SERVER_URL}|g" "${LMBENCH_DIR}/run-bench.py"

    # Also patch any workload generator scripts that may have the URL
    find "${LMBENCH_DIR}/3-workload-generators" -name "*.py" -exec \
        sed -i "s|http://localhost:30080|${SERVER_URL}|g" {} + 2>/dev/null || true
fi

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
# Extract KEY (model name) from server for run-bench.py --key arg
# -------------------------------------------------------------------------
MODEL_KEY=$(curl -s "${SERVER_URL}/v1/models" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data['data'][0]['id'])
except:
    print('${LMBENCH_MODEL_URL:-meta-llama/Llama-3.1-8B-Instruct}')
" 2>/dev/null)
cms_log_info "Model key: ${MODEL_KEY}"

# -------------------------------------------------------------------------
# Run LMBench workloads (stage 3 only — skip infra + baseline)
# -------------------------------------------------------------------------
cms_log_info "Starting LMBench workload execution..."

BENCH_EXIT=0
cd "${LMBENCH_DIR}"

export HF_TOKEN="${HF_TOKEN:-}"

python3 run-bench.py \
    --start-from 3 \
    --model-url "${LMBENCH_MODEL_URL:-meta-llama/Llama-3.1-8B-Instruct}" \
    --hf-token "${HF_TOKEN}" \
    --key "${MODEL_KEY}" \
    2>&1 || BENCH_EXIT=$?

if [ ${BENCH_EXIT} -ne 0 ]; then
    cms_log_error "LMBench exited with code ${BENCH_EXIT}"
fi

# -------------------------------------------------------------------------
# Copy results
# -------------------------------------------------------------------------
cms_log_info "Copying results to ${RESULTS_MOUNT}..."

if [ -d "${LMBENCH_DIR}/4-latest-results" ]; then
    mkdir -p "${RESULTS_MOUNT}/lmbench_results"
    cp -r "${LMBENCH_DIR}/4-latest-results/"* "${RESULTS_MOUNT}/lmbench_results/" 2>/dev/null || true
fi

mkdir -p "${RESULTS_MOUNT}/config"
cp "${LMBENCH_DIR}/run-bench.yaml" "${RESULTS_MOUNT}/config/" 2>/dev/null || true
[ -d "${LMBENCH_DIR}/0-bench-specs/custom" ] && \
    cp -r "${LMBENCH_DIR}/0-bench-specs/custom" "${RESULTS_MOUNT}/config/" 2>/dev/null || true

# Record which LMCache backend was used
cat > "${RESULTS_MOUNT}/config/lmcache_backend_info.json" << EOF
{
    "backend": "${LMCACHE_BACKEND:-cpu_offload}",
    "device": "${LMBENCH_DEVICE:-cpu}",
    "model": "${LMBENCH_MODEL_URL:-meta-llama/Llama-3.1-8B-Instruct}",
    "max_model_len": "${VLLM_MAX_MODEL_LEN:-4096}"
}
EOF

# -------------------------------------------------------------------------
# Parse results into CMS format
# -------------------------------------------------------------------------
cms_log_info "Parsing results..."
python3 "${LMBENCH_DIR}/parse_results.py" "${RESULTS_MOUNT}" "${SUITE_NAME}" || \
    cms_log_warn "Parser returned non-zero"

# -------------------------------------------------------------------------
# Generate HTML report + tarball
# -------------------------------------------------------------------------
cms_generate_report "${RESULTS_MOUNT}" "lmbench-${SUITE_NAME}" || true
cms_display_end_info
cms_package_results "${RESULTS_MOUNT}" || true

exit ${BENCH_EXIT}
