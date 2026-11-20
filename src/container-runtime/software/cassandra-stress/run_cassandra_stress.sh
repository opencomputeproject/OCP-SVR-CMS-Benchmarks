#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - Cassandra + cassandra-stress Benchmark Runner (Container Runtime)
#
# This script runs inside the container. It:
#   1. Sources the CMS common library for logging, topology, etc.
#   2. Collects comprehensive system hardware and software BOM
#   3. Generates cassandra.yaml (stock + overrides + env) and starts a single Cassandra node
#      with NUMA bindings from environment variables
#   4. Runs cassandra-stress phases (populate, a, b, c) against the local node
#   5. Snapshots per-NUMA-node memory placement (numastat) and nodetool stats after each phase
#   6. Parses results, then generates an HTML report and results tarball
#################################################################################################

# Source the CMS common library
source /opt/cms-utils/cms_common.sh

# Benchmark identity
CMS_SCRIPT_NAME="cassandra-stress-bench"
CMS_VERSION="0.1.0"
CMS_OUTPUT_PATH="."

# Trap Ctrl-C
cms_trap_ctrlc

#################################################################################################
# Environment variable defaults
#################################################################################################

BENCH_NAME="cassandra_stress"
BENCH_DIR="/opt/cassandra-bench"
DATA_ROOT="/data/cassandra"
CONF_DIR="${BENCH_DIR}/conf"
PROFILE="${BENCH_DIR}/blogpost_effective.yaml"
KEYSPACE="stresscql"
TABLE="blogposts"

_CPU_NUMA_NODE="${CPU_NUMA_NODE:-0}"
_MEM_NUMA_NODES="${MEM_NUMA_NODES:-0}"
_NUMA_POLICY="${NUMA_POLICY:-}"
_SERVER_CPU_LIST="${SERVER_CPU_LIST:-}"
_CLIENT_CPU_NUMA_NODE="${CLIENT_CPU_NUMA_NODE:-${_CPU_NUMA_NODE}}"
_CLIENT_CPU_LIST="${CLIENT_CPU_LIST:-}"
_CASSANDRA_HEAP_SIZE="${CASSANDRA_HEAP_SIZE:-8G}"
_MEMTABLE_ALLOCATION_TYPE="${MEMTABLE_ALLOCATION_TYPE:-heap_buffers}"
_CASSANDRA_JVM_EXTRA_OPTS="${CASSANDRA_JVM_EXTRA_OPTS:-}"
_DOMAIN_POPULATION="${DOMAIN_POPULATION:-10000000}"
_STRESS_PHASES="${STRESS_PHASES:-populate a b c}"
_STRESS_CL="${STRESS_CL:-LOCAL_QUORUM}"
_STRESS_POP_DIST="${STRESS_POP_DIST:-gaussian}"
_STRESS_LOG_INTERVAL="${STRESS_LOG_INTERVAL:-60}"
_STRESS_EXTRA_ARGS="${STRESS_EXTRA_ARGS:-}"
_COMPACTION_WAIT="${COMPACTION_WAIT:-1800}"
_TEST_NOTE="${TEST_NOTE:-Default Settings}"

# Per-phase defaults (profiles A/B/C from the production recipe, single node, no rate caps)
declare -A PHASE_DEFAULTS=(
    [POPULATE_THREADS]=64
    # a: read heavy
    [A_OPS]="insert=20,singlepost=100" [A_DURATION]="120m" [A_THREADS]=20 [A_RATE]=""
    # b: blog mix
    [B_OPS]="insert=2,singlepost=8"    [B_DURATION]="120m" [B_THREADS]=80 [B_RATE]=""
    # c: write heavy
    [C_OPS]="insert=60,singlepost=40"  [C_DURATION]="120m" [C_THREADS]=20 [C_RATE]=""
)

# cassandra-stress maps each seed to a domain id drawn pseudo-randomly from the profile's domain
# population, so N seeds over N ids reach only ~63% of them. Size the id space well above the seed
# space so the DOMAIN_POPULATION seeds map to (nearly) DOMAIN_POPULATION distinct domains.
DOMAIN_ID_SPACE_FACTOR=1000

RESULTS_FILE="results.csv"
PHASE_TIMES_FILE="phase_times.csv"
LOG_DIR="${PWD}/cassandra_logs"
SERVER_PID=""

# Resolve a phase parameter: environment override, else the phase default
# args: phase (populate|a|b|c), parameter name (e.g. THREADS)
phase_param() {
    local name="${1^^}_${2}"
    local val="${!name}"
    echo "${val:-${PHASE_DEFAULTS[${name}]}}"
}

#################################################################################################
# Server lifecycle helpers
#################################################################################################

nt() {
    nodetool -h 127.0.0.1 "$@"
}

# Wait for the node to report Up/Normal and for the CQL port to accept connections
wait_for_server() {
    local i
    for i in $(seq 1 120); do
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            return 1
        fi
        if nt status 2>/dev/null | grep -q '^UN' && (echo > /dev/tcp/127.0.0.1/9042) 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

stop_server() {
    [ -z "${SERVER_PID}" ] && return 0
    if kill -0 "${SERVER_PID}" 2>/dev/null; then
        cms_log_info "Stopping Cassandra..."
        nt drain >/dev/null 2>&1
        kill "${SERVER_PID}" 2>/dev/null
        local i
        for i in $(seq 1 60); do
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

# Capture per-NUMA-node memory placement, server CPU time, and nodetool stats.
# (Server GC per phase comes from cassandra-stress itself, which polls it over JMX; that polling
# also resets the counters behind `nodetool gcstats`, so gcstats is not snapshotted.)
# args: snapshot tag (e.g. "baseline", "a")
snapshot_server() {
    local tag=$1
    numastat -p "${SERVER_PID}" > "numastat_${tag}.txt" 2>&1
    cat "/proc/${SERVER_PID}/stat" > "proc_stat_${tag}.txt" 2>&1
    nt info > "nodetool_info_${tag}.txt" 2>&1
    nt tpstats > "nodetool_tpstats_${tag}.txt" 2>&1
    if [ "${tag}" != "baseline" ]; then
        nt tablestats "${KEYSPACE}.${TABLE}" > "nodetool_tablestats_${tag}.txt" 2>&1
    fi
    du -sb "${DATA_ROOT}/data" "${DATA_ROOT}/commitlog" > "disk_usage_${tag}.txt" 2>&1
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
cms_log_info "  Heap Size:             ${_CASSANDRA_HEAP_SIZE}"
cms_log_info "  Memtable Allocation:   ${_MEMTABLE_ALLOCATION_TYPE}"
cms_log_info "  Domain Population:     ${_DOMAIN_POPULATION}"
cms_log_info "  Stress Phases:         ${_STRESS_PHASES}"
cms_log_info "  Consistency Level:     ${_STRESS_CL}"
cms_log_info "  Key Distribution:      ${_STRESS_POP_DIST}(1..${_DOMAIN_POPULATION})"

#################################################################################################
# 1. Verify required tools and phase names
#################################################################################################

cms_verify_cmds numactl numastat bc java cassandra nodetool cassandra-stress python3

read -ra PHASES <<< "${_STRESS_PHASES}"
for _phase in "${PHASES[@]}"; do
    case "${_phase}" in
        populate|a|b|c) ;;
        *) cms_log_error "Unknown stress phase '${_phase}'. Valid phases: populate a b c"; exit 1 ;;
    esac
done

if ! [[ "${_DOMAIN_POPULATION}" =~ ^[0-9]+$ ]] || [ "${_DOMAIN_POPULATION}" -lt 1 ]; then
    cms_log_error "DOMAIN_POPULATION must be a positive integer (got '${_DOMAIN_POPULATION}')"
    exit 1
fi

case "${_STRESS_POP_DIST}" in
    gaussian|uniform) ;;
    *) cms_log_error "STRESS_POP_DIST must be gaussian or uniform (got '${_STRESS_POP_DIST}')"; exit 1 ;;
esac

#################################################################################################
# 2. Collect system BOM and record versions
#################################################################################################

cms_collect_sysinfo ./sysinfo

cp "${BENCH_DIR}/versions.txt" ./versions.txt 2>/dev/null
{
    echo "java_version_string=$(java -version 2>&1 | head -1)"
    echo "clk_tck=$(getconf CLK_TCK)"
} >> ./versions.txt

#################################################################################################
# 3. Query platform topology
#################################################################################################

cms_query_topology

#################################################################################################
# 4. Generate configuration
#################################################################################################

# Work on a copy of the release conf directory so the image stays pristine
rm -rf "${CONF_DIR}"
cp -r "${CASSANDRA_HOME}/conf" "${CONF_DIR}"
export CASSANDRA_CONF="${CONF_DIR}"
export CASSANDRA_LOG_DIR="${LOG_DIR}"
export MAX_HEAP_SIZE="${_CASSANDRA_HEAP_SIZE}"
mkdir -p "${LOG_DIR}"

if ! MEMTABLE_ALLOCATION_TYPE="${_MEMTABLE_ALLOCATION_TYPE}" python3 "${BENCH_DIR}/configure_cassandra.py" \
        "${CASSANDRA_HOME}/conf/cassandra.yaml" "${BENCH_DIR}/cassandra-overrides.yaml" "${CONF_DIR}/cassandra.yaml"; then
    cms_log_error "Failed to generate cassandra.yaml"
    exit 1
fi

# Datacenter / rack for GossipingPropertyFileSnitch
printf 'dc=datacenter1\nrack=rack1\n' > "${CONF_DIR}/cassandra-rackdc.properties"

# Extra JVM options, one per line, appended to the server JVM options file
if [ -n "$_CASSANDRA_JVM_EXTRA_OPTS" ]; then
    read -ra _jvm_parts <<< "$_CASSANDRA_JVM_EXTRA_OPTS"
    printf '%s\n' "${_jvm_parts[@]}" >> "${CONF_DIR}/jvm17-server.options"
fi

# GC log: GC events only, with wall-clock timestamps. The stock setting also logs heap/age/promotion
# detail into 10 x 10MB files, which rotates away the early phases of a multi-hour run.
# cassandra-env.sh skips its default when -Xlog:gc is already present in the options file.
if ! grep -qE '^-Xlog:gc' "${CONF_DIR}/jvm17-server.options"; then
    echo "-Xlog:gc=info:file=${LOG_DIR}/gc.log:time,uptime,pid,tid,level:filecount=10,filesize=100M" \
        >> "${CONF_DIR}/jvm17-server.options"
fi

cp "${CONF_DIR}/cassandra.yaml" ./cassandra.yaml

# Stress profile with the domain id space sized from DOMAIN_POPULATION (see DOMAIN_ID_SPACE_FACTOR)
_domain_ids=$(( _DOMAIN_POPULATION * DOMAIN_ID_SPACE_FACTOR ))
sed "s/population: uniform(1\.\.10M)/population: uniform(1..${_domain_ids})/" \
    "${BENCH_DIR}/blogpost.yaml" > "${PROFILE}"
if ! grep -q "population: uniform(1..${_domain_ids})" "${PROFILE}"; then
    cms_log_error "Could not set the domain population in the stress profile"
    exit 1
fi
cp "${PROFILE}" ./stress_profile.yaml

#################################################################################################
# 5. Start Cassandra
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

# bin/cassandra re-launches the JVM under "numactl $NUMACTL_ARGS" and defaults NUMACTL_ARGS to
# --interleave=all, which would override any binding applied from outside. Hand it our server
# binding instead so the JVM runs with exactly the requested CPU and memory policy.
export NUMACTL_ARGS="${NUMACTL_SERVER_ARGS[*]}"

# Start from empty data directories so data from a previous run is never reused
for _sub in data commitlog hints saved_caches cdc_raw; do
    rm -rf "${DATA_ROOT:?}/${_sub}"
    mkdir -p "${DATA_ROOT}/${_sub}"
done

cms_log_info "Starting Cassandra..."
cms_log_info "  NUMACTL_ARGS=\"${NUMACTL_ARGS}\" MAX_HEAP_SIZE=${MAX_HEAP_SIZE} cassandra -R -f"
cassandra -R -f > "${LOG_DIR}/stdout.log" 2>&1 &
SERVER_PID=$!

if ! wait_for_server; then
    cms_log_error "Cassandra failed to start. Last lines of ${LOG_DIR}/stdout.log:"
    tail -30 "${LOG_DIR}/stdout.log" 2>/dev/null
    exit 1
fi
cms_log_info "Cassandra running with PID ${SERVER_PID}"
cms_log_info "  JVM command: $(tr '\0' ' ' < "/proc/${SERVER_PID}/cmdline" | cut -c1-200)..."

snapshot_server baseline

#################################################################################################
# 6. Run cassandra-stress phases
#################################################################################################

# Run one cassandra-stress phase
# args: phase (populate|a|b|c)
# return: cassandra-stress exit code
run_phase() {
    local phase=$1
    local threads ops rate
    local args=(user "profile=${PROFILE}")

    # Every phase draws keys from the same seed space (1..DOMAIN_POPULATION), so the profiles
    # read and update exactly the domains that populate wrote.
    if [ "${phase}" = "populate" ]; then
        # Insert one row into every domain, visiting seeds sequentially
        threads=$(phase_param populate THREADS)
        args+=("ops(insert=1)" "n=${_DOMAIN_POPULATION}" "cl=${_STRESS_CL}" no-warmup
               -pop "seq=1..${_DOMAIN_POPULATION}")
    else
        threads=$(phase_param "${phase}" THREADS)
        ops=$(phase_param "${phase}" OPS)
        args+=("ops(${ops})" "duration=$(phase_param "${phase}" DURATION)" "cl=${_STRESS_CL}" no-warmup
               -pop "dist=${_STRESS_POP_DIST}(1..${_DOMAIN_POPULATION})")
    fi

    args+=(-rate "threads=${threads}")
    rate=$(phase_param "${phase}" RATE)
    [ -n "${rate}" ] && args+=("fixed=${rate}/s")

    args+=(-errors ignore
           -node 127.0.0.1
           -port native=9042
           -log "interval=${_STRESS_LOG_INTERVAL}"
           -graph "file=stress_graph_${phase}.html" "title=${phase}")
    if [ -n "$_STRESS_EXTRA_ARGS" ]; then
        local _extra
        read -ra _extra <<< "$_STRESS_EXTRA_ARGS"
        args+=("${_extra[@]}")
    fi

    cms_log_info "Starting cassandra-stress phase '${phase}'..."
    cms_log_info "  numactl ${NUMACTL_CLIENT_ARGS[*]} cassandra-stress ${args[*]}"
    cat "/proc/${SERVER_PID}/stat" > "proc_stat_${phase}_start.txt" 2>&1
    local t_start t_end
    t_start=$(date +%s.%N)
    numactl "${NUMACTL_CLIENT_ARGS[@]}" cassandra-stress "${args[@]}" > "stress_${phase}.txt" 2>&1
    local rc=$?
    t_end=$(date +%s.%N)
    echo "${phase},${t_start},${t_end},${rc}" >> "${PHASE_TIMES_FILE}"

    snapshot_server "${phase}"

    if [ ${rc} -ne 0 ]; then
        cms_log_error "cassandra-stress phase '${phase}' exited with code ${rc}. Check stress_${phase}.txt for details."
    else
        cms_log_info "Completed cassandra-stress phase '${phase}'"
    fi
    return ${rc}
}

# After populate: flush memtables and let compaction settle so every profile starts from the
# same on-disk state, then check how many partitions were written.
settle_after_populate() {
    cms_log_info "Flushing memtables and waiting up to ${_COMPACTION_WAIT}s for compactions..."
    nt flush "${KEYSPACE}" "${TABLE}" 2>&1
    local waited=0 pending
    while [ "${waited}" -lt "${_COMPACTION_WAIT}" ]; do
        pending=$(nt compactionstats 2>/dev/null | awk -F: '/pending tasks/ {gsub(/ /, "", $2); print $2; exit}')
        [ "${pending:-0}" = "0" ] && break
        sleep 10
        waited=$(( waited + 10 ))
    done
    cms_log_info "Compactions pending after ${waited}s: ${pending:-0}"

    local partitions
    partitions=$(nt tablestats "${KEYSPACE}.${TABLE}" 2>/dev/null | awk -F: '/Number of partitions \(estimate\)/ {gsub(/ /, "", $2); print $2; exit}')
    if [ -n "${partitions}" ] && [ "${partitions}" -lt $(( _DOMAIN_POPULATION * 9 / 10 )) ]; then
        cms_log_warn "Populate wrote ~${partitions} of ${_DOMAIN_POPULATION} partitions (estimate). Reads may miss."
    else
        cms_log_info "Populate wrote ~${partitions:-?} of ${_DOMAIN_POPULATION} partitions (estimate)"
    fi
    nt tablestats "${KEYSPACE}.${TABLE}" > nodetool_tablestats_populate_settled.txt 2>&1
}

bench_exit=0
echo "phase,start_epoch,end_epoch,exit_code" > "${PHASE_TIMES_FILE}"
start_time=$(date +%s%N)
for _phase in "${PHASES[@]}"; do
    if ! run_phase "${_phase}"; then
        bench_exit=1
        cms_log_error "Skipping remaining phases."
        break
    fi
    [ "${_phase}" = "populate" ] && settle_after_populate
done
end_time=$(date +%s%N)
time_taken=$(echo "scale=9; ($end_time - $start_time)/1000000000" | bc)

#################################################################################################
# 7. Stop the server
#################################################################################################

stop_server

#################################################################################################
# 8. Write and parse results
#################################################################################################

cms_log_info "Writing results..."

if [ ! -f "${RESULTS_FILE}" ]; then
    echo "benchmark,note,elapsed_time_sec" > "${RESULTS_FILE}"
fi
echo "${BENCH_NAME},\"${_TEST_NOTE}\",${time_taken}" >> "${RESULTS_FILE}"

# Parse before generating the report so results_*.json is included in the HTML
cms_log_info "Parsing cassandra-stress results..."
python3 "${BENCH_DIR}/parse_results.py" . "${BENCH_NAME}" || \
    cms_log_warn "Results parser returned non-zero"

#################################################################################################
# 9. Generate report
#################################################################################################

cms_generate_report . "${BENCH_NAME}" "./${RESULTS_FILE}"

#################################################################################################
# 10. Done
#################################################################################################

cms_log_info "===== Benchmark Complete ====="
cms_log_info "Test Note:    ${_TEST_NOTE}"
cms_log_info "Elapsed Time: ${time_taken} seconds"
cms_log_info "Results:      results_${BENCH_NAME}.json / results_${BENCH_NAME}.csv"
cms_log_info "Raw output:   stress_<phase>.txt / stress_graph_<phase>.html / timeseries_${BENCH_NAME}_<phase>.csv"
cms_log_info "Placement:    numastat_<phase>.txt"
cms_log_info "Server logs:  cassandra_logs/ (system.log, gc.log)"
cms_log_info "System BOM:   sysinfo/"
cms_log_info "HTML Report:  ${BENCH_NAME}_report.html"

cms_display_end_info

exit ${bench_exit}
