# Memcached Benchmark - Container Runtime

## How to

Ensure that you have the necessary prerequisites installed, see root of this directory for instructions.

### Build the base image first (one-time)

```bash
cd ../utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Make a log directory for the benchmark

```bash
mkdir -p results
```

## ENV file

Copy EDITME.env to your .env file for docker-compose. You must set:
 - HOST_RESULTS_DIR: where the output from the benchmark is stored
 - CPU_NUMA_NODE: the CPU NUMA node to bind the benchmark to
 - MEM_NUMA_NODES: the memory NUMA node(s) to allow (DRAM, CXL, or interleaved)

Optional fields are:
 - NUMA_POLICY:          numactl memory policy for the memcached server (e.g. `--interleave=0,2`, `--preferred=2`)
 - MEMCACHED_MEMORY_MB:  Max memory for memcached in MB (default: 262144 / 256GB)
 - MEMCACHED_THREADS:    Number of memcached worker threads
 - MEMCACHED_EXTRA_ARGS: Any additional memcached server arguments
 - MEMASLAP_THREADS:     Number of memaslap client threads (default: 16)
 - MEMASLAP_CONCURRENCY: Number of concurrent connections (default: 256)
 - MEMASLAP_DURATION:    Benchmark duration (default: 180s)
 - MEMASLAP_WINDOW_SIZE: Memaslap window size (default: 131072)
 - MEMASLAP_EXTRA_ARGS:  Any additional memaslap arguments
 - CONTAINER_MAX_MEMORY: Docker --memory limit (e.g. "155G")
 - CONTAINER_MAX_SWAP:   Docker --memory-swap limit (e.g. "256G")
 - TEST_NOTE:            Descriptive note appended to results

## Everything else (Dockerfile, docker-compose.yml, *.sh)

Look but don't `touch`, editing these files will invalidate the testing. We may eventually push the container to dockerhub or something similar but for now you're building it local.

## Building and running

When building you can either use the docker-compose command

```bash
docker-compose build
```
or just docker build

```bash
docker build -t OCP-CMS-memcached-benchmark:latest .
```

Before running the benchmark, make sure the .env file exists and is configured for your testrun, then run with `sudo` docker-compose

```bash
cp EDITME.env .env
vim .env #And make your changes
sudo docker-compose up -d
```
or without docker-compose

```bash
sudo docker run -d --privileged --volume <path-to-your-host-result-dir>:/opt/memcached-bench/results --env-file ./.env --name memcached-bench OCP-CMS-memcached-benchmark
```

## What it does

The container:
1. Collects comprehensive system hardware and software BOM (BIOS/firmware, CPU, memory, NUMA/CXL topology, PCI, kernel, packages, etc.)
2. Queries platform topology (sockets, cores, NUMA nodes, CXL devices, hyperthreading)
3. Starts a memcached server bound to the configured NUMA node(s) with the specified memory policy
4. Runs the memaslap load generator against the local memcached instance
5. Records elapsed time, memaslap output, and generates an HTML report with results tarball

## Output

Results are stored in the mounted results directory:
 - `results.csv`: Summary with benchmark name, test note, and elapsed time
 - `raw_results.txt`: Full memaslap output
 - `sysinfo/`: Comprehensive system BOM (see `sysinfo/SUMMARY.txt` for overview)
 - `memcached_report.html`: HTML report with system info and results
 - `memcached_results.tar.gz`: Archive of all output files
