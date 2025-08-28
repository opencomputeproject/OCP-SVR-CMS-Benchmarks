# run-redis-memtier
This benchmark uses the [Memtier](https://hub.docker.com/r/redislabs/memtier_benchmark) tool with the [redis-server](https://hub.docker.com/_/redis). The run-redis-memtier.sh script uses docker to orchastrate a single tenant environment.

The benchmark run, increases the size of the data from 1kb to 4Mb in powers of 2.  A "warm up" phase is run where the database gets populated using the set operation, followed by the benchmark phase which uses a get/set ratio of 1:10 and a wait-ratio of 10:1.

The script does not require root privileges to execute as docker allows us to run everything as a non-root user. However, there are optional OS tuning that does require root. 

A convenience script `generate_comparative_perf_charts.py` is provided to parse the output of the script and geneate comparasion bar charts between 2 separate runs.

# Usage - Run the benchmark

```bash
run-redis-memtier.sh: Usage
    run-redis-memtier.sh OPTIONS
 [Experiment options]
      -e dram|cxl|numainterleave|numapreferred|   : [Required] Memory environment
         kerneltpp
      -o <prefix>                                 : Prefix of the output directory: Default 'test'
 [Run options]
      -w <warm up time>                           : Number of seconds to warm the database: Default 300.
      -r <run time>                               : Number of seconds to 'run' the benchmark: Default 300
      -s <max_memory>                             : MaxMemory in GB for each Redis Server: Default 128gb
      -p allkeys-lru|allkeys-lru|allkeys-random|  : Redis MaxMemory Replacement Policy: Default volatile-lru
         volatile-lru|volatile-lfu|volatile-random
 [Machine confiuration options]
      -C <numa_node>                              : [Required] CPU NUMA Node to run the Redis Server
      -M <numa_node,..>                           : [Required] Memory NUMA Node(s) to run the Redis Server
      -S <numa_node>                              : [Required] CPU NUMA Node to run the Memtier workers
      -h                                          : Print this message
 
Example 1: Runs a single Redis container on NUMA 0 and a single Memtier container on NUMA Node1, 
  warms the database, runs the benchmark with default 128gb and volatile-lru
  and the defaule warmup time 300s, and default run time 300s.
 
    $ ./run-redis-memtier.sh -e dram -o test -i 1 -C 0 -M 0 -S 1
 
Example 2: Created the Redis and Memtier containers, runs the Redis container on NUMA Node 0, using
  CXL memory on NUMA Node 2, the Memtier container on NUMA Node 1, with replacement 
  policy allkeys-lru and maxmemory of 256gb, warm up time opf 600s and run time of 300s
 
    $ ./run-redis-memtier.sh -e cxl -o cxl -C 0 -M 2 -S 1 -p allkeys-lfu -s 256 -w 600 -r 300k
```


# Usage - Compare two results

```bash
usage: generate_comparative_perf_charts.py [-h] -l LEFT -r RIGHT [-o OUTPUT]

options:
  -h, --help            show this help message and exit
  -l LEFT, --left LEFT  directory path of the base results
  -r RIGHT, --right RIGHT
                        directory path of the experiment results
  -o OUTPUT, --output OUTPUT
                        The prefix for generating the charts

Example 1: Compare results between directories cxl_run-redis-memtier.sh.gnr1.0228-0830  and cxl_run-redis-memtier.sh.gnr1.0228-0830, and generate charts for all the metrics
    $ perf_charts.py -l dram_run-redis-memtier.sh.gnr1.0227-0036 -r cxl_run-redis-memtier.sh.gnr1.0228-0830 -o dram_cxl

    will generate the following sets of charts and excel chart:
    $ ls dram_cxl*
    dram_cxl_avg_latency.png  dram_cxl_kb_s.png      dram_cxl_ops_sec.png      dram_cxl_p95_latency.png    dram_cxl_p99_latency.png
    dram_cxl_hits_sec.png     dram_cxl_miss_sec.png  dram_cxl_p50_latency.png  dram_cxl_p99.9_latency.png
    dram_cxl.xlsx

```

## Install Instructions

### Prerequisites

The script requires the following commands and utilities to be installed
- numactl
- lscpu
- lspci
- grep
- cut
- sed
- awk
- dstat
- docker

To install these prerequsites, use:

**Fedora/CentOS/RHEL**

```bash
$ sudo dnf install numactl sed gawk util-linux pciutils dstat
```

**Ubuntu**

```bash
$ sudo apt install numactl grep sed gawk util-linux pciutils pcp-dstat
```

**Docker Engine**

To install docker for all users, follow the instructiosn on the [Docker website](https://docs.docker.com/engine/install)

### CGroup Permissions

The `run-redis-memtier.sh` script is expected to run as a non-root user. As such, the default security policy for cgroupsv2 commonly does not allow the use of `--cpus` for Podman (or Docker). This can cause containers to fail when starting with the following error:

```
Error: OCI runtime error: the requested cgroup controller `cpu` is not available
```

You must add the option for non-root users, using this procedure:

```bash
// Create the required /etc/systemd/system/user@.service.d/ directory

$ sudo mkdir -p /etc/systemd/system/user@.service.d/

// Create a delegate.conf file with the following content
$ sudo vim /etc/systemd/system/user@.service.d/delegate.conf
// Add this content
[Service]
Delegate=memory pids cpu cpuset

// Reload the systemd daemons to pick up the new change, or reboot the host
$ sudo systemctl daemon-reload

// Restart the user.slice systemd service
$ sudo systemctl restart user.slice

// Check the users permissions
$ cat "/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
cpuset cpu memory pids
```

If the above doesn't work the first time, log out of all sessions for that user and login again. Alternatively, reboot the host.

# Memtier and Redis Tuning & Configuration
Most of the common options are exposed via the command line arguments. The default environment downloads the latest redis-server and memtier-redis docker version. 

## Benchmark warm up and run time
The benchmark execution is designed to measure the performance of redis after the available memory is filled.  The time to warm the database (-w) is the key factor in filling the memory.  Increase or decrease the warmup time based on the the maxmemory (-s) made available to the run.


## OS Tuning & Configuration
Each environment and test requires different tuning. You can tune the host OS as needed. Here are some suggested things to do before running each test.

### Page Cache
We can drop the page cache by issuing a `sync` operation, then writing an appropriate number to the  `/proc/sys/vm/drop_caches` file. 

A value of one (1) will ask the kernel to drop only the page cache:

```bash
$ sync; echo 1 | sudo tee /proc/sys/vm/drop_caches > /dev/null
```

Writing two (2) frees dentries and inodes:

```bash
$ sync; echo 2 | sudo tee /proc/sys/vm/drop_caches > /dev/null
```

Finally, passing three (3) results in emptying everything — page cache, cached dentries, and inodes:

```bash
$ sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
```

### CPU Frequency Govenor 

The majority of modern processors are capable of operating in a number of different clock frequency and voltage configurations. The Linux kernel supports CPU performance scaling by means of the `CPUFreq` (CPU Frequency scaling) subsystem that consists of three layers of code: the core, scaling governors and scaling drivers. For benchmarking, we usually want maximum performance and power. By default, most Linux distributions place the system into a ‘powersave’ mode. The definition for ‘powersave’ and ‘performance’ scaling governors are:

**performance**

When attached to a policy object, this governor causes the highest frequency, within the `scaling_max_freq` policy limit, to be requested for that policy.

The request is made once at that time the governor for the policy is set to `performance` and whenever the `scaling_max_freq` or `scaling_min_freq` policy limits change after that.

**powersave**

When attached to a policy object, this governor causes the lowest frequency, within the `scaling_min_freq` policy limit, to be requested for that policy.

The request is made once at that time the governor for the policy is set to `powersave` and whenever the `scaling_max_freq` or `scaling_min_freq` policy limits change after that.

You can read more details about the  `CPUFreq`  Linux feature and configuration options in the  [Kernel Documentation](https://www.kernel.org/doc/html/latest/admin-guide/pm/cpufreq.html) .

Check the current mode:

```bash
$ sudo cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
powersave
powersave
powersave
powersave
[...snip...]
```

Switch to the ‘performance’ mode:

```bash
$ echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

Ensure the CPU scaling governor is in performance mode by checking the following; here you will see the setting from each processor (vcpu).

```bash
$ sudo cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
performance
performance
performance
performance
[...snip...]
```