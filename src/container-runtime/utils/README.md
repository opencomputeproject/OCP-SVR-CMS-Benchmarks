# OCP SRV CMS - Container Runtime Utilities

This directory contains shared utilities for all CMS benchmark containers. Every benchmark container (hardware and software) should pull from these common scripts to ensure consistent system information collection, logging, and output generation.

## Contents

| File                  | Type       | Description |
|:----------------------|:-----------|:------------|
| `Dockerfile.base`     | Dockerfile | Shared base image with all common packages. Benchmark Dockerfiles `FROM ocp-cms-base:latest`. |
| `cms_common.sh`       | Library    | Sourceable shell library providing logging, timing, NUMA/CPU topology queries, hugepage/governor management, unit conversion, and report generation. |
| `collect_sysinfo.sh`  | Script     | Standalone system BOM collector. Dumps comprehensive hardware and software inventory into a categorized directory tree. |
| `generate_report.sh`  | Script     | Post-run report generator. Produces an HTML report and results tarball from benchmark output. |

## How Benchmarks Integrate

### 1. Build the base image (one time)

```bash
cd src/container-runtime/utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### 2. Benchmark Dockerfiles inherit from the base

```dockerfile
FROM ocp-cms-base:latest

# Benchmark-specific packages
RUN apt-get update && apt-get install -y memcached && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/memcached-bench
COPY run_memcached.sh  /opt/memcached-bench/run_memcached.sh
COPY entrypoint.sh     /opt/memcached-bench/entrypoint.sh
RUN chmod +x *.sh

ENTRYPOINT ["./entrypoint.sh"]
```

If a benchmark cannot use the base image (e.g. it needs a different distro), it should instead COPY the utils scripts directly:

```dockerfile
FROM ubuntu:24.04
# ... install packages ...
COPY ../utils/collect_sysinfo.sh  /opt/cms-utils/collect_sysinfo.sh
COPY ../utils/cms_common.sh       /opt/cms-utils/cms_common.sh
COPY ../utils/generate_report.sh  /opt/cms-utils/generate_report.sh
RUN chmod +x /opt/cms-utils/*.sh
```

### 3. Benchmark run scripts source the common library

```bash
#!/usr/bin/env bash

# Source the common library
source /opt/cms-utils/cms_common.sh

# Set benchmark identity
CMS_SCRIPT_NAME="memcached-bench"
CMS_VERSION="0.1.0"

# Trap Ctrl-C
cms_trap_ctrlc

# Initialize outputs
cms_init_outputs

# Capture all stdout/stderr to a log file
cms_log_stdout_stderr

# Display start banner
cms_display_start_info "$*"

# Collect system BOM
cms_collect_sysinfo

# Query the platform topology
cms_query_topology

# ... run the benchmark ...
cms_log_info "Starting benchmark..."

# Generate report (HTML + tarball)
cms_generate_report ./results memcached ./results/results.csv

# Display end banner
cms_display_end_info

# Package results
cms_package_results
```

## System Information Collected by collect_sysinfo.sh

The collector creates the following directory structure:

```
sysinfo/
├── SUMMARY.txt                  # Human-readable one-page overview
├── collection_metadata.txt      # Timestamp, hostname, container ID
├── bios_firmware/               # dmidecode tables, DMI sysfs fields
│   ├── dmidecode_full.txt
│   ├── dmidecode_bios.txt
│   ├── dmidecode_memory.txt
│   ├── dmi_product_name.txt
│   └── ...
├── cpu/                         # lscpu, /proc/cpuinfo, frequencies, governor,
│   ├── lscpu.txt                  cache topology, vulnerabilities, microcode
│   ├── cpuinfo.txt
│   ├── cache_topology.txt
│   ├── all_cpu_frequencies.txt
│   └── ...
├── memory/                      # /proc/meminfo, free, hugepages, VM tunables,
│   ├── meminfo.txt                buddyinfo, zoneinfo, vmstat, slabinfo
│   ├── nr_hugepages.txt
│   ├── thp_enabled.txt
│   └── ...
├── numa_cxl/                    # numactl, per-node meminfo/cpulist/distance,
│   ├── numactl_hardware.txt       CXL device list, sysfs tree, distance matrix,
│   ├── cxl_list_all.txt           DIMM topology table
│   ├── memory_topology.txt
│   ├── node0/
│   │   ├── meminfo.txt
│   │   ├── cpulist.txt
│   │   └── distance.txt
│   └── ...
├── pci_devices/                 # lspci plain, verbose, tree, numeric, kernel
├── network/                     # ip addr/link/route, ethtool, ss
├── storage/                     # lsblk, df, mount, LVM, /proc/partitions
├── kernel_os/                   # uname, os-release, modules, kernel config,
│   ├── cmdline.txt                sysctl dump, key CMS tunables, interrupts,
│   ├── key_tunables.txt           security module status
│   └── ...
├── packages/                    # dpkg/rpm package lists, pip packages,
│   ├── dpkg_list.txt              shared libraries, tool versions, libc
│   ├── tool_versions.txt
│   └── ...
├── runtime/                     # Container environment, cgroup v1/v2 limits,
│   ├── environment.txt            process limits, ulimit
│   └── ...
├── gpu/                         # nvidia-smi, rocm-smi (if present)
└── power/                       # lm-sensors, thermal zones, RAPL counters, IPMI
```

## Functions Provided by cms_common.sh

### Logging
`cms_log_info`, `cms_log_warn`, `cms_log_error`, `cms_log_debug`

### Output Management
`cms_init_outputs`, `cms_log_stdout_stderr`, `cms_package_results`

### Banners
`cms_display_start_info`, `cms_display_end_info`

### Topology Queries
`cms_query_topology` (all-in-one), `cms_get_num_sockets`, `cms_get_cores_per_socket`, `cms_get_threads_per_core`, `cms_get_numa_node_count`, `cms_get_cxl_device_count`, `cms_check_hyperthreading`, `cms_get_cpulist_for_node`, `cms_get_first_cpu_on_node`, `cms_get_memory_per_node`

### Validation
`cms_verify_cmds`, `cms_verify_numa_node`, `cms_verify_socket`

### System Tuning
`cms_set_performance_governor` / `cms_restore_governor`, `cms_set_hugepages` / `cms_restore_hugepages`, `cms_clear_page_cache`

### Collection & Reporting
`cms_collect_sysinfo`, `cms_generate_report`

### Utilities
`cms_to_bytes`, `cms_trap_ctrlc`
