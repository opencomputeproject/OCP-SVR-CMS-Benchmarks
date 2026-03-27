#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - Memcached Benchmark Runner (Container Runtime)
#
# This script runs inside the container. It:
#   1. Sources the CMS common library for logging, topology, etc.
#   2. Collects comprehensive system hardware and software BOM
#   3. Starts a memcached server with NUMA bindings from environment variables
#   4. Runs memaslap load generator against the local memcached instance
#   5. Collects and formats results
#   6. Generates an HTML report and results tarball
#################################################################################################

# Source the CMS common library
source /opt/cms-utils/cms_common.sh

# Benchmark identity
CMS_SCRIPT_NAME="memcached-bench"
CMS_VERSION="0.1.0"
CMS_OUTPUT_PATH="."

# Trap Ctrl-C
cms_trap_ctrlc

#################################################################################################
# Environment variable defaults
#################################################################################################

_CPU_NUMA_NODE="${CPU_NUMA_NODE:-0}"
_MEM_NUMA_NODES="${MEM_NUMA_NODES:-0}"
_NUMA_POLICY="${NUMA_POLICY:-}"
_MEMCACHED_MEMORY_MB="${MEMCACHED_MEMORY_MB:-262144}"
_MEMCACHED_THREADS="${MEMCACHED_THREADS:-}"
_MEMCACHED_EXTRA_ARGS="${MEMCACHED_EXTRA_ARGS:-}"
_MEMASLAP_THREADS="${MEMASLAP_THREADS:-16}"
_MEMASLAP_CONCURRENCY="${MEMASLAP_CONCURRENCY:-256}"
_MEMASLAP_DURATION="${MEMASLAP_DURATION:-180s}"
_MEMASLAP_WINDOW_SIZE="${MEMASLAP_WINDOW_SIZE:-131072}"
_MEMASLAP_EXTRA_ARGS="${MEMASLAP_EXTRA_ARGS:-}"
_TEST_NOTE="${TEST_NOTE:-Default Settings}"

RESULTS_FILE="results.csv"
RAW_RESULTS="raw_results.txt"

#################################################################################################
# Start
#################################################################################################

cms_display_start_info "$*"

cms_log_info "Test Note: ${_TEST_NOTE}"
cms_log_info "Configuration:"
cms_log_info "  CPU NUMA Node:      ${_CPU_NUMA_NODE}"
cms_log_info "  Memory NUMA Nodes:  ${_MEM_NUMA_NODES}"
cms_log_info "  NUMA Policy:        ${_NUMA_POLICY:-<none>}"
cms_log_info "  Memcached Memory:   ${_MEMCACHED_MEMORY_MB} MB"
cms_log_info "  Memcached Threads:  ${_MEMCACHED_THREADS:-<auto>}"
cms_log_info "  Memaslap Threads:   ${_MEMASLAP_THREADS}"
cms_log_info "  Memaslap Conns:     ${_MEMASLAP_CONCURRENCY}"
cms_log_info "  Memaslap Duration:  ${_MEMASLAP_DURATION}"
cms_log_info "  Memaslap Window:    ${_MEMASLAP_WINDOW_SIZE}"

#################################################################################################
# 1. Verify required tools
#################################################################################################

cms_verify_cmds numactl memcached bc

if ! command -v memaslap &>/dev/null; then
    cms_log_error "memaslap not found. The libmemcached build may have failed."
    exit 1
fi

#################################################################################################
# 2. Collect system BOM
#################################################################################################

cms_collect_sysinfo ./sysinfo

#################################################################################################
# 3. Query platform topology
#################################################################################################

cms_query_topology

#################################################################################################
# 4. Start memcached server
#################################################################################################

# Build numactl arguments for the memcached server using arrays.
# Arrays preserve argument boundaries so spaces in user-provided values
# (e.g. NUMA_POLICY="--interleave 0,2") don't cause word-splitting problems.
NUMACTL_SERVER_ARGS=()
if [ -n "$_CPU_NUMA_NODE" ]; then
    NUMACTL_SERVER_ARGS+=("--cpunodebind=${_CPU_NUMA_NODE}")
fi
if [ -n "$_MEM_NUMA_NODES" ]; then
    if [ -z "$_NUMA_POLICY" ]; then
        NUMACTL_SERVER_ARGS+=("--membind=${_MEM_NUMA_NODES}")
    fi
fi
if [ -n "$_NUMA_POLICY" ]; then
    read -ra _policy_parts <<< "$_NUMA_POLICY"
    NUMACTL_SERVER_ARGS+=("${_policy_parts[@]}")
fi

# Build memcached server arguments
MEMCACHED_ARGS=(-m "${_MEMCACHED_MEMORY_MB}" -u root -l 127.0.0.1 -p 11211)
if [ -n "$_MEMCACHED_THREADS" ]; then
    MEMCACHED_ARGS+=(-t "${_MEMCACHED_THREADS}")
fi
if [ -n "$_MEMCACHED_EXTRA_ARGS" ]; then
    read -ra _extra_parts <<< "$_MEMCACHED_EXTRA_ARGS"
    MEMCACHED_ARGS+=("${_extra_parts[@]}")
fi

cms_log_info "Starting memcached server..."
cms_log_info "  numactl ${NUMACTL_SERVER_ARGS[*]} memcached ${MEMCACHED_ARGS[*]}"
numactl "${NUMACTL_SERVER_ARGS[@]}" memcached "${MEMCACHED_ARGS[@]}" &
MEMCACHED_PID=$!

sleep 2

if ! kill -0 $MEMCACHED_PID 2>/dev/null; then
    cms_log_error "Memcached failed to start. Exiting."
    exit 1
fi
cms_log_info "Memcached running with PID ${MEMCACHED_PID}"

#################################################################################################
# 5. Run memaslap benchmark
#################################################################################################

MEMASLAP_ARGS=(-s 127.0.0.1:11211)
MEMASLAP_ARGS+=(-T "${_MEMASLAP_THREADS}")
MEMASLAP_ARGS+=(-c "${_MEMASLAP_CONCURRENCY}")
MEMASLAP_ARGS+=(-t "${_MEMASLAP_DURATION}")
MEMASLAP_ARGS+=(-X "${_MEMASLAP_WINDOW_SIZE}")
if [ -n "$_MEMASLAP_EXTRA_ARGS" ]; then
    read -ra _extra_parts <<< "$_MEMASLAP_EXTRA_ARGS"
    MEMASLAP_ARGS+=("${_extra_parts[@]}")
fi

# Bind client to the same CPU node by default
NUMACTL_CLIENT_ARGS=()
if [ -n "$_CPU_NUMA_NODE" ]; then
    NUMACTL_CLIENT_ARGS+=("--cpunodebind=${_CPU_NUMA_NODE}")
fi

cms_log_info "Starting memaslap benchmark..."
cms_log_info "  numactl ${NUMACTL_CLIENT_ARGS[*]} memaslap ${MEMASLAP_ARGS[*]}"

start_time=$(date +%s%N)
numactl "${NUMACTL_CLIENT_ARGS[@]}" memaslap "${MEMASLAP_ARGS[@]}" > "${RAW_RESULTS}" 2>&1
memaslap_exit=$?
end_time=$(date +%s%N)
time_taken=$(echo "scale=9; ($end_time - $start_time)/1000000000" | bc)

if [ $memaslap_exit -ne 0 ]; then
    cms_log_error "Memaslap exited with code ${memaslap_exit}. Check ${RAW_RESULTS} for details."
fi

#################################################################################################
# 6. Stop memcached
#################################################################################################

cms_log_info "Stopping memcached..."
kill $MEMCACHED_PID 2>/dev/null
wait $MEMCACHED_PID 2>/dev/null

#################################################################################################
# 7. Write results
#################################################################################################

cms_log_info "Writing results..."

if [ ! -f "${RESULTS_FILE}" ]; then
    echo "benchmark,note,elapsed_time_sec" > "${RESULTS_FILE}"
fi

echo "memcached,\"${_TEST_NOTE}\",${time_taken}" >> "${RESULTS_FILE}"

if grep -q "Run time" "${RAW_RESULTS}" 2>/dev/null; then
    grep "Run time" "${RAW_RESULTS}" >> "${RESULTS_FILE}"
fi

#################################################################################################
# 8. Generate report
#################################################################################################

cms_generate_report . memcached "./${RESULTS_FILE}"

#################################################################################################
# 9. Done
#################################################################################################

cms_log_info "===== Benchmark Complete ====="
cms_log_info "Test Note:    ${_TEST_NOTE}"
cms_log_info "Elapsed Time: ${time_taken} seconds"
cms_log_info "Results:      ${RESULTS_FILE}"
cms_log_info "Raw output:   ${RAW_RESULTS}"
cms_log_info "System BOM:   sysinfo/"
cms_log_info "HTML Report:  memcached_report.html"

cat "${RAW_RESULTS}"

cms_display_end_info
