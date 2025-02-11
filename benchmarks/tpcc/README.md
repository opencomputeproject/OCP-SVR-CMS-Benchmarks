# sysbench-tpcc
This benchmark uses the [Sysbench](https://github.com/akopytov/sysbench/) tool with the [Percona TPCC LUA scripts](https://github.com/Percona-Lab/sysbench-tpcc). The sysbench-tpcc.sh script uses Podman to orchastrate a single or multi tennant cloud-like environment.

The script does not require root priviledges to execute as Podman allows us to run everything as a non-root user. However, there are optional OS tuning that does require root. 

# Usage

```bash
sysbench-tpcc.sh: Usage
    sysbench-tpcc.sh OPTIONS
 [Experiment options]
      -e dram|cxl|numainterleave|numapreferred|   : [Required] Memory environment
         kerneltpp
      -i <number_of_instances>                    : The number of container intances to execute: Default 1
      -o <prefix>                                 : [Required] prefix of the output files: Default 'test'
      -s <scale>                                  : Number of warehouses (scale): Default 10
      -t <number_of_tables>                       : The number of tables per warehouse: Default 10
      -T <run time>                               : Number of seconds to 'run' the benchmark. Default 300
      -W <worker threads>                         : Maximum number of Sysbench worker threads. Default 1
 [Run options]
      -c                                          : Cleanup. Completely remove all containers and the MySQL database
      -p                                          : Prepare the database
      -w                                          : Warm the database. Default False.
      -r                                          : Run the Sysbench workload
 [Machine confiuration options]
      -C <numa_node>                              : [Required] CPU NUMA Node to run the MySQLServer
      -D <server_cpus_for_each_instance>          : [Optional] Number of vCPUs for each server [Default 4]
      -E <server_memory_in_GB_for_each_instance>  : [Optional] Memory in GB for each server [Default 16g]
      -M <numa_node,..>                           : [Required] Memory NUMA Node to run the MySQLServer
      -U <client_cpus_for_each_instance>          : [Optional] Number of vCPUs for each client [Default 4]
      -V <client_memory_in_GB_for_each_instance>  : [Optional] Memory in GB for each client [Default 1g]
      -X <size_of_innodb_pool_in_GB>              : [Optional] Memory in GB for the mysql database [Default 10G]
      -S <numa_node>                              : [Required] CPU NUMA Node to run the Sysbench workers
      -h                                          : Print this message

Example 1: Runs a single MySQL server on NUMA 0 and a single SysBench instance on NUMA Node1,
  prepares the database, runs the benchmark from 1..1000 threads in powers of two,
  and removes the database and containers when complete.
  The server and client CPU, Memory sizes are default.

    $ ./sysbench-tpcc.sh -e dram -o test -i 1 -t 10 -W 1000  -C 0 -M 0 -S 1 -p -w -r -c

Example 2: Created the MySQL and Sysbench containers, runs the MySQL container on NUMA Node 0, the
  Sysbench container on NUMA Node 1, then prepares the database and exits. The containers are left running.
  The server and client CPU, Memory sizes are default.

    $ ./sysbench-tpcc.sh -e dram -o test -C 0 -M 0 -S 1 -p

Example 3: Created the MySQL and Sysbench containers, runs the MySQL container on NUMA Node 0, the
  Sysbench container on NUMA Node 1, then prepares the database and exits. The containers are left running.
  52 cores on socket 0 and 512GB on socket 0 are used to run the MySQL container.
  26 cores on socket 1 and 48GB on socket 1 are used to nun the sysbench client container.

    $ ./sysbench-tpcc.sh -e dram -o test -C 0 -M 0 -S 1 -p -D 52 -E 512 -U 26 -X 48
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
- podman

To install these prerequsites, use:

**Fedora/CentOS/RHEL**

```bash
$ sudo dnf install numactl sed gawk podman util-linux pciutils
```

**Ubuntu**

```bash
$ sudo apt install numactl grep sed gawk podman util-linux pciutils
```

### MySQL Data Directory

The script expects the MySQL data will be hosted on a file system on the host and a Podman container will allow the container to mount the data directory to perform read/write operations. Each container will have its own data directory within the filesystem. For example, if `MYSQL_DATA_DIR=/data`, the first MySQL container will create and mount `/data/mysql1`. It is important that the data directory on the host is writable by the container. The easiest method is to open permissions using:

```bash
$ sudo chmod 777 /data
```

If you prefer to host the data elsewhere, modify the `sysbench-tpcc.sh` script and change the `MYSQL_DATA_DIR` variable.

### CGroup Permissions

The `sysbench-tpcc.sh` script is expected to run as a non-root user. This is why Podman is used to manage the containers. As such, the default security policy for cgroupsv2 commonly does not allow the use of `--cpus` for Podman (or Docker). This can cause containers to fail when starting with the following error:

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

### Podman Errors

If you see the following error
```
Error validating CNI config file /home/<username>/.config/cni/net.d/mysqlsysbench.conflist: [plugin bridge does not support config version \"1.0.0\" plugin portmap does not support config version \"1.0.0\" plugin firewall does not support config version \"1.0.0\" plugin tuning does not support config version \"1.0.0\"]
```

You must fix the CNI config files via the following method

```
bash
$ podman network ls
NETWORK ID    NAME           VERSION     PLUGINS
2f259bab93aa  podman         0.4.0       bridge,portmap,firewall,tuning
0c75ec5d56ea  mysqlsysbench  1.0.0       bridge,portmap,firewall,tuning,dnsname

$ vi ~/.config/cnd/net.d/mysqlsysbench.conflist
// Change the line "cniVersion": "1.0.0" to
"cniVersion":  "0.4.0"
```


#

## Sysbench Tuning & Configuration
Most of the common options are exposed via the command line arguments. The default environment downloads and compiles the latest sysbench version using a multi-stage `Dockerfile`. The release version of sysbench does not have the `--warmup` option, so we muct compile it to ascertain this feature. Each sysbench container uses 4 vCPUs and 1GiB of memory. To change this, edit the sysbench-tpcc.sh script and modify the `CLIENT_CPU_LIMIT` and `CLIENT_MEMORY_LIMIT` variables. 

Sysbench and the `sysbench-tpcc.sh` script have many more options that can be modified inside the script itself. Edit the `sysbench-tpcc.sh` script and change the parameters shown in the top of the script inside the "Variables" section.

```bash
# ==== Podman Variables ====

# Podman network name
NETWORK_NAME=mysqlsysbench

# Container CPU and memory limits for the MySQL server and the Sysbench client
# Note: The MySQL (server) values should be configured for the size of the test database. The OOM killer will stop the database if too few resources are assigned.
CLIENT_CPU_LIMIT=4  								# Number of vCPUs to give to the Sysbench container
CLIENT_MEMORY_LIMIT=1g  							# Amount of memory (GiB) to give to the Sysbench container
SERVER_CPU_LIMIT=4  								# Number of vCPUs to give to the MySQL container
SERVER_MEMORY_LIMIT=16g  							# Amount of memory (GiB) to give to the MySQL container

# === MySQL Variables ===
MYSQL_ROOT_PASSWORD=my-secret-pw  					# Root Users Password
MYSQL_START_PORT=3333  								# Host Port number for the first instance. Additional instances will increment by 1 for each instance 3306..3307..3308..
MYSQL_DATA_DIR=/data 								# Base directory for the MySQL Data Directory on the host
MYSQL_CONF=${SCRIPT_DIR}/my.cnf.d/my.cnf  			# Location of the my.cnf file the MySQL server will use
MySQLDockerImgTag="docker.io/library/mysql:latest"  # MySQL Version. Get the Docker Tag ID from https://hub.docker.com/_/mysql

# === Sysbench Variables ===

# Sysbench username and password
SYSBENCH_USER="sbuser"
SYSBENCH_USER_PASSWORD="sbuser-pwd"
SCALE=1  									# Default number of warehouses (scale value)
TABLES=10  									# Default number of tables per warehouse. Use -t to override.
SYSBENCH_CONTAINER_IMG_NAME="sysbenchmysql" # Sysbench container image name
SysbenchDBName="sbtest"  					# Name of the MySQL Database to create and run Sysbench against
```

## MySQL Tuning & Configuration
When the MySQL container starts, it uses the configuration options defined in `my.cnf.d/my.cnf`. You are free to modify this file to add or remove entries as needed. All MySQL containers use the same configuration file.

The default configuration creates a 10GB database running on 4 vCPUs with 16GB RAM. If you change the database size, by altering the SCALE or number of TABLES, you will need to calculate the new CPU and Memory requirements, then modify the SERVER_CPU_LIMIT and SERVER_MEMORY_LIMIT variables inside the script to avoid the Kernel OOM killer stopping the MySQL database instance. 

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
