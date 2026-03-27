#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - Common Benchmark Library (cms_common.sh)
#
# Sourceable shell library providing shared functions for all CMS benchmark containers.
# Unifies patterns currently duplicated across mlc.sh, run-stream-scaling.sh, and lib/common.
#
# Usage: source /opt/cms-utils/cms_common.sh
#
# This file is COPY'd into every benchmark container at /opt/cms-utils/ and sourced by
# each benchmark's run script. It provides:
#
#   - Logging (info, warn, error, debug with timestamps)
#   - Output directory initialization and log capture
#   - Start/end banners with elapsed time
#   - System topology queries (sockets, cores, NUMA, CXL, hyperthreading)
#   - System info collection (calls collect_sysinfo.sh)
#   - Utility functions (convert units, verify commands, page cache, etc.)
#################################################################################################

CMS_COMMON_VERSION="0.1.0"

# Guard against double-sourcing
if [ -n "${_CMS_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CMS_COMMON_LOADED=1

#################################################################################################
# Script identity (set by the calling script, defaults provided here)
#################################################################################################

CMS_SCRIPT_NAME="${CMS_SCRIPT_NAME:-${0##*/}}"
CMS_SCRIPT_DIR="${CMS_SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[1]:-$0}")" &>/dev/null && pwd 2>/dev/null)}"
CMS_VERSION="${CMS_VERSION:-0.0.0}"

#################################################################################################
# Output paths
#################################################################################################

CMS_OUTPUT_PATH="${CMS_OUTPUT_PATH:-./${CMS_SCRIPT_NAME}.$(hostname).$(date +"%m%d-%H%M")}"
CMS_LOG_FILE=""    # Set by cms_log_stdout_stderr

#################################################################################################
# 1. Logging
#################################################################################################

cms_log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
cms_log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') - $*"; }
cms_log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2; }
cms_log_debug() {
    if [ "${CMS_VERBOSITY:-0}" -ge 1 ]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - ${BASH_SOURCE[1]##*/}:${FUNCNAME[1]}[${BASH_LINENO[0]}] $*"
    fi
}

#################################################################################################
# 2. Output directory & log capture
#################################################################################################

# Create the output directory. Removes any stale one first.
cms_init_outputs() {
    rm -rf "${CMS_OUTPUT_PATH}" 2>/dev/null
    mkdir -p "${CMS_OUTPUT_PATH}"
    cms_log_info "Output directory: ${CMS_OUTPUT_PATH}"
}

# Tee all stdout+stderr to a log file inside the output directory.
# Call AFTER cms_init_outputs.
cms_log_stdout_stderr() {
    local log_path="${1:-${CMS_OUTPUT_PATH}}"
    CMS_LOG_FILE="${log_path}/${CMS_SCRIPT_NAME}.log"
    local tee_cmd
    tee_cmd=$(command -v tee 2>/dev/null)
    if [ -n "${tee_cmd}" ]; then
        exec &> >(${tee_cmd} -a "${CMS_LOG_FILE}")
    else
        exec &> "${CMS_LOG_FILE}"
    fi
}

#################################################################################################
# 3. Start / End Banners
#################################################################################################

_CMS_START_TIME=0

cms_display_start_info() {
    _CMS_START_TIME=$(date +%s)
    echo "======================================================================="
    echo "Starting ${CMS_SCRIPT_NAME}"
    echo "${CMS_SCRIPT_NAME} Version ${CMS_VERSION}"
    echo "CMS Common Library Version ${CMS_COMMON_VERSION}"
    if [ -n "$1" ]; then
        echo "Arguments: $*"
    fi
    echo "Started: $(date --date "@${_CMS_START_TIME}" 2>/dev/null || date)"
    echo "======================================================================="
}

cms_display_end_info() {
    local end_time
    end_time=$(date +%s)
    local duration=$(( end_time - _CMS_START_TIME ))

    local days=$(( duration / 86400 ))
    local hours=$(( (duration % 86400) / 3600 ))
    local minutes=$(( (duration % 3600) / 60 ))
    local seconds=$(( duration % 60 ))

    local result=""
    [ $days    -gt 0 ] && result+="${days} day(s), "
    [ $hours   -gt 0 ] && result+="${hours} hour(s), "
    [ $minutes -gt 0 ] && result+="${minutes} minute(s), "
    result+="${seconds} second(s)"

    echo "======================================================================="
    echo "${CMS_SCRIPT_NAME} Completed"
    echo "Ended: $(date --date "@${end_time}" 2>/dev/null || date)"
    echo "Duration: ${result}"
    echo "Results: ${CMS_OUTPUT_PATH}"
    [ -n "${CMS_LOG_FILE}" ] && echo "Logfile: ${CMS_LOG_FILE}"
    echo "======================================================================="
}

#################################################################################################
# 4. Ctrl-C Handler
#################################################################################################

cms_trap_ctrlc() {
    trap '_cms_ctrlc_handler' INT
}

_cms_ctrlc_handler() {
    echo ""
    cms_log_info "Received CTRL+C - aborting"
    cms_display_end_info
    exit 1
}

#################################################################################################
# 5. Command Verification
#################################################################################################

# Verify that a list of commands exist on PATH. Exits on failure.
# Usage: cms_verify_cmds numactl lscpu lspci grep bc awk
cms_verify_cmds() {
    local err=false
    for cmd in "$@"; do
        if ! command -v "${cmd}" &>/dev/null; then
            cms_log_error "Required command not found: ${cmd}"
            err=true
        fi
    done
    if ${err}; then
        cms_log_error "Exiting due to missing commands."
        exit 1
    fi
}

#################################################################################################
# 6. System Topology Queries
#################################################################################################

# All of these populate global variables and print an INFO line.

CMS_NUM_SOCKETS=0
CMS_CORES_PER_SOCKET=0
CMS_THREADS_PER_CORE=0
CMS_NUMA_NODES=0
CMS_NUM_CXL_DEVICES=0
CMS_HYPERTHREADING=false

cms_get_num_sockets() {
    CMS_NUM_SOCKETS=$(lscpu 2>/dev/null | grep "Socket(s):" | awk -F: '{print $2}' | xargs || true)
    CMS_NUM_SOCKETS="${CMS_NUM_SOCKETS:-1}"
    cms_log_info "Sockets: ${CMS_NUM_SOCKETS}"
}

cms_get_cores_per_socket() {
    CMS_CORES_PER_SOCKET=$(lscpu 2>/dev/null | grep "Core(s) per socket:" | awk -F: '{print $2}' | xargs || true)
    CMS_CORES_PER_SOCKET="${CMS_CORES_PER_SOCKET:-1}"
    cms_log_info "Cores per socket: ${CMS_CORES_PER_SOCKET}"
}

cms_get_threads_per_core() {
    CMS_THREADS_PER_CORE=$(lscpu 2>/dev/null | grep "Thread(s) per core:" | awk -F: '{print $2}' | xargs || true)
    CMS_THREADS_PER_CORE="${CMS_THREADS_PER_CORE:-1}"
    cms_log_info "Threads per core: ${CMS_THREADS_PER_CORE}"
}

cms_get_numa_node_count() {
    CMS_NUMA_NODES=$(lscpu 2>/dev/null | grep "NUMA node(s):" | awk -F: '{print $2}' | xargs || true)
    if [ -z "${CMS_NUMA_NODES}" ]; then
        # Fallback: count node directories in sysfs
        if [ -d /sys/devices/system/node ]; then
            CMS_NUMA_NODES=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' -type d 2>/dev/null | wc -l || true)
        else
            CMS_NUMA_NODES=0
        fi
    fi
    # Force to integer, default 0
    CMS_NUMA_NODES=$(( ${CMS_NUMA_NODES:-0} + 0 )) 2>/dev/null || CMS_NUMA_NODES=0
    cms_log_info "NUMA nodes: ${CMS_NUMA_NODES}"
}

cms_get_cxl_device_count() {
    if command -v lspci &>/dev/null; then
        CMS_NUM_CXL_DEVICES=$(lspci 2>/dev/null | grep -ci "CXL" || true)
        CMS_NUM_CXL_DEVICES="${CMS_NUM_CXL_DEVICES:-0}"
    else
        CMS_NUM_CXL_DEVICES=0
    fi
    cms_log_info "CXL devices (PCI): ${CMS_NUM_CXL_DEVICES}"
}

cms_check_hyperthreading() {
    local smt_active
    smt_active=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "")
    if [ "${smt_active}" = "1" ]; then
        CMS_HYPERTHREADING=true
        cms_log_info "Hyperthreading: ENABLED"
    elif [ "${smt_active}" = "0" ]; then
        CMS_HYPERTHREADING=false
        cms_log_info "Hyperthreading: DISABLED"
    else
        # Fallback to checking threads per core
        cms_get_threads_per_core
        if [ "${CMS_THREADS_PER_CORE:-1}" -gt 1 ] 2>/dev/null; then
            CMS_HYPERTHREADING=true
            cms_log_info "Hyperthreading: ENABLED (via thread count)"
        else
            CMS_HYPERTHREADING=false
            cms_log_info "Hyperthreading: DISABLED (via thread count)"
        fi
    fi
}

# Populate all topology variables at once
cms_query_topology() {
    cms_get_num_sockets
    cms_get_cores_per_socket
    cms_get_threads_per_core
    cms_get_numa_node_count
    cms_get_cxl_device_count
    cms_check_hyperthreading
}

# Get the CPU list for a given NUMA node
# Usage: cms_get_cpulist_for_node 0
# Returns: sets CMS_NODE_CPULIST
CMS_NODE_CPULIST=""
cms_get_cpulist_for_node() {
    local node=$1
    CMS_NODE_CPULIST=$(cat "/sys/devices/system/node/node${node}/cpulist" 2>/dev/null || echo "")
    if [ -z "${CMS_NODE_CPULIST}" ]; then
        cms_log_error "Could not get CPU list for NUMA node ${node}"
        return 1
    fi
    cms_log_debug "NUMA node ${node} CPUs: ${CMS_NODE_CPULIST}"
}

# Get first CPU on a given NUMA node
# Usage: cms_get_first_cpu_on_node 0
# Returns: sets CMS_FIRST_CPU
CMS_FIRST_CPU=""
cms_get_first_cpu_on_node() {
    local node=$1
    CMS_FIRST_CPU=$(numactl --hardware 2>/dev/null | grep "node ${node} cpus:" | cut -f2 -d":" | awk '{print $1}' || true)
    if [ -z "${CMS_FIRST_CPU}" ]; then
        cms_log_error "Could not determine first CPU on NUMA node ${node}"
        return 1
    fi
    cms_log_debug "First CPU on NUMA node ${node}: ${CMS_FIRST_CPU}"
}

# Get memory capacity (kB) for each NUMA node
# Returns: sets associative array CMS_NUMA_MEMTOTALS[nodeN]=<kB>
declare -gA CMS_NUMA_MEMTOTALS 2>/dev/null || true
cms_get_memory_per_node() {
    for ndir in /sys/devices/system/node/node*; do
        [ -d "${ndir}" ] || continue
        local nid
        nid=$(basename "${ndir}")
        local memkb
        memkb=$(grep 'MemTotal:' "${ndir}/meminfo" 2>/dev/null | awk '{print $4}')
        if [ -n "${memkb}" ]; then
            CMS_NUMA_MEMTOTALS["${nid}"]="${memkb}"
            cms_log_info "${nid} MemTotal: ${memkb} kB"
        fi
    done
}

# Verify that a user-supplied NUMA node ID is valid
# Usage: cms_verify_numa_node 2
cms_verify_numa_node() {
    local node=$1
    local label="${2:-NUMA node}"
    if [ -z "${CMS_NUMA_NODES}" ] || [ "${CMS_NUMA_NODES}" -eq 0 ]; then
        cms_get_numa_node_count
    fi
    if [ "${node}" -ge "${CMS_NUMA_NODES}" ] 2>/dev/null || [ "${node}" -lt 0 ] 2>/dev/null; then
        cms_log_error "${label} ${node} does not exist. System has NUMA nodes 0-$(( CMS_NUMA_NODES - 1 ))."
        return 1
    fi
}

# Verify that a user-supplied socket ID is valid
# Usage: cms_verify_socket 1
cms_verify_socket() {
    local sock=$1
    if [ -z "${CMS_NUM_SOCKETS}" ] || [ "${CMS_NUM_SOCKETS}" -eq 0 ]; then
        cms_get_num_sockets
    fi
    if [ "${sock}" -ge "${CMS_NUM_SOCKETS}" ] 2>/dev/null; then
        cms_log_error "Socket ${sock} does not exist. System has sockets 0-$(( CMS_NUM_SOCKETS - 1 ))."
        return 1
    fi
}

#################################################################################################
# 7. System Info Collection
#################################################################################################

# Call the standalone collect_sysinfo.sh script.
# arg1: output directory (defaults to ./sysinfo under CMS_OUTPUT_PATH)
cms_collect_sysinfo() {
    local outdir="${1:-${CMS_OUTPUT_PATH}/sysinfo}"
    local script="${CMS_SYSINFO_SCRIPT:-/opt/cms-utils/collect_sysinfo.sh}"

    # Also look next to this library file if the default path doesn't exist
    if [ ! -x "${script}" ]; then
        local lib_dir
        lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd 2>/dev/null)"
        if [ -x "${lib_dir}/collect_sysinfo.sh" ]; then
            script="${lib_dir}/collect_sysinfo.sh"
        fi
    fi

    if [ -x "${script}" ]; then
        cms_log_info "Collecting system BOM via ${script}..."
        "${script}" "${outdir}"
    else
        cms_log_warn "System info collector not found at ${script}"
        cms_log_warn "Falling back to basic collection"
        mkdir -p "${outdir}"
        hostname > "${outdir}/hostname.txt" 2>/dev/null
        uname -a > "${outdir}/uname.txt" 2>/dev/null
        lscpu    > "${outdir}/lscpu.txt" 2>/dev/null
        free -h  > "${outdir}/free.txt" 2>/dev/null
        numactl --hardware > "${outdir}/numactl_hw.txt" 2>/dev/null
        lspci    > "${outdir}/lspci.txt" 2>/dev/null
    fi
    cms_log_info "System BOM collection complete."
}

#################################################################################################
# 8. CPU Frequency Governor
#################################################################################################

_CMS_SAVED_GOVERNOR=""

# Set all CPU cores to performance governor, saving the current setting for restore
cms_set_performance_governor() {
    _CMS_SAVED_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")
    if [ -n "${_CMS_SAVED_GOVERNOR}" ] && [ "${_CMS_SAVED_GOVERNOR}" != "performance" ]; then
        cms_log_info "Setting CPU governor to 'performance' (was '${_CMS_SAVED_GOVERNOR}')"
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || \
            cms_log_warn "Could not set CPU governor (need root?)"
    else
        cms_log_info "CPU governor already set to 'performance' (or not available)"
    fi
}

# Restore the CPU governor to what it was before cms_set_performance_governor
cms_restore_governor() {
    if [ -n "${_CMS_SAVED_GOVERNOR}" ] && [ "${_CMS_SAVED_GOVERNOR}" != "performance" ]; then
        cms_log_info "Restoring CPU governor to '${_CMS_SAVED_GOVERNOR}'"
        echo "${_CMS_SAVED_GOVERNOR}" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    fi
}

#################################################################################################
# 9. Hugepages
#################################################################################################

_CMS_SAVED_HUGEPAGES=""

# Allocate N hugepages, saving current count for restore
# Usage: cms_set_hugepages 1024
cms_set_hugepages() {
    local requested=$1
    _CMS_SAVED_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo "")
    cms_log_info "Setting nr_hugepages to ${requested} (was ${_CMS_SAVED_HUGEPAGES})"
    echo "${requested}" > /proc/sys/vm/nr_hugepages 2>/dev/null || \
        cms_log_warn "Could not set hugepages (need root?)"
}

cms_restore_hugepages() {
    if [ -n "${_CMS_SAVED_HUGEPAGES}" ]; then
        cms_log_info "Restoring nr_hugepages to ${_CMS_SAVED_HUGEPAGES}"
        echo "${_CMS_SAVED_HUGEPAGES}" > /proc/sys/vm/nr_hugepages 2>/dev/null || true
    fi
}

#################################################################################################
# 10. Page Cache
#################################################################################################

# Clear the page cache. Requires root.
cms_clear_page_cache() {
    cms_log_info "Clearing page cache..."
    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || \
        cms_log_warn "Could not clear page cache (need root?)"
}

#################################################################################################
# 11. Unit Conversion
#################################################################################################

# Convert a human-readable size string (e.g. "16G", "512M", "1024K") to bytes.
# Usage: cms_to_bytes "16G"
cms_to_bytes() {
    local input
    input=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    local last_char="${input: -1}"
    local numeric="${input:0:$(( ${#input} - 1 ))}"

    if [[ "${numeric}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        case "${last_char}" in
            K) echo "$(echo "scale=0; ${numeric} * 1024" | bc)";;
            M) echo "$(echo "scale=0; ${numeric} * 1024 * 1024" | bc)";;
            G) echo "$(echo "scale=0; ${numeric} * 1024 * 1024 * 1024" | bc)";;
            T) echo "$(echo "scale=0; ${numeric} * 1024 * 1024 * 1024 * 1024" | bc)";;
            *) # No suffix, treat as bytes
               echo "${input}";;
        esac
    elif [[ "${input}" =~ ^[0-9]+$ ]]; then
        echo "${input}"
    else
        cms_log_error "Invalid size string: $1"
        return 1
    fi
}

#################################################################################################
# 12. Results Packaging
#################################################################################################

# Create a tarball of the output directory.
# Usage: cms_package_results [output_path]
cms_package_results() {
    local path="${1:-${CMS_OUTPUT_PATH}}"
    # Resolve relative paths like "." to an absolute path for naming
    local resolved_path
    resolved_path=$(cd "${path}" 2>/dev/null && pwd) || resolved_path="${path}"
    local tarball="${resolved_path}.tar.gz"
    cms_log_info "Packaging results to ${tarball}..."
    tar czf "${tarball}" -C "$(dirname "${resolved_path}")" "$(basename "${resolved_path}")" 2>/dev/null || \
        cms_log_warn "Could not create results tarball"
    cms_log_info "Results archive: ${tarball}"
}

cms_log_debug "cms_common.sh v${CMS_COMMON_VERSION} loaded"
