#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - System Information Collector (collect_sysinfo.sh)
#
# Collects a comprehensive hardware and software bill-of-materials (BOM) from inside
# a container. Designed to run in a privileged Docker container to maximize visibility
# into the host system. Output is organized into subdirectories by category.
#
# All data is collected in BOTH formats:
#   - Original .txt files (for human readability and backward compatibility)
#   - Structured .json files per category + a combined sysinfo.json
#
# This script lives in the utils/ directory and is COPY'd into every benchmark container.
# Individual benchmarks call it before their run to capture the full system state.
#
# Usage: ./collect_sysinfo.sh [output_directory]
#   output_directory: defaults to ./sysinfo
#
# The script is designed to be graceful - missing tools or inaccessible paths produce
# a "not available" note rather than errors. It never exits non-zero.
#################################################################################################

SYSINFO_VERSION="0.2.0"
SYSINFO_DIR="${1:-./sysinfo}"

mkdir -p "${SYSINFO_DIR}"/{bios_firmware,cpu,memory,numa_cxl,pci_devices,network,storage,kernel_os,packages,runtime,gpu,power}

#################################################################################################
# Collection helpers
#################################################################################################

_sysinfo_log() {
    echo "[SYSINFO] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Run a command, save stdout+stderr to a file. Skip silently if command missing or fails.
# arg1: output path relative to SYSINFO_DIR
# arg2+: command and arguments
_collect_cmd() {
    local outfile="${SYSINFO_DIR}/$1"; shift
    if command -v "$1" &>/dev/null; then
        "$@" > "${outfile}" 2>&1 || true
    else
        echo "# Command not found: $1" > "${outfile}"
    fi
}

# Copy or cat a file from the host/proc/sys filesystems.
# arg1: output path relative to SYSINFO_DIR
# arg2: source file
_collect_file() {
    local outfile="${SYSINFO_DIR}/$1"
    local src="$2"
    if [ -r "${src}" ]; then
        if [ -s "${src}" ]; then
            cat "${src}" > "${outfile}" 2>/dev/null || echo "# Unreadable: ${src}" > "${outfile}"
        else
            echo "# Empty: ${src}" > "${outfile}"
        fi
    else
        echo "# Not available: ${src}" > "${outfile}"
    fi
}

# Walk a directory tree of readable files and dump key=value style output.
# arg1: output path relative to SYSINFO_DIR
# arg2: source directory
_collect_tree() {
    local outfile="${SYSINFO_DIR}/$1"
    local srcdir="$2"
    if [ -d "${srcdir}" ]; then
        find "${srcdir}" -type f -readable 2>/dev/null | sort | while read -r f; do
            echo "=== ${f} ==="
            cat "${f}" 2>/dev/null || echo "# unreadable"
            echo ""
        done > "${outfile}"
    else
        echo "# Directory not available: ${srcdir}" > "${outfile}"
    fi
}

#################################################################################################
# JSON helpers
#
# These helpers build JSON safely in pure bash without requiring jq or python.
# Values are escaped for JSON (backslashes, quotes, control chars).
#################################################################################################

# Escape a string for safe JSON embedding
_json_escape() {
    local s="$1"
    # Escape backslashes first, then quotes, then control characters
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    # Newlines: replace with \n
    s=$(printf '%s' "$s" | awk '
        BEGIN { ORS="" }
        NR>1 { printf "\\n" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); print }
    ')
    printf '%s' "$s"
}

# Read a single-value file and return its trimmed content, or a fallback
# arg1: file path
# arg2: fallback value (default: null without quotes)
_read_val() {
    local f="$1"
    local fallback="${2:-}"
    if [ -r "$f" ] && [ -s "$f" ]; then
        local v
        v=$(head -1 "$f" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$v" ] && ! echo "$v" | grep -qE '^#\s*(Not available|Command not found|Empty|Unreadable)'; then
            printf '%s' "$v"
            return 0
        fi
    fi
    printf '%s' "$fallback"
    return 1
}

# Read a whole file and return its content, or fallback
_read_file() {
    local f="$1"
    local fallback="${2:-}"
    if [ -r "$f" ] && [ -s "$f" ]; then
        local v
        v=$(cat "$f" 2>/dev/null)
        if [ -n "$v" ] && ! echo "$v" | head -1 | grep -qE '^#\s*(Not available|Command not found|Empty|Unreadable|Directory not available)'; then
            printf '%s' "$v"
            return 0
        fi
    fi
    printf '%s' "$fallback"
    return 1
}

# Emit a JSON string field: "key": "value"
# arg1: key, arg2: value (will be escaped)
_json_str() {
    local escaped
    escaped=$(_json_escape "$2")
    printf '"%s": "%s"' "$1" "$escaped"
}

# Emit a JSON string field from a file: "key": "value_from_file"
# arg1: key, arg2: file path
_json_str_from_file() {
    local val
    val=$(_read_val "$2" "")
    if [ -n "$val" ]; then
        _json_str "$1" "$val"
    else
        printf '"%s": null' "$1"
    fi
}

# Emit a JSON field with the full contents of a file (multiline as escaped string)
# arg1: key, arg2: file path
_json_text_from_file() {
    local val
    val=$(_read_file "$2" "")
    if [ -n "$val" ]; then
        local escaped
        escaped=$(_json_escape "$val")
        printf '"%s": "%s"' "$1" "$escaped"
    else
        printf '"%s": null' "$1"
    fi
}

# Emit a JSON number field: "key": number
# arg1: key, arg2: value
_json_num() {
    if [ -n "$2" ] && [[ "$2" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        printf '"%s": %s' "$1" "$2"
    else
        printf '"%s": null' "$1"
    fi
}

# Emit a JSON number from a single-value file
_json_num_from_file() {
    local val
    val=$(_read_val "$2" "")
    _json_num "$1" "$val"
}

# Emit a JSON boolean: "key": true/false
_json_bool() {
    if [ "$2" = "true" ] || [ "$2" = "1" ]; then
        printf '"%s": true' "$1"
    else
        printf '"%s": false' "$1"
    fi
}

#################################################################################################
# Begin collection
#################################################################################################

_sysinfo_log "Starting system information collection v${SYSINFO_VERSION}"
_sysinfo_log "Output directory: ${SYSINFO_DIR}"

# ----- Collection metadata -----
_COLLECTION_TS_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
_COLLECTION_TS_LOCAL=$(date '+%Y-%m-%d %H:%M:%S %Z')
_HOSTNAME=$(hostname 2>/dev/null || echo "")
_CONTAINER_ID=$(cat /proc/self/cgroup 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -1)

{
    echo "collection_timestamp_utc=${_COLLECTION_TS_UTC}"
    echo "collection_timestamp_local=${_COLLECTION_TS_LOCAL}"
    echo "sysinfo_collector_version=${SYSINFO_VERSION}"
    echo "hostname=${_HOSTNAME}"
    echo "container_id=${_CONTAINER_ID}"
} > "${SYSINFO_DIR}/collection_metadata.txt"

# metadata JSON
{
    printf '{\n'
    printf '  %s,\n' "$(_json_str "collection_timestamp_utc" "${_COLLECTION_TS_UTC}")"
    printf '  %s,\n' "$(_json_str "collection_timestamp_local" "${_COLLECTION_TS_LOCAL}")"
    printf '  %s,\n' "$(_json_str "sysinfo_collector_version" "${SYSINFO_VERSION}")"
    printf '  %s,\n' "$(_json_str "hostname" "${_HOSTNAME}")"
    printf '  %s\n'  "$(_json_str "container_id" "${_CONTAINER_ID}")"
    printf '}\n'
} > "${SYSINFO_DIR}/collection_metadata.json"

#################################################################################################
# 1. BIOS / Firmware / Baseboard
#################################################################################################
_sysinfo_log "Collecting BIOS / firmware / baseboard..."

_collect_cmd  bios_firmware/dmidecode_full.txt         dmidecode
_collect_cmd  bios_firmware/dmidecode_bios.txt          dmidecode -t bios
_collect_cmd  bios_firmware/dmidecode_system.txt        dmidecode -t system
_collect_cmd  bios_firmware/dmidecode_baseboard.txt     dmidecode -t baseboard
_collect_cmd  bios_firmware/dmidecode_chassis.txt       dmidecode -t chassis
_collect_cmd  bios_firmware/dmidecode_processor.txt     dmidecode -t processor
_collect_cmd  bios_firmware/dmidecode_memory.txt        dmidecode -t memory
_collect_cmd  bios_firmware/dmidecode_cache.txt         dmidecode -t cache
_collect_cmd  bios_firmware/dmidecode_connector.txt     dmidecode -t connector
_collect_cmd  bios_firmware/dmidecode_slot.txt          dmidecode -t slot

_collect_file bios_firmware/dmi_product_name.txt        /sys/class/dmi/id/product_name
_collect_file bios_firmware/dmi_product_serial.txt      /sys/class/dmi/id/product_serial
_collect_file bios_firmware/dmi_product_uuid.txt        /sys/class/dmi/id/product_uuid
_collect_file bios_firmware/dmi_board_vendor.txt        /sys/class/dmi/id/board_vendor
_collect_file bios_firmware/dmi_board_name.txt          /sys/class/dmi/id/board_name
_collect_file bios_firmware/dmi_board_version.txt       /sys/class/dmi/id/board_version
_collect_file bios_firmware/dmi_bios_vendor.txt         /sys/class/dmi/id/bios_vendor
_collect_file bios_firmware/dmi_bios_version.txt        /sys/class/dmi/id/bios_version
_collect_file bios_firmware/dmi_bios_date.txt           /sys/class/dmi/id/bios_date
_collect_file bios_firmware/dmi_chassis_vendor.txt      /sys/class/dmi/id/chassis_vendor
_collect_file bios_firmware/dmi_chassis_type.txt        /sys/class/dmi/id/chassis_type
_collect_file bios_firmware/dmi_sys_vendor.txt          /sys/class/dmi/id/sys_vendor

# BIOS JSON
{
    printf '{\n'
    printf '  "dmi": {\n'
    printf '    %s,\n' "$(_json_str_from_file "product_name" "/sys/class/dmi/id/product_name")"
    printf '    %s,\n' "$(_json_str_from_file "product_serial" "/sys/class/dmi/id/product_serial")"
    printf '    %s,\n' "$(_json_str_from_file "product_uuid" "/sys/class/dmi/id/product_uuid")"
    printf '    %s,\n' "$(_json_str_from_file "board_vendor" "/sys/class/dmi/id/board_vendor")"
    printf '    %s,\n' "$(_json_str_from_file "board_name" "/sys/class/dmi/id/board_name")"
    printf '    %s,\n' "$(_json_str_from_file "board_version" "/sys/class/dmi/id/board_version")"
    printf '    %s,\n' "$(_json_str_from_file "bios_vendor" "/sys/class/dmi/id/bios_vendor")"
    printf '    %s,\n' "$(_json_str_from_file "bios_version" "/sys/class/dmi/id/bios_version")"
    printf '    %s,\n' "$(_json_str_from_file "bios_date" "/sys/class/dmi/id/bios_date")"
    printf '    %s,\n' "$(_json_str_from_file "chassis_vendor" "/sys/class/dmi/id/chassis_vendor")"
    printf '    %s,\n' "$(_json_str_from_file "chassis_type" "/sys/class/dmi/id/chassis_type")"
    printf '    %s\n'  "$(_json_str_from_file "sys_vendor" "/sys/class/dmi/id/sys_vendor")"
    printf '  },\n'
    printf '  "dmidecode": {\n'
    printf '    %s,\n' "$(_json_text_from_file "bios"      "${SYSINFO_DIR}/bios_firmware/dmidecode_bios.txt")"
    printf '    %s,\n' "$(_json_text_from_file "system"    "${SYSINFO_DIR}/bios_firmware/dmidecode_system.txt")"
    printf '    %s,\n' "$(_json_text_from_file "baseboard" "${SYSINFO_DIR}/bios_firmware/dmidecode_baseboard.txt")"
    printf '    %s,\n' "$(_json_text_from_file "chassis"   "${SYSINFO_DIR}/bios_firmware/dmidecode_chassis.txt")"
    printf '    %s,\n' "$(_json_text_from_file "processor" "${SYSINFO_DIR}/bios_firmware/dmidecode_processor.txt")"
    printf '    %s,\n' "$(_json_text_from_file "memory"    "${SYSINFO_DIR}/bios_firmware/dmidecode_memory.txt")"
    printf '    %s,\n' "$(_json_text_from_file "cache"     "${SYSINFO_DIR}/bios_firmware/dmidecode_cache.txt")"
    printf '    %s,\n' "$(_json_text_from_file "connector" "${SYSINFO_DIR}/bios_firmware/dmidecode_connector.txt")"
    printf '    %s,\n' "$(_json_text_from_file "slot"      "${SYSINFO_DIR}/bios_firmware/dmidecode_slot.txt")"
    printf '    %s\n'  "$(_json_text_from_file "full"      "${SYSINFO_DIR}/bios_firmware/dmidecode_full.txt")"
    printf '  }\n'
    printf '}\n'
} > "${SYSINFO_DIR}/bios_firmware/bios_firmware.json"

#################################################################################################
# 2. CPU
#################################################################################################
_sysinfo_log "Collecting CPU information..."

_collect_cmd  cpu/lscpu.txt                             lscpu
_collect_cmd  cpu/lscpu_extended.txt                    lscpu -e
_collect_cmd  cpu/lscpu_parse.txt                       lscpu -p
_collect_cmd  cpu/lscpu_json.txt                        lscpu -J
_collect_file cpu/cpuinfo.txt                           /proc/cpuinfo
_collect_file cpu/cpu_scaling_governor.txt              /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
_collect_file cpu/cpu_scaling_driver.txt                /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
_collect_file cpu/cpu_energy_perf_policy.txt            /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
_collect_file cpu/cpuinfo_max_freq.txt                  /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
_collect_file cpu/cpuinfo_min_freq.txt                  /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq
_collect_file cpu/scaling_cur_freq.txt                  /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
_collect_file cpu/smt_active.txt                        /sys/devices/system/cpu/smt/active
_collect_file cpu/smt_control.txt                       /sys/devices/system/cpu/smt/control
_collect_file cpu/microcode_version.txt                 /sys/devices/system/cpu/cpu0/microcode/version

# Per-CPU current frequency snapshot
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    {
        for cpudir in /sys/devices/system/cpu/cpu[0-9]*; do
            id=$(basename "${cpudir}")
            freq="${cpudir}/cpufreq/scaling_cur_freq"
            [ -r "${freq}" ] && echo "${id}: $(cat "${freq}") kHz"
        done
    } > "${SYSINFO_DIR}/cpu/all_cpu_frequencies.txt" 2>/dev/null
else
    echo "# cpufreq not available" > "${SYSINFO_DIR}/cpu/all_cpu_frequencies.txt"
fi

# Per-CPU scaling governor snapshot
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    {
        for cpudir in /sys/devices/system/cpu/cpu[0-9]*; do
            id=$(basename "${cpudir}")
            gov="${cpudir}/cpufreq/scaling_governor"
            [ -r "${gov}" ] && echo "${id}: $(cat "${gov}")"
        done
    } > "${SYSINFO_DIR}/cpu/all_cpu_governors.txt" 2>/dev/null
else
    echo "# cpufreq not available" > "${SYSINFO_DIR}/cpu/all_cpu_governors.txt"
fi

# CPU vulnerabilities
_collect_tree cpu/vulnerabilities.txt                   /sys/devices/system/cpu/vulnerabilities

# CPU cache topology
if [ -d /sys/devices/system/cpu/cpu0/cache ]; then
    {
        for idx in /sys/devices/system/cpu/cpu0/cache/index*; do
            [ -d "${idx}" ] || continue
            level=$(cat "${idx}/level" 2>/dev/null)
            type=$(cat "${idx}/type" 2>/dev/null)
            size=$(cat "${idx}/size" 2>/dev/null)
            ways=$(cat "${idx}/ways_of_associativity" 2>/dev/null)
            shared=$(cat "${idx}/shared_cpu_list" 2>/dev/null)
            echo "$(basename ${idx}): L${level} ${type} ${size} ${ways}-way shared_by=[${shared}]"
        done
    } > "${SYSINFO_DIR}/cpu/cache_topology.txt" 2>/dev/null
fi

# CPU JSON
{
    printf '{\n'

    # Parse lscpu for structured fields
    _arch=$(_read_val "" "")
    _cpus=$(_read_val "" "")
    _tpc=$(_read_val "" "")
    _cps=$(_read_val "" "")
    _sockets=$(_read_val "" "")
    _numa=$(_read_val "" "")
    _model=$(_read_val "" "")
    if [ -f "${SYSINFO_DIR}/cpu/lscpu.txt" ]; then
        _arch=$(grep -m1 "^Architecture:" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
        _cpus=$(grep -m1 "^CPU(s):" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
        _tpc=$(grep -m1 "^Thread(s) per core:" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
        _cps=$(grep -m1 "^Core(s) per socket:" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
        _sockets=$(grep -m1 "^Socket(s):" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
        _numa=$(grep -m1 "^NUMA node(s):" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
        _model=$(grep -m1 "^Model name:" "${SYSINFO_DIR}/cpu/lscpu.txt" 2>/dev/null | awk -F: '{print $2}' | xargs)
    fi

    printf '  %s,\n' "$(_json_str "architecture" "${_arch}")"
    printf '  %s,\n' "$(_json_num "cpus" "${_cpus}")"
    printf '  %s,\n' "$(_json_num "threads_per_core" "${_tpc}")"
    printf '  %s,\n' "$(_json_num "cores_per_socket" "${_cps}")"
    printf '  %s,\n' "$(_json_num "sockets" "${_sockets}")"
    printf '  %s,\n' "$(_json_num "numa_nodes" "${_numa}")"
    printf '  %s,\n' "$(_json_str "model_name" "${_model}")"
    printf '  %s,\n' "$(_json_str_from_file "scaling_governor" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")"
    printf '  %s,\n' "$(_json_str_from_file "scaling_driver" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver")"
    printf '  %s,\n' "$(_json_str_from_file "energy_perf_policy" "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference")"
    printf '  %s,\n' "$(_json_num_from_file "cpuinfo_max_freq_khz" "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq")"
    printf '  %s,\n' "$(_json_num_from_file "cpuinfo_min_freq_khz" "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq")"
    printf '  %s,\n' "$(_json_num_from_file "scaling_cur_freq_khz" "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")"

    _smt=$(_read_val "/sys/devices/system/cpu/smt/active" "")
    printf '  %s,\n' "$(_json_str "smt_active" "${_smt}")"
    printf '  %s,\n' "$(_json_str_from_file "smt_control" "/sys/devices/system/cpu/smt/control")"
    printf '  %s,\n' "$(_json_str_from_file "microcode_version" "/sys/devices/system/cpu/cpu0/microcode/version")"

    # Cache topology as array
    printf '  "cache_topology": [\n'
    _cache_first=true
    if [ -d /sys/devices/system/cpu/cpu0/cache ]; then
        for idx in /sys/devices/system/cpu/cpu0/cache/index*; do
            [ -d "${idx}" ] || continue
            ${_cache_first} || printf ',\n'
            _cache_first=false
            _cl=$(cat "${idx}/level" 2>/dev/null || echo "")
            _ct=$(cat "${idx}/type" 2>/dev/null || echo "")
            _cs=$(cat "${idx}/size" 2>/dev/null || echo "")
            _cw=$(cat "${idx}/ways_of_associativity" 2>/dev/null || echo "")
            _csh=$(cat "${idx}/shared_cpu_list" 2>/dev/null || echo "")
            printf '    { %s, %s, %s, %s, %s }' \
                "$(_json_num "level" "${_cl}")" \
                "$(_json_str "type" "${_ct}")" \
                "$(_json_str "size" "${_cs}")" \
                "$(_json_num "ways_of_associativity" "${_cw}")" \
                "$(_json_str "shared_cpu_list" "${_csh}")"
        done
    fi
    printf '\n  ],\n'

    # Per-CPU frequencies as object
    printf '  "per_cpu_frequencies_khz": {\n'
    _freq_first=true
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for cpudir in /sys/devices/system/cpu/cpu[0-9]*; do
            freq="${cpudir}/cpufreq/scaling_cur_freq"
            [ -r "${freq}" ] || continue
            ${_freq_first} || printf ',\n'
            _freq_first=false
            _cpuid=$(basename "${cpudir}")
            _fval=$(cat "${freq}" 2>/dev/null || echo "")
            printf '    %s' "$(_json_num "${_cpuid}" "${_fval}")"
        done
    fi
    printf '\n  },\n'

    # Vulnerabilities as object
    printf '  "vulnerabilities": {\n'
    _vuln_first=true
    if [ -d /sys/devices/system/cpu/vulnerabilities ]; then
        for vf in /sys/devices/system/cpu/vulnerabilities/*; do
            [ -f "${vf}" ] || continue
            ${_vuln_first} || printf ',\n'
            _vuln_first=false
            _vn=$(basename "${vf}")
            _vv=$(cat "${vf}" 2>/dev/null | head -1 || echo "")
            printf '    %s' "$(_json_str "${_vn}" "${_vv}")"
        done
    fi
    printf '\n  },\n'

    # lscpu raw and parsed outputs as text blobs
    printf '  %s,\n' "$(_json_text_from_file "lscpu_raw" "${SYSINFO_DIR}/cpu/lscpu.txt")"
    printf '  %s,\n' "$(_json_text_from_file "lscpu_extended" "${SYSINFO_DIR}/cpu/lscpu_extended.txt")"
    printf '  %s\n'  "$(_json_text_from_file "cpuinfo" "${SYSINFO_DIR}/cpu/cpuinfo.txt")"

    # If lscpu -J produced valid JSON, include it natively
    if [ -f "${SYSINFO_DIR}/cpu/lscpu_json.txt" ]; then
        _lscpu_j=$(cat "${SYSINFO_DIR}/cpu/lscpu_json.txt" 2>/dev/null)
        if echo "${_lscpu_j}" | head -1 | grep -q '{' 2>/dev/null; then
            printf ',\n  "lscpu_json": %s\n' "${_lscpu_j}"
        fi
    fi

    printf '}\n'
} > "${SYSINFO_DIR}/cpu/cpu.json"

#################################################################################################
# 3. Memory (DRAM)
#################################################################################################
_sysinfo_log "Collecting memory information..."

_collect_file memory/meminfo.txt                        /proc/meminfo
_collect_cmd  memory/free.txt                           free -h
_collect_cmd  memory/free_bytes.txt                     free -b
_collect_file memory/buddyinfo.txt                      /proc/buddyinfo
_collect_file memory/pagetypeinfo.txt                   /proc/pagetypeinfo
_collect_file memory/slabinfo.txt                       /proc/slabinfo
_collect_file memory/vmstat.txt                         /proc/vmstat
_collect_file memory/zoneinfo.txt                       /proc/zoneinfo

# Hugepages
_collect_file memory/nr_hugepages.txt                   /proc/sys/vm/nr_hugepages
_collect_file memory/nr_hugepages_mempolicy.txt         /proc/sys/vm/nr_hugepages_mempolicy
_collect_file memory/nr_overcommit_hugepages.txt        /proc/sys/vm/nr_overcommit_hugepages
_collect_file memory/thp_enabled.txt                    /sys/kernel/mm/transparent_hugepage/enabled
_collect_file memory/thp_defrag.txt                     /sys/kernel/mm/transparent_hugepage/defrag
_collect_file memory/thp_shmem_enabled.txt              /sys/kernel/mm/transparent_hugepage/shmem_enabled

# VM tunables
_collect_file memory/swappiness.txt                     /proc/sys/vm/swappiness
_collect_file memory/overcommit_memory.txt              /proc/sys/vm/overcommit_memory
_collect_file memory/overcommit_ratio.txt               /proc/sys/vm/overcommit_ratio
_collect_file memory/min_free_kbytes.txt                /proc/sys/vm/min_free_kbytes
_collect_file memory/zone_reclaim_mode.txt              /proc/sys/vm/zone_reclaim_mode
_collect_file memory/dirty_ratio.txt                    /proc/sys/vm/dirty_ratio
_collect_file memory/dirty_background_ratio.txt         /proc/sys/vm/dirty_background_ratio
_collect_file memory/watermark_boost_factor.txt         /proc/sys/vm/watermark_boost_factor
_collect_file memory/watermark_scale_factor.txt         /proc/sys/vm/watermark_scale_factor
_collect_file memory/vfs_cache_pressure.txt             /proc/sys/vm/vfs_cache_pressure
_collect_file memory/compact_memory.txt                 /proc/sys/vm/compact_memory
_collect_file memory/oom_kill_allocating_task.txt        /proc/sys/vm/oom_kill_allocating_task

# Memory JSON
{
    printf '{\n'

    # Parse /proc/meminfo for key values
    printf '  "meminfo": {\n'
    _mi_first=true
    if [ -r /proc/meminfo ]; then
        while IFS= read -r line; do
            _k=$(echo "$line" | awk -F: '{print $1}' | xargs)
            _v=$(echo "$line" | awk -F: '{print $2}' | xargs | awk '{print $1}')
            _u=$(echo "$line" | awk -F: '{print $2}' | xargs | awk '{print $2}')
            [ -z "$_k" ] && continue
            ${_mi_first} || printf ',\n'
            _mi_first=false
            if [ -n "$_u" ]; then
                printf '    "%s": { "value": %s, "unit": "%s" }' "$_k" "${_v:-0}" "$_u"
            else
                printf '    %s' "$(_json_num "$_k" "$_v")"
            fi
        done < /proc/meminfo
    fi
    printf '\n  },\n'

    # Free output (parsed)
    printf '  "free": {\n'
    if [ -f "${SYSINFO_DIR}/memory/free_bytes.txt" ]; then
        _mem_line=$(grep "^Mem:" "${SYSINFO_DIR}/memory/free_bytes.txt" 2>/dev/null)
        _swp_line=$(grep "^Swap:" "${SYSINFO_DIR}/memory/free_bytes.txt" 2>/dev/null)
        if [ -n "$_mem_line" ]; then
            _mt=$(echo "$_mem_line" | awk '{print $2}')
            _mu=$(echo "$_mem_line" | awk '{print $3}')
            _mf=$(echo "$_mem_line" | awk '{print $4}')
            _ms=$(echo "$_mem_line" | awk '{print $5}')
            _mb=$(echo "$_mem_line" | awk '{print $6}')
            _ma=$(echo "$_mem_line" | awk '{print $7}')
            printf '    "mem_total_bytes": %s,\n' "${_mt:-0}"
            printf '    "mem_used_bytes": %s,\n' "${_mu:-0}"
            printf '    "mem_free_bytes": %s,\n' "${_mf:-0}"
            printf '    "mem_shared_bytes": %s,\n' "${_ms:-0}"
            printf '    "mem_buff_cache_bytes": %s,\n' "${_mb:-0}"
            printf '    "mem_available_bytes": %s,\n' "${_ma:-0}"
        fi
        if [ -n "$_swp_line" ]; then
            _st=$(echo "$_swp_line" | awk '{print $2}')
            _su=$(echo "$_swp_line" | awk '{print $3}')
            _sf=$(echo "$_swp_line" | awk '{print $4}')
            printf '    "swap_total_bytes": %s,\n' "${_st:-0}"
            printf '    "swap_used_bytes": %s,\n' "${_su:-0}"
            printf '    "swap_free_bytes": %s\n' "${_sf:-0}"
        else
            printf '    "swap_total_bytes": 0,\n'
            printf '    "swap_used_bytes": 0,\n'
            printf '    "swap_free_bytes": 0\n'
        fi
    fi
    printf '  },\n'

    # Hugepages
    printf '  "hugepages": {\n'
    printf '    %s,\n' "$(_json_num_from_file "nr_hugepages" "/proc/sys/vm/nr_hugepages")"
    printf '    %s,\n' "$(_json_num_from_file "nr_hugepages_mempolicy" "/proc/sys/vm/nr_hugepages_mempolicy")"
    printf '    %s,\n' "$(_json_num_from_file "nr_overcommit_hugepages" "/proc/sys/vm/nr_overcommit_hugepages")"
    printf '    %s,\n' "$(_json_str_from_file "thp_enabled" "/sys/kernel/mm/transparent_hugepage/enabled")"
    printf '    %s,\n' "$(_json_str_from_file "thp_defrag" "/sys/kernel/mm/transparent_hugepage/defrag")"
    printf '    %s\n'  "$(_json_str_from_file "thp_shmem_enabled" "/sys/kernel/mm/transparent_hugepage/shmem_enabled")"
    printf '  },\n'

    # VM tunables
    printf '  "vm_tunables": {\n'
    printf '    %s,\n' "$(_json_num_from_file "swappiness" "/proc/sys/vm/swappiness")"
    printf '    %s,\n' "$(_json_num_from_file "overcommit_memory" "/proc/sys/vm/overcommit_memory")"
    printf '    %s,\n' "$(_json_num_from_file "overcommit_ratio" "/proc/sys/vm/overcommit_ratio")"
    printf '    %s,\n' "$(_json_num_from_file "min_free_kbytes" "/proc/sys/vm/min_free_kbytes")"
    printf '    %s,\n' "$(_json_num_from_file "zone_reclaim_mode" "/proc/sys/vm/zone_reclaim_mode")"
    printf '    %s,\n' "$(_json_num_from_file "dirty_ratio" "/proc/sys/vm/dirty_ratio")"
    printf '    %s,\n' "$(_json_num_from_file "dirty_background_ratio" "/proc/sys/vm/dirty_background_ratio")"
    printf '    %s,\n' "$(_json_num_from_file "watermark_boost_factor" "/proc/sys/vm/watermark_boost_factor")"
    printf '    %s,\n' "$(_json_num_from_file "watermark_scale_factor" "/proc/sys/vm/watermark_scale_factor")"
    printf '    %s,\n' "$(_json_num_from_file "vfs_cache_pressure" "/proc/sys/vm/vfs_cache_pressure")"
    printf '    %s\n'  "$(_json_num_from_file "oom_kill_allocating_task" "/proc/sys/vm/oom_kill_allocating_task")"
    printf '  },\n'

    # Raw text blobs for detailed data
    printf '  %s,\n' "$(_json_text_from_file "buddyinfo" "${SYSINFO_DIR}/memory/buddyinfo.txt")"
    printf '  %s,\n' "$(_json_text_from_file "pagetypeinfo" "${SYSINFO_DIR}/memory/pagetypeinfo.txt")"
    printf '  %s,\n' "$(_json_text_from_file "slabinfo" "${SYSINFO_DIR}/memory/slabinfo.txt")"
    printf '  %s,\n' "$(_json_text_from_file "vmstat" "${SYSINFO_DIR}/memory/vmstat.txt")"
    printf '  %s\n'  "$(_json_text_from_file "zoneinfo" "${SYSINFO_DIR}/memory/zoneinfo.txt")"

    printf '}\n'
} > "${SYSINFO_DIR}/memory/memory.json"

#################################################################################################
# 4. NUMA Topology & CXL Devices
#################################################################################################
_sysinfo_log "Collecting NUMA topology and CXL device information..."

_collect_cmd  numa_cxl/numactl_hardware.txt             numactl --hardware
_collect_cmd  numa_cxl/numactl_show.txt                 numactl --show
_collect_cmd  numa_cxl/numastat.txt                     numastat
_collect_cmd  numa_cxl/numastat_m.txt                   numastat -m
_collect_file numa_cxl/numa_balancing.txt               /proc/sys/kernel/numa_balancing
_collect_file numa_cxl/numa_demotion_enabled.txt        /sys/kernel/mm/numa/demotion_enabled

# Per-NUMA-node detail
for node_dir in /sys/devices/system/node/node[0-9]*; do
    [ -d "${node_dir}" ] || continue
    nid=$(basename "${node_dir}")
    out="${SYSINFO_DIR}/numa_cxl/${nid}"
    mkdir -p "${out}"
    cat "${node_dir}/meminfo"   > "${out}/meminfo.txt"   2>/dev/null || true
    cat "${node_dir}/cpulist"   > "${out}/cpulist.txt"   2>/dev/null || true
    cat "${node_dir}/distance"  > "${out}/distance.txt"  2>/dev/null || true
    cat "${node_dir}/numastat"  > "${out}/numastat.txt"  2>/dev/null || true
    cat "${node_dir}/vmstat"    > "${out}/vmstat.txt"     2>/dev/null || true
done

# NUMA distance matrix (human-readable)
{
    echo "NUMA Distance Matrix"
    echo "===================="
    numactl --hardware 2>/dev/null | grep -A 100 "node distances"
} > "${SYSINFO_DIR}/numa_cxl/numa_distance_matrix.txt" 2>/dev/null

# Memory topology table (mirrors src/tools/showmemtopo)
{
    dmidecode -t memory 2>/dev/null | awk '
    BEGIN {
        printf "%8s | %14s | %14s | %12s | %8s | %20s | %s\n",
               "Handle","Manufacturer","Part Number","Speed","Capacity","Bank Locator","Locator";
        printf "=========|================|================|==============|==========|======================|====================\n";
        FoundDIMM=0;
    }
    $1=="Handle"     { Handle=substr($2,1,length($2)-1); ReadNextLine=1; next }
    ReadNextLine     { FoundDIMM=($0~/Memory Device/); ReadNextLine=0; next }
    $1=="Size:"      { Size=($2!="No")? $2$3 : "empty"; next }
    FoundDIMM && $1=="Locator:"       { Locator=""; for(i=2;i<=NF;i++) Locator=Locator" "$i; next }
    FoundDIMM && $1=="Bank" && $2=="Locator:" { BankLoc=""; for(i=3;i<=NF;i++) BankLoc=BankLoc" "$i; next }
    FoundDIMM && $1=="Speed:"         { Speed=""; for(i=2;i<=NF;i++) Speed=Speed" "$i; next }
    FoundDIMM && $1=="Manufacturer:"  { Mfr=""; for(i=2;i<=NF;i++) Mfr=Mfr" "$i; next }
    FoundDIMM && $1=="Part" && $2=="Number:" { PN=""; for(i=3;i<=NF;i++) PN=PN" "$i; next }
    FoundDIMM && Size && Speed {
        printf "%8s | %14s | %14s | %12s | %8s | %20s | %s\n",
               Handle, Mfr, PN, Speed, Size, BankLoc, Locator;
        Size=""; Mfr=""; PN=""; Speed=""; BankLoc="";
    }'
} > "${SYSINFO_DIR}/numa_cxl/memory_topology.txt" 2>/dev/null

# CXL devices
_collect_cmd  numa_cxl/cxl_list.txt                     cxl list
_collect_cmd  numa_cxl/cxl_list_memdevs.txt             cxl list -M
_collect_cmd  numa_cxl/cxl_list_verbose.txt             cxl list -v
_collect_cmd  numa_cxl/cxl_list_all.txt                 cxl list -BMDPRTi

# CXL sysfs tree (full dump)
_collect_tree numa_cxl/cxl_sysfs.txt                    /sys/bus/cxl

# NUMA/CXL JSON
{
    printf '{\n'
    printf '  %s,\n' "$(_json_num_from_file "numa_balancing" "/proc/sys/kernel/numa_balancing")"
    printf '  %s,\n' "$(_json_str_from_file "numa_demotion_enabled" "/sys/kernel/mm/numa/demotion_enabled")"

    # Per-node detail
    printf '  "nodes": {\n'
    _node_first=true
    for node_dir in /sys/devices/system/node/node[0-9]*; do
        [ -d "${node_dir}" ] || continue
        ${_node_first} || printf ',\n'
        _node_first=false
        _nid=$(basename "${node_dir}")
        _cpulist=$(cat "${node_dir}/cpulist" 2>/dev/null || echo "")
        _distance=$(cat "${node_dir}/distance" 2>/dev/null || echo "")
        # Extract MemTotal from node meminfo
        _nmem=$(grep "MemTotal:" "${node_dir}/meminfo" 2>/dev/null | awk '{print $4}')
        _nfree=$(grep "MemFree:" "${node_dir}/meminfo" 2>/dev/null | awk '{print $4}')
        printf '    "%s": {\n' "$_nid"
        printf '      %s,\n' "$(_json_str "cpulist" "$_cpulist")"
        printf '      %s,\n' "$(_json_str "distance" "$_distance")"
        printf '      %s,\n' "$(_json_num "mem_total_kb" "$_nmem")"
        printf '      %s\n'  "$(_json_num "mem_free_kb" "$_nfree")"
        printf '    }'
    done
    printf '\n  },\n'

    # CXL — include raw cxl list output; if it's valid JSON, embed natively
    _cxl_raw=""
    if [ -f "${SYSINFO_DIR}/numa_cxl/cxl_list.txt" ]; then
        _cxl_raw=$(cat "${SYSINFO_DIR}/numa_cxl/cxl_list.txt" 2>/dev/null)
    fi
    if [ -n "${_cxl_raw}" ] && echo "${_cxl_raw}" | head -1 | grep -qE '^\[|^\{'; then
        printf '  "cxl_devices": %s,\n' "${_cxl_raw}"
    else
        printf '  %s,\n' "$(_json_text_from_file "cxl_devices" "${SYSINFO_DIR}/numa_cxl/cxl_list.txt")"
    fi

    # Verbose CXL
    _cxl_all=""
    if [ -f "${SYSINFO_DIR}/numa_cxl/cxl_list_all.txt" ]; then
        _cxl_all=$(cat "${SYSINFO_DIR}/numa_cxl/cxl_list_all.txt" 2>/dev/null)
    fi
    if [ -n "${_cxl_all}" ] && echo "${_cxl_all}" | head -1 | grep -qE '^\[|^\{'; then
        printf '  "cxl_devices_all": %s,\n' "${_cxl_all}"
    else
        printf '  %s,\n' "$(_json_text_from_file "cxl_devices_all" "${SYSINFO_DIR}/numa_cxl/cxl_list_all.txt")"
    fi

    # Raw text blobs
    printf '  %s,\n' "$(_json_text_from_file "numactl_hardware" "${SYSINFO_DIR}/numa_cxl/numactl_hardware.txt")"
    printf '  %s,\n' "$(_json_text_from_file "numastat" "${SYSINFO_DIR}/numa_cxl/numastat.txt")"
    printf '  %s,\n' "$(_json_text_from_file "numastat_m" "${SYSINFO_DIR}/numa_cxl/numastat_m.txt")"
    printf '  %s,\n' "$(_json_text_from_file "memory_topology" "${SYSINFO_DIR}/numa_cxl/memory_topology.txt")"
    printf '  %s\n'  "$(_json_text_from_file "cxl_sysfs" "${SYSINFO_DIR}/numa_cxl/cxl_sysfs.txt")"

    printf '}\n'
} > "${SYSINFO_DIR}/numa_cxl/numa_cxl.json"

#################################################################################################
# 5. PCI Devices
#################################################################################################
_sysinfo_log "Collecting PCI device information..."

_collect_cmd  pci_devices/lspci.txt                     lspci
_collect_cmd  pci_devices/lspci_verbose.txt             lspci -vvv
_collect_cmd  pci_devices/lspci_tree.txt                lspci -tv
_collect_cmd  pci_devices/lspci_numeric.txt             lspci -nn
_collect_cmd  pci_devices/lspci_kernel.txt              lspci -k

# PCI JSON
{
    printf '{\n'
    printf '  %s,\n' "$(_json_text_from_file "lspci" "${SYSINFO_DIR}/pci_devices/lspci.txt")"
    printf '  %s,\n' "$(_json_text_from_file "lspci_verbose" "${SYSINFO_DIR}/pci_devices/lspci_verbose.txt")"
    printf '  %s,\n' "$(_json_text_from_file "lspci_tree" "${SYSINFO_DIR}/pci_devices/lspci_tree.txt")"
    printf '  %s,\n' "$(_json_text_from_file "lspci_numeric" "${SYSINFO_DIR}/pci_devices/lspci_numeric.txt")"
    printf '  %s\n'  "$(_json_text_from_file "lspci_kernel" "${SYSINFO_DIR}/pci_devices/lspci_kernel.txt")"
    printf '}\n'
} > "${SYSINFO_DIR}/pci_devices/pci_devices.json"

#################################################################################################
# 6. Network Interfaces
#################################################################################################
_sysinfo_log "Collecting network information..."

_collect_cmd  network/ip_addr.txt                       ip addr show
_collect_cmd  network/ip_link.txt                       ip link show
_collect_cmd  network/ip_route.txt                      ip route show
_collect_cmd  network/ifconfig.txt                      ifconfig -a
_collect_cmd  network/ss_summary.txt                    ss -s
_collect_cmd  network/ss_listening.txt                  ss -tlnp
_collect_file network/hostname.txt                      /etc/hostname

# Per-NIC ethtool info (physical NICs only)
if command -v ethtool &>/dev/null; then
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        [ "${iface}" = "lo" ] && continue
        {
            echo "=== ${iface} ==="
            ethtool "${iface}" 2>/dev/null
            echo ""
            echo "--- driver ---"
            ethtool -i "${iface}" 2>/dev/null
            echo ""
        }
    done > "${SYSINFO_DIR}/network/ethtool_all.txt" 2>/dev/null
fi

# Network JSON
{
    printf '{\n'
    printf '  %s,\n' "$(_json_str_from_file "hostname" "/etc/hostname")"
    printf '  %s,\n' "$(_json_text_from_file "ip_addr" "${SYSINFO_DIR}/network/ip_addr.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ip_link" "${SYSINFO_DIR}/network/ip_link.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ip_route" "${SYSINFO_DIR}/network/ip_route.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ifconfig" "${SYSINFO_DIR}/network/ifconfig.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ss_summary" "${SYSINFO_DIR}/network/ss_summary.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ss_listening" "${SYSINFO_DIR}/network/ss_listening.txt")"
    printf '  %s\n'  "$(_json_text_from_file "ethtool_all" "${SYSINFO_DIR}/network/ethtool_all.txt")"
    printf '}\n'
} > "${SYSINFO_DIR}/network/network.json"

#################################################################################################
# 7. Storage
#################################################################################################
_sysinfo_log "Collecting storage information..."

_collect_cmd  storage/lsblk.txt                         lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL,VENDOR,SERIAL,ROTA
_collect_cmd  storage/lsblk_all.txt                     lsblk -a
_collect_cmd  storage/lsblk_json.txt                    lsblk -J
_collect_cmd  storage/df.txt                            df -hT
_collect_cmd  storage/mount.txt                         mount
_collect_cmd  storage/findmnt.txt                       findmnt
_collect_file storage/partitions.txt                    /proc/partitions
_collect_file storage/diskstats.txt                     /proc/diskstats
_collect_file storage/mounts.txt                        /proc/mounts
_collect_file storage/mdstat.txt                        /proc/mdstat
_collect_cmd  storage/vgdisplay.txt                     vgdisplay
_collect_cmd  storage/pvdisplay.txt                     pvdisplay
_collect_cmd  storage/lvdisplay.txt                     lvdisplay

# Storage JSON
{
    printf '{\n'

    # If lsblk -J produced valid JSON, embed natively
    _lsblk_j=""
    if [ -f "${SYSINFO_DIR}/storage/lsblk_json.txt" ]; then
        _lsblk_j=$(cat "${SYSINFO_DIR}/storage/lsblk_json.txt" 2>/dev/null)
    fi
    if [ -n "${_lsblk_j}" ] && echo "${_lsblk_j}" | head -1 | grep -qE '^\{'; then
        printf '  "lsblk_json": %s,\n' "${_lsblk_j}"
    fi

    printf '  %s,\n' "$(_json_text_from_file "lsblk" "${SYSINFO_DIR}/storage/lsblk.txt")"
    printf '  %s,\n' "$(_json_text_from_file "df" "${SYSINFO_DIR}/storage/df.txt")"
    printf '  %s,\n' "$(_json_text_from_file "mount" "${SYSINFO_DIR}/storage/mount.txt")"
    printf '  %s,\n' "$(_json_text_from_file "findmnt" "${SYSINFO_DIR}/storage/findmnt.txt")"
    printf '  %s,\n' "$(_json_text_from_file "partitions" "${SYSINFO_DIR}/storage/partitions.txt")"
    printf '  %s,\n' "$(_json_text_from_file "diskstats" "${SYSINFO_DIR}/storage/diskstats.txt")"
    printf '  %s,\n' "$(_json_text_from_file "mounts" "${SYSINFO_DIR}/storage/mounts.txt")"
    printf '  %s,\n' "$(_json_text_from_file "mdstat" "${SYSINFO_DIR}/storage/mdstat.txt")"
    printf '  %s,\n' "$(_json_text_from_file "vgdisplay" "${SYSINFO_DIR}/storage/vgdisplay.txt")"
    printf '  %s,\n' "$(_json_text_from_file "pvdisplay" "${SYSINFO_DIR}/storage/pvdisplay.txt")"
    printf '  %s\n'  "$(_json_text_from_file "lvdisplay" "${SYSINFO_DIR}/storage/lvdisplay.txt")"
    printf '}\n'
} > "${SYSINFO_DIR}/storage/storage.json"

#################################################################################################
# 8. Kernel / OS / Boot
#################################################################################################
_sysinfo_log "Collecting kernel and OS information..."

_collect_cmd  kernel_os/uname.txt                       uname -a
_collect_file kernel_os/os_release.txt                  /etc/os-release
_collect_file kernel_os/lsb_release.txt                 /etc/lsb-release
_collect_cmd  kernel_os/lsb_release_a.txt               lsb_release -a
_collect_file kernel_os/version.txt                     /proc/version
_collect_file kernel_os/cmdline.txt                     /proc/cmdline
_collect_file kernel_os/modules.txt                     /proc/modules
_collect_cmd  kernel_os/lsmod.txt                       lsmod
_collect_file kernel_os/uptime.txt                      /proc/uptime
_collect_cmd  kernel_os/uptime_human.txt                uptime
_collect_file kernel_os/loadavg.txt                     /proc/loadavg
_collect_file kernel_os/stat.txt                        /proc/stat
_collect_file kernel_os/interrupts.txt                  /proc/interrupts
_collect_file kernel_os/softirqs.txt                    /proc/softirqs
_collect_file kernel_os/schedstat.txt                   /proc/schedstat

# Kernel config
if [ -f /proc/config.gz ]; then
    zcat /proc/config.gz > "${SYSINFO_DIR}/kernel_os/kernel_config.txt" 2>/dev/null || true
elif ls /boot/config-"$(uname -r)" 1>/dev/null 2>&1; then
    cp "/boot/config-$(uname -r)" "${SYSINFO_DIR}/kernel_os/kernel_config.txt" 2>/dev/null || true
else
    echo "# Kernel config not available" > "${SYSINFO_DIR}/kernel_os/kernel_config.txt"
fi

# Full sysctl dump
_collect_cmd  kernel_os/sysctl_all.txt                  sysctl -a

# Curated tunables that matter for memory/CXL benchmarking
{
    echo "=== Key Kernel Tunables for CMS Benchmarking ==="
    echo ""
    for param in \
        kernel.sched_migration_cost_ns \
        kernel.sched_min_granularity_ns \
        kernel.sched_wakeup_granularity_ns \
        kernel.numa_balancing \
        kernel.numa_balancing_scan_delay_ms \
        kernel.numa_balancing_scan_period_min_ms \
        kernel.numa_balancing_scan_period_max_ms \
        kernel.numa_balancing_scan_size_mb \
        vm.swappiness \
        vm.overcommit_memory \
        vm.overcommit_ratio \
        vm.min_free_kbytes \
        vm.zone_reclaim_mode \
        vm.dirty_ratio \
        vm.dirty_background_ratio \
        vm.nr_hugepages \
        vm.nr_overcommit_hugepages \
        vm.vfs_cache_pressure \
        vm.watermark_boost_factor \
        vm.watermark_scale_factor \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.tcp_fin_timeout \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_keepalive_time \
        ; do
        val=$(sysctl -n "${param}" 2>/dev/null || echo "N/A")
        printf "%-55s = %s\n" "${param}" "${val}"
    done
} > "${SYSINFO_DIR}/kernel_os/key_tunables.txt" 2>/dev/null

# Security modules
_collect_file kernel_os/selinux_enforce.txt              /sys/fs/selinux/enforce
_collect_cmd  kernel_os/getenforce.txt                   getenforce
_collect_file kernel_os/apparmor_profiles.txt            /sys/kernel/security/apparmor/profiles

# Kernel/OS JSON
{
    printf '{\n'

    # Parse os-release for structured fields
    _os_name="" ; _os_version="" ; _os_id=""
    if [ -r /etc/os-release ]; then
        _os_name=$(grep "^NAME=" /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        _os_version=$(grep "^VERSION=" /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
        _os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    fi
    _uname_r=$(uname -r 2>/dev/null || echo "")
    _uname_a=$(uname -a 2>/dev/null || echo "")

    printf '  %s,\n' "$(_json_str "os_name" "$_os_name")"
    printf '  %s,\n' "$(_json_str "os_version" "$_os_version")"
    printf '  %s,\n' "$(_json_str "os_id" "$_os_id")"
    printf '  %s,\n' "$(_json_str "kernel_release" "$_uname_r")"
    printf '  %s,\n' "$(_json_str "uname" "$_uname_a")"
    printf '  %s,\n' "$(_json_str_from_file "cmdline" "/proc/cmdline")"
    printf '  %s,\n' "$(_json_str_from_file "version" "/proc/version")"

    # Uptime
    _uptime_s=$(_read_val "/proc/uptime" "")
    _uptime_s=$(echo "$_uptime_s" | awk '{print $1}')
    printf '  %s,\n' "$(_json_num "uptime_seconds" "$_uptime_s")"
    printf '  %s,\n' "$(_json_str_from_file "loadavg" "/proc/loadavg")"

    # Key tunables as structured object
    printf '  "key_tunables": {\n'
    _kt_first=true
    for param in \
        kernel.sched_migration_cost_ns \
        kernel.numa_balancing \
        vm.swappiness \
        vm.overcommit_memory \
        vm.overcommit_ratio \
        vm.min_free_kbytes \
        vm.zone_reclaim_mode \
        vm.dirty_ratio \
        vm.dirty_background_ratio \
        vm.nr_hugepages \
        vm.nr_overcommit_hugepages \
        vm.vfs_cache_pressure \
        vm.watermark_boost_factor \
        vm.watermark_scale_factor \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.ipv4.tcp_fin_timeout \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_keepalive_time \
        ; do
        ${_kt_first} || printf ',\n'
        _kt_first=false
        _val=$(sysctl -n "${param}" 2>/dev/null || echo "")
        printf '    %s' "$(_json_str "${param}" "${_val}")"
    done
    printf '\n  },\n'

    # Raw text blobs
    printf '  %s,\n' "$(_json_text_from_file "lsmod" "${SYSINFO_DIR}/kernel_os/lsmod.txt")"
    printf '  %s,\n' "$(_json_text_from_file "interrupts" "${SYSINFO_DIR}/kernel_os/interrupts.txt")"
    printf '  %s\n'  "$(_json_text_from_file "modules" "${SYSINFO_DIR}/kernel_os/modules.txt")"

    printf '}\n'
} > "${SYSINFO_DIR}/kernel_os/kernel_os.json"

#################################################################################################
# 9. Installed Packages / Software BOM
#################################################################################################
_sysinfo_log "Collecting installed packages and software BOM..."

# Debian/Ubuntu
if command -v dpkg &>/dev/null; then
    dpkg -l                  > "${SYSINFO_DIR}/packages/dpkg_list.txt"       2>/dev/null
    dpkg --get-selections    > "${SYSINFO_DIR}/packages/dpkg_selections.txt" 2>/dev/null
    apt list --installed     > "${SYSINFO_DIR}/packages/apt_installed.txt"   2>/dev/null
fi

# RHEL/Fedora/CentOS
if command -v rpm &>/dev/null; then
    rpm -qa --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort \
        > "${SYSINFO_DIR}/packages/rpm_list.txt" 2>/dev/null
fi
if command -v dnf &>/dev/null; then
    dnf list installed > "${SYSINFO_DIR}/packages/dnf_installed.txt" 2>/dev/null
elif command -v yum &>/dev/null; then
    yum list installed > "${SYSINFO_DIR}/packages/yum_installed.txt" 2>/dev/null
fi

# Python
if command -v pip3 &>/dev/null; then
    pip3 list --format=freeze > "${SYSINFO_DIR}/packages/pip3_list.txt" 2>/dev/null
elif command -v pip &>/dev/null; then
    pip list --format=freeze  > "${SYSINFO_DIR}/packages/pip_list.txt"  2>/dev/null
fi

# Shared libraries
_collect_cmd  packages/ldconfig.txt                     ldconfig -p

# C library
_collect_cmd  packages/libc_version.txt                 ldd --version

# Key tool versions
{
    echo "=== Key Tool Versions ==="
    echo ""
    for cmd in gcc g++ make cmake python3 python pip3 numactl memcached memaslap redis-server; do
        if command -v "${cmd}" &>/dev/null; then
            ver=$("${cmd}" --version 2>&1 | head -1)
            printf "%-25s : %s\n" "${cmd}" "${ver}"
        else
            printf "%-25s : NOT INSTALLED\n" "${cmd}"
        fi
    done
    # Special-case tools that use non-standard version flags
    if command -v lscpu &>/dev/null; then
        printf "%-25s : %s\n" "util-linux (lscpu)" "$(lscpu -V 2>&1 | head -1)"
    fi
    if command -v cxl &>/dev/null; then
        printf "%-25s : %s\n" "cxl-cli" "$(cxl --version 2>&1 | head -1)"
    fi
    if command -v mlc &>/dev/null; then
        printf "%-25s : %s\n" "mlc" "$(mlc --version 2>&1 | head -1)"
    fi
} > "${SYSINFO_DIR}/packages/tool_versions.txt" 2>/dev/null

# Packages JSON
{
    printf '{\n'

    # Tool versions as structured object
    printf '  "tool_versions": {\n'
    _tv_first=true
    for cmd in gcc g++ make cmake python3 python pip3 numactl memcached memaslap redis-server; do
        ${_tv_first} || printf ',\n'
        _tv_first=false
        if command -v "${cmd}" &>/dev/null; then
            _tv=$("${cmd}" --version 2>&1 | head -1)
            printf '    %s' "$(_json_str "${cmd}" "${_tv}")"
        else
            printf '    "%s": null' "${cmd}"
        fi
    done
    if command -v lscpu &>/dev/null; then
        printf ',\n    %s' "$(_json_str "util-linux" "$(lscpu -V 2>&1 | head -1)")"
    fi
    if command -v cxl &>/dev/null; then
        printf ',\n    %s' "$(_json_str "cxl-cli" "$(cxl --version 2>&1 | head -1)")"
    fi
    if command -v mlc &>/dev/null; then
        printf ',\n    %s' "$(_json_str "mlc" "$(mlc --version 2>&1 | head -1)")"
    fi
    printf '\n  },\n'

    # Package manager (detect which one is present)
    _pkg_mgr="unknown"
    if command -v dpkg &>/dev/null; then _pkg_mgr="dpkg/apt"
    elif command -v rpm &>/dev/null; then _pkg_mgr="rpm"
    fi
    printf '  %s,\n' "$(_json_str "package_manager" "$_pkg_mgr")"

    # C library
    printf '  %s,\n' "$(_json_text_from_file "libc_version" "${SYSINFO_DIR}/packages/libc_version.txt")"

    # Raw package lists as text blobs (these can be very large)
    printf '  %s,\n' "$(_json_text_from_file "dpkg_list" "${SYSINFO_DIR}/packages/dpkg_list.txt")"
    printf '  %s,\n' "$(_json_text_from_file "rpm_list" "${SYSINFO_DIR}/packages/rpm_list.txt")"
    printf '  %s\n'  "$(_json_text_from_file "pip3_list" "${SYSINFO_DIR}/packages/pip3_list.txt")"

    printf '}\n'
} > "${SYSINFO_DIR}/packages/packages.json"

#################################################################################################
# 10. Container Runtime Environment
#################################################################################################
_sysinfo_log "Collecting container runtime environment..."

# Environment variables (strip anything that looks like a secret)
env | grep -viE 'password|secret|token|key|credential|auth' | sort \
    > "${SYSINFO_DIR}/runtime/environment.txt" 2>/dev/null

# Cgroup v2
_collect_file runtime/cgroup.txt                        /proc/self/cgroup
_collect_file runtime/cgroup_controllers.txt            /sys/fs/cgroup/cgroup.controllers
_collect_file runtime/cgroup_memory_max.txt             /sys/fs/cgroup/memory.max
_collect_file runtime/cgroup_memory_current.txt         /sys/fs/cgroup/memory.current
_collect_file runtime/cgroup_memory_swap_max.txt        /sys/fs/cgroup/memory.swap.max
_collect_file runtime/cgroup_cpu_max.txt                /sys/fs/cgroup/cpu.max
_collect_file runtime/cgroup_cpuset_cpus.txt            /sys/fs/cgroup/cpuset.cpus.effective
_collect_file runtime/cgroup_cpuset_mems.txt            /sys/fs/cgroup/cpuset.mems.effective

# Cgroup v1 (older kernels / runtimes)
if [ -d /sys/fs/cgroup/memory ]; then
    _collect_file runtime/cgv1_memory_limit.txt         /sys/fs/cgroup/memory/memory.limit_in_bytes
    _collect_file runtime/cgv1_memory_usage.txt         /sys/fs/cgroup/memory/memory.usage_in_bytes
    _collect_file runtime/cgv1_memsw_limit.txt          /sys/fs/cgroup/memory/memory.memsw.limit_in_bytes
fi
if [ -d /sys/fs/cgroup/cpuset ]; then
    _collect_file runtime/cgv1_cpuset_cpus.txt          /sys/fs/cgroup/cpuset/cpuset.cpus
    _collect_file runtime/cgv1_cpuset_mems.txt          /sys/fs/cgroup/cpuset/cpuset.mems
fi

# Process limits
_collect_file runtime/proc_limits.txt                   /proc/self/limits
_collect_file runtime/proc_status.txt                   /proc/self/status
_collect_cmd  runtime/ulimit.txt                        bash -c "ulimit -a"

# Runtime JSON
{
    printf '{\n'

    # Environment as object (key=value parsed)
    printf '  "environment": {\n'
    _env_first=true
    env | grep -viE 'password|secret|token|key|credential|auth' | sort | while IFS='=' read -r ek ev; do
        [ -z "$ek" ] && continue
        ${_env_first} || printf ',\n'
        _env_first=false
        printf '    %s' "$(_json_str "$ek" "$ev")"
    done
    printf '\n  },\n'

    # Cgroup v2
    printf '  "cgroup_v2": {\n'
    printf '    %s,\n' "$(_json_str_from_file "controllers" "/sys/fs/cgroup/cgroup.controllers")"
    printf '    %s,\n' "$(_json_str_from_file "memory_max" "/sys/fs/cgroup/memory.max")"
    printf '    %s,\n' "$(_json_str_from_file "memory_current" "/sys/fs/cgroup/memory.current")"
    printf '    %s,\n' "$(_json_str_from_file "memory_swap_max" "/sys/fs/cgroup/memory.swap.max")"
    printf '    %s,\n' "$(_json_str_from_file "cpu_max" "/sys/fs/cgroup/cpu.max")"
    printf '    %s,\n' "$(_json_str_from_file "cpuset_cpus" "/sys/fs/cgroup/cpuset.cpus.effective")"
    printf '    %s\n'  "$(_json_str_from_file "cpuset_mems" "/sys/fs/cgroup/cpuset.mems.effective")"
    printf '  },\n'

    # Cgroup v1
    printf '  "cgroup_v1": {\n'
    printf '    %s,\n' "$(_json_str_from_file "memory_limit" "/sys/fs/cgroup/memory/memory.limit_in_bytes")"
    printf '    %s,\n' "$(_json_str_from_file "memory_usage" "/sys/fs/cgroup/memory/memory.usage_in_bytes")"
    printf '    %s,\n' "$(_json_str_from_file "memsw_limit" "/sys/fs/cgroup/memory/memory.memsw.limit_in_bytes")"
    printf '    %s,\n' "$(_json_str_from_file "cpuset_cpus" "/sys/fs/cgroup/cpuset/cpuset.cpus")"
    printf '    %s\n'  "$(_json_str_from_file "cpuset_mems" "/sys/fs/cgroup/cpuset/cpuset.mems")"
    printf '  },\n'

    # Process info
    printf '  %s,\n' "$(_json_text_from_file "proc_limits" "${SYSINFO_DIR}/runtime/proc_limits.txt")"
    printf '  %s,\n' "$(_json_text_from_file "proc_status" "${SYSINFO_DIR}/runtime/proc_status.txt")"
    printf '  %s\n'  "$(_json_text_from_file "ulimit" "${SYSINFO_DIR}/runtime/ulimit.txt")"

    printf '}\n'
} > "${SYSINFO_DIR}/runtime/runtime.json"

#################################################################################################
# 11. GPU (if present)
#################################################################################################
_sysinfo_log "Collecting GPU information (if present)..."

_collect_cmd  gpu/nvidia_smi.txt                        nvidia-smi
_collect_cmd  gpu/nvidia_smi_query.txt                  nvidia-smi -q
_collect_cmd  gpu/rocm_smi.txt                          rocm-smi
_collect_cmd  gpu/rocm_smi_all.txt                      rocm-smi --showall

# GPU JSON
{
    printf '{\n'
    # Detect GPU presence
    _has_nvidia=false ; _has_amd=false
    command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null && _has_nvidia=true
    command -v rocm-smi &>/dev/null && rocm-smi &>/dev/null && _has_amd=true
    printf '  %s,\n' "$(_json_bool "nvidia_present" "$_has_nvidia")"
    printf '  %s,\n' "$(_json_bool "amd_present" "$_has_amd")"
    printf '  %s,\n' "$(_json_text_from_file "nvidia_smi" "${SYSINFO_DIR}/gpu/nvidia_smi.txt")"
    printf '  %s,\n' "$(_json_text_from_file "nvidia_smi_query" "${SYSINFO_DIR}/gpu/nvidia_smi_query.txt")"
    printf '  %s,\n' "$(_json_text_from_file "rocm_smi" "${SYSINFO_DIR}/gpu/rocm_smi.txt")"
    printf '  %s\n'  "$(_json_text_from_file "rocm_smi_all" "${SYSINFO_DIR}/gpu/rocm_smi_all.txt")"
    printf '}\n'
} > "${SYSINFO_DIR}/gpu/gpu.json"

#################################################################################################
# 12. Power / Thermal / Sensors
#################################################################################################
_sysinfo_log "Collecting power and thermal information..."

_collect_cmd  power/sensors.txt                         sensors
_collect_cmd  power/ipmitool_sdr.txt                    ipmitool sdr
_collect_cmd  power/ipmitool_fru.txt                    ipmitool fru

# Thermal zones
if [ -d /sys/class/thermal ]; then
    {
        for tz in /sys/class/thermal/thermal_zone*; do
            [ -d "${tz}" ] || continue
            name=$(basename "${tz}")
            type=$(cat "${tz}/type" 2>/dev/null || echo "unknown")
            temp=$(cat "${tz}/temp" 2>/dev/null || echo "N/A")
            echo "${name}: type=${type}  temp=${temp}"
        done
    } > "${SYSINFO_DIR}/power/thermal_zones.txt" 2>/dev/null
fi

# Intel RAPL energy counters
if [ -d /sys/class/powercap ]; then
    {
        find /sys/class/powercap -type f \( -name "name" -o -name "energy_uj" -o -name "max_energy_range_uj" \) \
            2>/dev/null | sort | while read -r f; do
            echo "=== ${f} ==="
            cat "${f}" 2>/dev/null
            echo ""
        done
    } > "${SYSINFO_DIR}/power/rapl_energy.txt" 2>/dev/null
fi

# Power JSON
{
    printf '{\n'
    printf '  %s,\n' "$(_json_text_from_file "sensors" "${SYSINFO_DIR}/power/sensors.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ipmitool_sdr" "${SYSINFO_DIR}/power/ipmitool_sdr.txt")"
    printf '  %s,\n' "$(_json_text_from_file "ipmitool_fru" "${SYSINFO_DIR}/power/ipmitool_fru.txt")"

    # Thermal zones as array
    printf '  "thermal_zones": [\n'
    _tz_first=true
    if [ -d /sys/class/thermal ]; then
        for tz in /sys/class/thermal/thermal_zone*; do
            [ -d "${tz}" ] || continue
            ${_tz_first} || printf ',\n'
            _tz_first=false
            _tzn=$(basename "${tz}")
            _tzt=$(cat "${tz}/type" 2>/dev/null || echo "unknown")
            _tztemp=$(cat "${tz}/temp" 2>/dev/null || echo "")
            printf '    { %s, %s, %s }' \
                "$(_json_str "name" "$_tzn")" \
                "$(_json_str "type" "$_tzt")" \
                "$(_json_num "temp_millicelsius" "$_tztemp")"
        done
    fi
    printf '\n  ],\n'

    printf '  %s\n' "$(_json_text_from_file "rapl_energy" "${SYSINFO_DIR}/power/rapl_energy.txt")"
    printf '}\n'
} > "${SYSINFO_DIR}/power/power.json"

#################################################################################################
# SUMMARY (text — kept for backward compatibility)
#################################################################################################
_sysinfo_log "Generating summary..."

{
    echo "============================================================"
    echo " OCP SRV CMS - System Information Summary"
    echo " Collected: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo " Collector Version: ${SYSINFO_VERSION}"
    echo "============================================================"
    echo ""

    echo "--- Platform ---"
    printf "  Vendor:   %s\n" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo 'N/A')"
    printf "  Product:  %s\n" "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo 'N/A')"
    printf "  Board:    %s %s\n" "$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo 'N/A')" \
                                  "$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo '')"
    printf "  Chassis:  %s\n" "$(cat /sys/class/dmi/id/chassis_vendor 2>/dev/null || echo 'N/A')"
    echo ""

    echo "--- BIOS / Firmware ---"
    printf "  Vendor:   %s\n" "$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo 'N/A')"
    printf "  Version:  %s\n" "$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo 'N/A')"
    printf "  Date:     %s\n" "$(cat /sys/class/dmi/id/bios_date 2>/dev/null || echo 'N/A')"
    echo ""

    echo "--- CPU ---"
    lscpu 2>/dev/null | grep -E "^Model name|^Socket|^Core|^Thread|^CPU\(s\)|^NUMA|^CPU.*MHz|^Vendor|^Architecture|^Byte Order" | sed 's/^/  /'
    echo ""

    echo "--- Memory ---"
    free -h 2>/dev/null | sed 's/^/  /'
    echo ""

    echo "--- NUMA Topology ---"
    numactl --hardware 2>/dev/null | sed 's/^/  /'
    echo ""

    echo "--- CXL Devices ---"
    if command -v cxl &>/dev/null; then
        cxl_out=$(cxl list 2>/dev/null)
        if [ -n "${cxl_out}" ] && [ "${cxl_out}" != "[]" ]; then
            echo "${cxl_out}" | sed 's/^/  /'
        else
            echo "  No CXL devices found"
        fi
    else
        echo "  cxl-cli not available"
    fi
    echo ""

    echo "--- Kernel ---"
    printf "  %s\n" "$(uname -a 2>/dev/null)"
    echo ""

    echo "--- OS ---"
    grep -E "^NAME=|^VERSION=|^ID=" /etc/os-release 2>/dev/null | sed 's/^/  /'
    echo ""

    echo "--- Container ---"
    printf "  Hostname:  %s\n" "$(hostname 2>/dev/null)"
    printf "  PID 1:     %s\n" "$(cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')"
    echo ""

    echo "--- PCI (CXL / Memory-related) ---"
    lspci 2>/dev/null | grep -iE "CXL|memory controller|host bridge|system peripheral" | sed 's/^/  /' || echo "  None found"
    echo ""

    echo "--- DIMM Summary ---"
    dmidecode -t memory 2>/dev/null | grep -cE "Size:.*[0-9]+ [MG]B" | xargs -I{} echo "  Populated DIMMs: {}"
    dmidecode -t memory 2>/dev/null | grep -E "Size:.*[0-9]+ [MG]B" | awk '{sum+=$2} END{printf "  Total Capacity:  %d GB\n", sum/1024}' 2>/dev/null
    echo ""

} > "${SYSINFO_DIR}/SUMMARY.txt" 2>/dev/null

#################################################################################################
# Combined sysinfo.json — references all per-category JSON files into one structure
#################################################################################################
_sysinfo_log "Generating combined sysinfo.json..."

{
    printf '{\n'
    printf '  "sysinfo_version": "%s",\n' "${SYSINFO_VERSION}"
    printf '  "collection_timestamp_utc": "%s",\n' "${_COLLECTION_TS_UTC}"
    printf '  "hostname": "%s",\n' "${_HOSTNAME}"

    # Inline each category JSON (strip outer braces)
    for category in bios_firmware cpu memory numa_cxl pci_devices network storage kernel_os packages runtime gpu power; do
        json_file="${SYSINFO_DIR}/${category}/${category}.json"
        if [ -f "${json_file}" ]; then
            # Read the file, strip first '{' and last '}'
            _cat_body=$(sed '1s/^{//; $s/}$//' "${json_file}" 2>/dev/null)
            printf '  "%s": {%s},\n' "${category}" "${_cat_body}"
        else
            printf '  "%s": null,\n' "${category}"
        fi
    done | sed '$ s/,$//'

    printf '}\n'
} > "${SYSINFO_DIR}/sysinfo.json"

#################################################################################################
# Archive
#################################################################################################
_sysinfo_log "Creating archive..."
tar czf "${SYSINFO_DIR}.tar.gz" -C "$(dirname "${SYSINFO_DIR}")" "$(basename "${SYSINFO_DIR}")" 2>/dev/null || true

_sysinfo_log "System information collection complete."
_sysinfo_log "  Summary:  ${SYSINFO_DIR}/SUMMARY.txt"
_sysinfo_log "  JSON:     ${SYSINFO_DIR}/sysinfo.json"
_sysinfo_log "  Full:     ${SYSINFO_DIR}/"
_sysinfo_log "  Archive:  ${SYSINFO_DIR}.tar.gz"
