#!/usr/bin/env bash

#################################################################################################
# OCP SRV CMS - System Information Collector (collect_sysinfo.sh)
#
# Collects a comprehensive hardware and software bill-of-materials (BOM) from inside
# a container. Designed to run in a privileged Docker container to maximize visibility
# into the host system. Output is organized into subdirectories by category.
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

SYSINFO_VERSION="0.1.0"
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
# Begin collection
#################################################################################################

_sysinfo_log "Starting system information collection v${SYSINFO_VERSION}"
_sysinfo_log "Output directory: ${SYSINFO_DIR}"

# ----- Collection metadata -----
{
    echo "collection_timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "collection_timestamp_local=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "sysinfo_collector_version=${SYSINFO_VERSION}"
    echo "hostname=$(hostname 2>/dev/null)"
    echo "container_id=$(cat /proc/self/cgroup 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -1)"
} > "${SYSINFO_DIR}/collection_metadata.txt"

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

#################################################################################################
# 5. PCI Devices
#################################################################################################
_sysinfo_log "Collecting PCI device information..."

_collect_cmd  pci_devices/lspci.txt                     lspci
_collect_cmd  pci_devices/lspci_verbose.txt             lspci -vvv
_collect_cmd  pci_devices/lspci_tree.txt                lspci -tv
_collect_cmd  pci_devices/lspci_numeric.txt             lspci -nn
_collect_cmd  pci_devices/lspci_kernel.txt              lspci -k

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

#################################################################################################
# 11. GPU (if present)
#################################################################################################
_sysinfo_log "Collecting GPU information (if present)..."

_collect_cmd  gpu/nvidia_smi.txt                        nvidia-smi
_collect_cmd  gpu/nvidia_smi_query.txt                  nvidia-smi -q
_collect_cmd  gpu/rocm_smi.txt                          rocm-smi
_collect_cmd  gpu/rocm_smi_all.txt                      rocm-smi --showall

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

#################################################################################################
# SUMMARY
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
# Archive
#################################################################################################
_sysinfo_log "Creating archive..."
tar czf "${SYSINFO_DIR}.tar.gz" -C "$(dirname "${SYSINFO_DIR}")" "$(basename "${SYSINFO_DIR}")" 2>/dev/null || true

_sysinfo_log "System information collection complete."
_sysinfo_log "  Summary:  ${SYSINFO_DIR}/SUMMARY.txt"
_sysinfo_log "  Full:     ${SYSINFO_DIR}/"
_sysinfo_log "  Archive:  ${SYSINFO_DIR}.tar.gz"
