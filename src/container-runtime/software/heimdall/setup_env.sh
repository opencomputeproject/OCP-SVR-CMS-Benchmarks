#!/usr/bin/env bash
# =============================================================================
# setup_env.sh - Generate heimdall configuration files from environment vars
#
# Heimdall expects two .env files:
#   1. self.env              - user credentials (sudo password, Slack, etc.)
#   2. $(hostname).env       - machine hardware configuration
#
# In a container running as root, these are synthesized from the
# environment variables passed in via docker-compose.
#
# If cms_common.sh is already sourced, we use its logging. Otherwise
# we fall back to plain echo.
# =============================================================================

set -euo pipefail

# Use CMS logging if available, else plain echo
if command -v cms_log_info &>/dev/null; then
    _log() { cms_log_info "$*"; }
else
    _log() { echo "[INFO] $*"; }
fi

ENV_DIR="/opt/heimdall/benchmark/basic_performance/env_files"
HOSTNAME=$(hostname)
export HEIMDALL_HOSTNAME="${HOSTNAME}"

_log "Generating heimdall environment files (hostname: ${HOSTNAME})"

# -------------------------------------------------------------------------
# 1. self.env  (credentials / notifications)
# -------------------------------------------------------------------------
cat > "${ENV_DIR}/self.env" <<EOF
Slack=0
SlackURL=
HOSTNAME=${HOSTNAME}
USER_PASSWORD=rootpassword
EOF
_log "Created: ${ENV_DIR}/self.env"

# -------------------------------------------------------------------------
# 2. $(hostname).env  (machine hardware config)
# -------------------------------------------------------------------------
DISABLE_PREFETCH="${DISABLE_PREFETCH:-True}"
BOOST_CPU="${BOOST_CPU:-True}"
SOCKET_NUMBER="${SOCKET_NUMBER:-2}"
SNC_MODE="${SNC_MODE:-1}"
DIMM_PHYSICAL_START_ADDR="${DIMM_PHYSICAL_START_ADDR:-0x800000000}"
CXL_PHYSICAL_START_ADDR="${CXL_PHYSICAL_START_ADDR:-0x4080000000}"
TEST_SIZE="${TEST_SIZE:-0x840000000}"

cat > "${ENV_DIR}/${HOSTNAME}.env" <<EOF
disable_prefetch=${DISABLE_PREFETCH}
boost_cpu=${BOOST_CPU}
socket_number=${SOCKET_NUMBER}
snc_mode=${SNC_MODE}

# for cache analysis
dimm_physical_start_addr=${DIMM_PHYSICAL_START_ADDR}
cxl_physical_start_addr=${CXL_PHYSICAL_START_ADDR}
test_size=${TEST_SIZE}
EOF
_log "Created: ${ENV_DIR}/${HOSTNAME}.env"

# -------------------------------------------------------------------------
# 3. Generate custom batch YAML for basic_performance (if params provided)
# -------------------------------------------------------------------------
BATCH_DIR="/opt/heimdall/benchmark/basic_performance/scripts/batch"

# Only generate a custom BW-vs-latency YAML if the user set BW_ params
if [ -n "${BW_THREAD_NUM_TYPE:-}" ]; then
    _log "Generating custom bw_vs_latency YAML from env vars"

    BW_THREAD_NUM_ARRAY="${BW_THREAD_NUM_ARRAY:-1,2,4,8,16}"
    THREAD_ARRAY_YAML=$(echo "${BW_THREAD_NUM_ARRAY}" | sed 's/,/, /g')

    BW_PATTERN_ITERATION="${BW_PATTERN_ITERATION:-2}"
    PAT_ITER_YAML=$(echo "${BW_PATTERN_ITERATION}" | sed 's/,/, /g')

    BW_BUFFER_SIZE_MB="${BW_BUFFER_SIZE_MB:-512}"
    BUF_YAML=$(echo "${BW_BUFFER_SIZE_MB}" | sed 's/,/, /g')

    BW_CORE_SOCKET_ARRAY="${BW_CORE_SOCKET_ARRAY:-0,1}"
    SOCKET_YAML=$(echo "${BW_CORE_SOCKET_ARRAY}" | sed 's/,/, /g')

    BW_NUMA_NODE_ARRAY="${BW_NUMA_NODE_ARRAY:-0,1}"
    NUMA_YAML=$(echo "${BW_NUMA_NODE_ARRAY}" | sed 's/,/, /g')

    BW_DELAY_ARRAY="${BW_DELAY_ARRAY:-0}"
    BW_LATENCY_STRIDE="${BW_LATENCY_STRIDE:-64}"
    BW_LATENCY_BLOCK="${BW_LATENCY_BLOCK:-64}"
    BW_LATENCY_ACCESS="${BW_LATENCY_ACCESS:-1048576}"
    BW_LOAD_BLOCK="${BW_LOAD_BLOCK:-256}"
    BW_STORE_BLOCK="${BW_STORE_BLOCK:-256}"

    BW_LOADSTORE_ARRAY="${BW_LOADSTORE_ARRAY:-0,1}"
    BW_MEM_ALLOC_ARRAY="${BW_MEM_ALLOC_ARRAY:-1}"
    BW_LATENCY_PATTERN="${BW_LATENCY_PATTERN:-1}"
    BW_BANDWIDTH_PATTERN="${BW_BANDWIDTH_PATTERN:-1}"

    cat > "${BATCH_DIR}/100_bw_vs_latency.yaml" <<YAMLEOF
job_id: 100

thread_num_type: ${BW_THREAD_NUM_TYPE}

thread_num_array: [${THREAD_ARRAY_YAML}]

pattern_iteration_array: [${PAT_ITER_YAML}]

thread_buffer_size array_megabyte: [${BUF_YAML}]

core_socket_array: [${SOCKET_YAML}]

numa_node_array: [${NUMA_YAML}]

delay_array:
$(echo "${BW_DELAY_ARRAY}" | tr ',' '\n' | sed 's/^/  - /')

loadstore_array:
$(echo "${BW_LOADSTORE_ARRAY}" | tr ',' '\n' | sed 's/^/  - /')

mem_alloc_type_array:
$(echo "${BW_MEM_ALLOC_ARRAY}" | tr ',' '\n' | sed 's/^/  - /')

latency_pattern_array:
$(echo "${BW_LATENCY_PATTERN}" | tr ',' '\n' | sed 's/^/  - /')

latency_pattern_stride_size_array_byte:
  - ${BW_LATENCY_STRIDE}

latency_pattern_block_size_array_byte:
  - ${BW_LATENCY_BLOCK}

latency_pattern_access_size_array_byte:
  - ${BW_LATENCY_ACCESS}

bandwidth_pattern_array:
$(echo "${BW_BANDWIDTH_PATTERN}" | tr ',' '\n' | sed 's/^/  - /')

bandwidth_load_pattern_block_size: [${BW_LOAD_BLOCK}]

bandwidth_store_pattern_block_size: [${BW_STORE_BLOCK}]
YAMLEOF

    _log "Created: ${BATCH_DIR}/100_bw_vs_latency.yaml"
fi

# Generate custom cache heatmap YAML if user set CACHE_ params
if [ -n "${CACHE_REPEAT:-}" ]; then
    _log "Generating custom cache_heatmap YAML from env vars"

    CACHE_TEST_TYPE="${CACHE_TEST_TYPE:-0}"
    CACHE_USE_FLUSH="${CACHE_USE_FLUSH:-0}"
    CACHE_FLUSH_TYPE="${CACHE_FLUSH_TYPE:-0}"
    CACHE_LDST_TYPE="${CACHE_LDST_TYPE:-0}"
    CACHE_CORE_ID="${CACHE_CORE_ID:-0,20}"
    CACHE_NODE_ID="${CACHE_NODE_ID:-2}"
    CACHE_ACCESS_ORDER="${CACHE_ACCESS_ORDER:-0}"
    CACHE_STRIDE_SIZES="${CACHE_STRIDE_SIZES:-0x40,0x80,0x100,0x200,0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x10000,0x20000,0x40000,0x80000,0x100000,0x200000,0x400000,0x800000,0x1000000,0x2000000,0x4000000}"
    CACHE_BLOCK_NUMS="${CACHE_BLOCK_NUMS:-0x1,0x2,0x4,0x8,0x10,0x20,0x40,0x80,0x100,0x200,0x400,0x800,0x1000,0x2000,0x4000,0x8000,0x10000,0x20000,0x40000,0x80000,0x100000}"

    cat > "${BATCH_DIR}/200_cache_heatmap.yaml" <<YAMLEOF
job_id: 200
repeat: ${CACHE_REPEAT}
test_type: ${CACHE_TEST_TYPE}
use_flush: ${CACHE_USE_FLUSH}
flush_type: [$(echo "${CACHE_FLUSH_TYPE}" | sed 's/,/, /g')]
ldst_type: [$(echo "${CACHE_LDST_TYPE}" | sed 's/,/, /g')]
core_id: [$(echo "${CACHE_CORE_ID}" | sed 's/,/, /g')]
node_id: [$(echo "${CACHE_NODE_ID}" | sed 's/,/, /g')]
access_order: [$(echo "${CACHE_ACCESS_ORDER}" | sed 's/,/, /g')]
stride_size_array: [$(echo "${CACHE_STRIDE_SIZES}" | sed 's/,/, /g')]
block_num_array: [$(echo "${CACHE_BLOCK_NUMS}" | sed 's/,/, /g')]
YAMLEOF

    _log "Created: ${BATCH_DIR}/200_cache_heatmap.yaml"
fi

_log "Environment setup complete"
