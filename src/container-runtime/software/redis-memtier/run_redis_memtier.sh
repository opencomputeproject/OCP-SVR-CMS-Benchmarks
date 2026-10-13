#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - Redis + Memtier Benchmark Runner (Container Runtime)
#
# This script runs inside the container. It:
#   1. Sources the CMS common library for logging, topology, etc.
#   2. Collects comprehensive system hardware and software BOM
#   3. Starts a single redis-server with NUMA bindings from environment variables
#   4. Runs memtier_benchmark phases (fill, read, mixed) against the local redis-server
#   5. Snapshots redis INFO and per-node memory placement (numastat) after each phase
#   6. Parses results, then generates an HTML report and results tarball
#################################################################################################

# Source the CMS common library
source /opt/cms-utils/cms_common.sh

# Benchmark identity
CMS_SCRIPT_NAME="redis-memtier-bench"
CMS_VERSION="0.1.0"
CMS_OUTPUT_PATH="."

# Trap Ctrl-C
cms_trap_ctrlc

#################################################################################################
# Environment variable defaults
#################################################################################################

BENCH_NAME="redis_memtier"
BENCH_DIR="/opt/redis-bench"
DATA_DIR="${BENCH_DIR}/data"
SERVER_BIN="redis-server"
CLI_BIN="redis-cli"
SERVER_CONF="${BENCH_DIR}/redis.conf"
SERVER_PORT=6379

_CPU_NUMA_NODE="${CPU_NUMA_NODE:-0}"
_MEM_NUMA_NODES="${MEM_NUMA_NODES:-0}"
_NUMA_POLICY="${NUMA_POLICY:-}"
_SERVER_CPU_LIST="${SERVER_CPU_LIST:-}"
_CLIENT_CPU_NUMA_NODE="${CLIENT_CPU_NUMA_NODE:-${_CPU_NUMA_NODE}}"
_CLIENT_CPU_LIST="${CLIENT_CPU_LIST:-}"
_SERVER_MAXMEMORY="${REDIS_MAXMEMORY:-2576980377}"
_SERVER_MAXMEMORY_POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}"
_SERVER_APPENDONLY="${REDIS_APPENDONLY:-yes}"
_SERVER_IO_THREADS="${REDIS_IO_THREADS:-}"
_SERVER_EXTRA_ARGS="${REDIS_EXTRA_ARGS:-}"
_MEMTIER_PHASES="${MEMTIER_PHASES:-fill read mixed}"
_MEMTIER_PERCENTILES="${MEMTIER_PERCENTILES:-50,90,95,99,99.9}"
_MEMTIER_EXTRA_ARGS="${MEMTIER_EXTRA_ARGS:-}"
_TEST_NOTE="${TEST_NOTE:-Default Settings}"

# Per-phase memtier parameters and the flag each one maps to
PHASE_PARAMS=(TEST_TIME CLIENTS THREADS PIPELINE DATA_SIZE RATIO KEY_PATTERN KEY_MINIMUM KEY_MAXIMUM RATE_LIMIT)
declare -A MEMTIER_FLAGS=(
    [TEST_TIME]="--test-time"
    [CLIENTS]="--clients"
    [THREADS]="--threads"
    [PIPELINE]="--pipeline"
    [DATA_SIZE]="--data-size"
    [RATIO]="--ratio"
    [KEY_PATTERN]="--key-pattern"
    [KEY_MINIMUM]="--key-minimum"
    [KEY_MAXIMUM]="--key-maximum"
    [RATE_LIMIT]="--rate-limiting"
)

# Per-phase defaults. An empty default means the flag is omitted and memtier's own default applies.
declare -A PHASE_DEFAULTS=(
    # fill: write-only, sequential keys, populates the keyspace
    [FILL_TEST_TIME]=240   [FILL_CLIENTS]=20   [FILL_THREADS]=10  [FILL_PIPELINE]=10
    [FILL_DATA_SIZE]=1024  [FILL_RATIO]="1:0"  [FILL_KEY_PATTERN]="P:P"
    [FILL_KEY_MINIMUM]=1   [FILL_KEY_MAXIMUM]=100000  [FILL_RATE_LIMIT]=""
    # read: read-only, rate limited, latency at a fixed load
    [READ_TEST_TIME]=240   [READ_CLIENTS]=10   [READ_THREADS]=10  [READ_PIPELINE]=1
    [READ_DATA_SIZE]=1024  [READ_RATIO]="0:1"  [READ_KEY_PATTERN]="P:P"
    [READ_KEY_MINIMUM]=1   [READ_KEY_MAXIMUM]=100000  [READ_RATE_LIMIT]=500
    # mixed: 1:10 set:get, unthrottled, throughput
    [MIXED_TEST_TIME]=3600 [MIXED_CLIENTS]=50  [MIXED_THREADS]=4  [MIXED_PIPELINE]=1
    [MIXED_DATA_SIZE]=32   [MIXED_RATIO]="1:10" [MIXED_KEY_PATTERN]="R:R"
    [MIXED_KEY_MINIMUM]=1 [MIXED_KEY_MAXIMUM]=100000 [MIXED_RATE_LIMIT]=""
)

RESULTS_FILE="results.csv"
SERVER_LOG="${PWD}/server.log"
SERVER_PID=""

# Resolve a phase parameter: environment override, else the phase default
# args: phase (fill|read|mixed), parameter name (e.g. CLIENTS)
phase_param() {
    local name="${1^^}_${2}"
    local val="${!name}"
    echo "${val:-${PHASE_DEFAULTS[${name}]}}"
}

#################################################################################################
# Server lifecycle helpers
#################################################################################################

server_cli() {
    "${CLI_BIN}" -h 127.0.0.1 -p "${SERVER_PORT}" "$@"
}

wait_for_server() {
    local i
    for i in $(seq 1 30); do
        if server_cli ping 2>/dev/null | grep -q PONG; then
            return 0
        fi
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            return 1
        fi
        sleep 1
    done
    return 1
}

stop_server() {
    [ -z "${SERVER_PID}" ] && return 0
    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        cms_log_info "Stopping ${SERVER_BIN}..."
        server_cli shutdown nosave >/dev/null 2>&1 || kill "${SERVER_PID}" 2>/dev/null
        local i
        for i in $(seq 1 30); do
            kill -0 "${SERVER_PID}" 2>/dev/null || break
            sleep 1
        done
        kill -9 "${SERVER_PID}" 2>/dev/null
    fi
    wait "${SERVER_PID}" 2>/dev/null
    SERVER_PID=""
}

# Ensure the server is stopped however the script exits (including docker stop / SIGTERM)
trap stop_server EXIT
trap 'exit 143' TERM

# Capture server state and per-NUMA-node memory placement of the server process
# args: snapshot tag (e.g. "baseline", "fill")
snapshot_server() {
    local tag=$1
    server_cli INFO all > "server_info_${tag}.txt" 2>&1
    numastat -p "${SERVER_PID}" > "numastat_${tag}.txt" 2>&1
}

#################################################################################################
# Start
#################################################################################################

cms_log_stdout_stderr "."
cms_display_start_info "$*"

cms_log_info "Test Note: ${_TEST_NOTE}"
cms_log_info "Configuration:"
cms_log_info "  Server CPU NUMA Node:  ${_CPU_NUMA_NODE}"
cms_log_info "  Server CPU List:       ${_SERVER_CPU_LIST:-<whole node>}"
cms_log_info "  Server Memory Nodes:   ${_MEM_NUMA_NODES}"
cms_log_info "  NUMA Policy:           ${_NUMA_POLICY:-<none>}"
cms_log_info "  Client CPU NUMA Node:  ${_CLIENT_CPU_NUMA_NODE}"
cms_log_info "  Client CPU List:       ${_CLIENT_CPU_LIST:-<whole node>}"
cms_log_info "  maxmemory:             ${_SERVER_MAXMEMORY}"
cms_log_info "  maxmemory-policy:      ${_SERVER_MAXMEMORY_POLICY}"
cms_log_info "  appendonly:            ${_SERVER_APPENDONLY}"
cms_log_info "  io-threads:            ${_SERVER_IO_THREADS:-<default>}"
cms_log_info "  Memtier Phases:        ${_MEMTIER_PHASES}"

#################################################################################################
# 1. Verify required tools and phase names
#################################################################################################

cms_verify_cmds numactl numastat bc "${SERVER_BIN}" "${CLI_BIN}" memtier_benchmark

read -ra PHASES <<< "${_MEMTIER_PHASES}"
for _phase in "${PHASES[@]}"; do
    case "${_phase}" in
        fill|read|mixed) ;;
        *) cms_log_error "Unknown memtier phase '${_phase}'. Valid phases: fill read mixed"; exit 1 ;;
    esac
done

#################################################################################################
# 2. Collect system BOM and record versions
#################################################################################################

cms_collect_sysinfo ./sysinfo

cp "${BENCH_DIR}/versions.txt" ./versions.txt 2>/dev/null
{
    echo "${SERVER_BIN}_version_string=$(${SERVER_BIN} --version)"
    echo "memtier_version_string=$(memtier_benchmark --version 2>&1 | head -1)"
} >> ./versions.txt

#################################################################################################
# 3. Query platform topology
#################################################################################################

cms_query_topology

#################################################################################################
# 4. Start the server
#################################################################################################

# Build numactl arguments using arrays so user-provided values with spaces
# (e.g. NUMA_POLICY="--interleave 0,2") don't cause word-splitting problems.
NUMACTL_SERVER_ARGS=()
if [ -n "$_SERVER_CPU_LIST" ]; then
    NUMACTL_SERVER_ARGS+=("--physcpubind=${_SERVER_CPU_LIST}")
elif [ -n "$_CPU_NUMA_NODE" ]; then
    NUMACTL_SERVER_ARGS+=("--cpunodebind=${_CPU_NUMA_NODE}")
fi
if [ -n "$_MEM_NUMA_NODES" ] && [ -z "$_NUMA_POLICY" ]; then
    NUMACTL_SERVER_ARGS+=("--membind=${_MEM_NUMA_NODES}")
fi
if [ -n "$_NUMA_POLICY" ]; then
    read -ra _policy_parts <<< "$_NUMA_POLICY"
    NUMACTL_SERVER_ARGS+=("${_policy_parts[@]}")
fi

NUMACTL_CLIENT_ARGS=()
if [ -n "$_CLIENT_CPU_LIST" ]; then
    NUMACTL_CLIENT_ARGS+=("--physcpubind=${_CLIENT_CPU_LIST}")
elif [ -n "$_CLIENT_CPU_NUMA_NODE" ]; then
    NUMACTL_CLIENT_ARGS+=("--cpunodebind=${_CLIENT_CPU_NUMA_NODE}")
fi

# Fail fast with a clear message if the requested bindings cannot be applied
# (no NUMA support on the host/VM, a node that does not exist, an invalid CPU list, ...)
for _binding in "server:NUMACTL_SERVER_ARGS" "client:NUMACTL_CLIENT_ARGS"; do
    _role="${_binding%%:*}"
    declare -n _args="${_binding#*:}"
    if ! _err=$(numactl "${_args[@]}" true 2>&1); then
        cms_log_error "numactl cannot apply the ${_role} binding '${_args[*]}': ${_err}"
        cms_log_error "Check CPU_NUMA_NODE / MEM_NUMA_NODES / NUMA_POLICY / *_CPU_LIST and that the host exposes NUMA (numactl --hardware)."
        exit 1
    fi
    unset -n _args
done

SERVER_ARGS=("${SERVER_CONF}"
    --port "${SERVER_PORT}"
    --maxmemory "${_SERVER_MAXMEMORY}"
    --maxmemory-policy "${_SERVER_MAXMEMORY_POLICY}"
    --appendonly "${_SERVER_APPENDONLY}"
    --dir "${DATA_DIR}"
    --logfile "${SERVER_LOG}")
if [ -n "$_SERVER_IO_THREADS" ]; then
    SERVER_ARGS+=(--io-threads "${_SERVER_IO_THREADS}")
fi
if [ -n "$_SERVER_EXTRA_ARGS" ]; then
    read -ra _extra_parts <<< "$_SERVER_EXTRA_ARGS"
    SERVER_ARGS+=("${_extra_parts[@]}")
fi

# Start from an empty data directory so AOF files from a previous run are never reloaded
rm -rf "${DATA_DIR:?}"
mkdir -p "${DATA_DIR}"

cms_log_info "Starting ${SERVER_BIN}..."
cms_log_info "  numactl ${NUMACTL_SERVER_ARGS[*]} ${SERVER_BIN} ${SERVER_ARGS[*]}"
numactl "${NUMACTL_SERVER_ARGS[@]}" "${SERVER_BIN}" "${SERVER_ARGS[@]}" &
SERVER_PID=$!

if ! wait_for_server; then
    cms_log_error "${SERVER_BIN} failed to start. Last lines of ${SERVER_LOG}:"
    tail -20 "${SERVER_LOG}" 2>/dev/null
    exit 1
fi
cms_log_info "${SERVER_BIN} running with PID ${SERVER_PID}"

# Record the effective server configuration and the pre-load memory placement
server_cli CONFIG GET '*' > server_config.txt 2>&1
snapshot_server baseline

#################################################################################################
# 5. Run memtier phases
#################################################################################################

# Warn when the fill dataset is far smaller than maxmemory: the run will not exercise
# memory capacity or eviction, so placement on the target memory tier is barely tested.
_maxmemory_bytes=$(server_cli CONFIG GET maxmemory 2>/dev/null | tail -1)
_fill_kmin=$(phase_param fill KEY_MINIMUM); _fill_kmax=$(phase_param fill KEY_MAXIMUM)
_fill_dsize=$(phase_param fill DATA_SIZE)
# Empty values fall back to memtier's defaults (key range 0-10000000, 32 byte values)
_fill_keys=$(( ${_fill_kmax:-10000000} - ${_fill_kmin:-0} + 1 ))
_fill_bytes=$(( _fill_keys * ${_fill_dsize:-32} ))
cms_log_info "Fill dataset (values only): ${_fill_keys} keys x ${_fill_dsize:-32} B = ${_fill_bytes} bytes; maxmemory = ${_maxmemory_bytes} bytes"
if [ -n "${_maxmemory_bytes}" ] && [ "${_maxmemory_bytes}" -gt 0 ] && [ $(( _fill_bytes * 2 )) -lt "${_maxmemory_bytes}" ]; then
    cms_log_warn "Fill dataset is less than half of maxmemory. Raise FILL_KEY_MAXIMUM / READ_KEY_MAXIMUM to stress memory capacity."
fi

# Run one memtier phase
# args: phase (fill|read|mixed)
# return: memtier exit code
run_phase() {
    local phase=$1
    local args=(--server 127.0.0.1
                --port "${SERVER_PORT}"
                --protocol=redis
                --run-count=1
                --show-config
                --hide-histogram
                --print-percentiles "${_MEMTIER_PERCENTILES}"
                --json-out-file "memtier_${phase}.json")
    local p val
    for p in "${PHASE_PARAMS[@]}"; do
        val=$(phase_param "${phase}" "${p}")
        [ -n "${val}" ] && args+=("${MEMTIER_FLAGS[${p}]}=${val}")
    done
    if [ -n "$_MEMTIER_EXTRA_ARGS" ]; then
        local _extra
        read -ra _extra <<< "$_MEMTIER_EXTRA_ARGS"
        args+=("${_extra[@]}")
    fi

    cms_log_info "Starting memtier phase '${phase}'..."
    cms_log_info "  numactl ${NUMACTL_CLIENT_ARGS[*]} memtier_benchmark ${args[*]}"
    numactl "${NUMACTL_CLIENT_ARGS[@]}" memtier_benchmark "${args[@]}" > "memtier_${phase}.txt" 2>&1
    local rc=$?

    snapshot_server "${phase}"

    if [ ${rc} -ne 0 ]; then
        cms_log_error "memtier phase '${phase}' exited with code ${rc}. Check memtier_${phase}.txt for details."
    else
        cms_log_info "Completed memtier phase '${phase}'"
    fi
    return ${rc}
}

bench_exit=0
start_time=$(date +%s%N)
for _phase in "${PHASES[@]}"; do
    if ! run_phase "${_phase}"; then
        bench_exit=1
        cms_log_error "Skipping remaining phases: later phases depend on the keyspace populated by earlier ones."
        break
    fi
    # A fill that is too short for the key range (or one using S:S, where every connection walks
    # the whole range on its own) leaves keys unwritten. Eviction also lowers the key count.
    if [ "${_phase}" = "fill" ]; then
        _dbsize=$(server_cli DBSIZE 2>/dev/null)
        if [ "${_dbsize:-0}" -lt $(( _fill_keys * 99 / 100 )) ]; then
            cms_log_warn "Fill populated ${_dbsize:-0} of ${_fill_keys} keys. Lengthen FILL_TEST_TIME or check eviction (maxmemory)."
        else
            cms_log_info "Fill populated ${_dbsize} of ${_fill_keys} keys"
        fi
    fi
done
end_time=$(date +%s%N)
time_taken=$(echo "scale=9; ($end_time - $start_time)/1000000000" | bc)

#################################################################################################
# 6. Stop the server
#################################################################################################

stop_server

#################################################################################################
# 7. Write and parse results
#################################################################################################

cms_log_info "Writing results..."

if [ ! -f "${RESULTS_FILE}" ]; then
    echo "benchmark,note,elapsed_time_sec" > "${RESULTS_FILE}"
fi
echo "${BENCH_NAME},\"${_TEST_NOTE}\",${time_taken}" >> "${RESULTS_FILE}"

# Parse before generating the report so results_*.json is included in the HTML
cms_log_info "Parsing memtier results..."
python3 "${BENCH_DIR}/parse_results.py" . "${BENCH_NAME}" || \
    cms_log_warn "Results parser returned non-zero"

#################################################################################################
# 8. Generate report
#################################################################################################

cms_generate_report . "${BENCH_NAME}" "./${RESULTS_FILE}"

#################################################################################################
# 9. Done
#################################################################################################

cms_log_info "===== Benchmark Complete ====="
cms_log_info "Test Note:    ${_TEST_NOTE}"
cms_log_info "Elapsed Time: ${time_taken} seconds"
cms_log_info "Results:      results_${BENCH_NAME}.json / results_${BENCH_NAME}.csv"
cms_log_info "Raw output:   memtier_<phase>.txt / memtier_<phase>.json"
cms_log_info "Placement:    numastat_<phase>.txt"
cms_log_info "System BOM:   sysinfo/"
cms_log_info "HTML Report:  ${BENCH_NAME}_report.html"

cms_display_end_info

exit ${bench_exit}
