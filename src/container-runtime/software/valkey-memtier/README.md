# Valkey + Memtier Benchmark - Container Runtime

A single standalone `valkey-server` and the [memtier_benchmark](https://github.com/RedisLabs/memtier_benchmark) load generator, run in one container. memtier drives the server over loopback, so no network hardware or tuning is involved. The server and client are each bound to NUMA nodes / CPUs with `numactl`, and the server's memory can be bound to DRAM, CXL, or an interleave of both.

## How to

Ensure that you have the necessary prerequisites installed, see root of this directory for instructions.

### Build the base image first (one-time)

```bash
cd ../../utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Make a log directory for the benchmark

```bash
mkdir -p results
```

## ENV file

Copy EDITME.env to your .env file for docker-compose. You must set:
 - HOST_RESULTS_DIR: where the output from the benchmark is stored
 - CPU_NUMA_NODE: the CPU NUMA node to bind valkey-server to
 - MEM_NUMA_NODES: the memory NUMA node(s) to allow for valkey-server (DRAM, CXL, or interleaved)

Optional fields are:

| Variable | Default | Description |
|:--|:--|:--|
| `VALKEY_VERSION` | `latest` | Valkey release tag to build. `latest` = newest stable x.y.z tag |
| `MEMTIER_VERSION` | `latest` | memtier_benchmark release tag to build |
| `NUMA_POLICY` | | numactl memory policy for valkey-server, replaces `--membind` (e.g. `--interleave=0,2`, `--preferred=2`) |
| `SERVER_CPU_LIST` | | Pin valkey-server to specific CPUs (e.g. `2-3`) instead of the whole `CPU_NUMA_NODE` |
| `CLIENT_CPU_NUMA_NODE` | `CPU_NUMA_NODE` | CPU NUMA node for memtier |
| `CLIENT_CPU_LIST` | | Pin memtier to specific CPUs instead of a whole node |
| `VALKEY_MAXMEMORY` | `2576980377` | valkey `maxmemory` (bytes, or with unit e.g. `128gb`) |
| `VALKEY_MAXMEMORY_POLICY` | `allkeys-lru` | Eviction policy |
| `VALKEY_APPENDONLY` | `yes` | AOF persistence. RDB snapshots are always off |
| `VALKEY_IO_THREADS` | | Valkey I/O threads |
| `VALKEY_EXTRA_ARGS` | | Additional valkey-server arguments |
| `MEMTIER_PHASES` | `fill read mixed` | Phases to run, in order |
| `MEMTIER_PERCENTILES` | `50,90,95,99,99.9` | Latency percentiles to report |
| `MEMTIER_EXTRA_ARGS` | | Additional memtier arguments for every phase |
| `<PHASE>_*` | see below | Per-phase memtier settings |
| `TEST_NOTE` | `Default Settings` | Descriptive note appended to results |

## Workload

The run starts one valkey-server from an empty data directory, then runs the memtier phases listed in `MEMTIER_PHASES` back to back against it. Each phase is set with `<PHASE>_TEST_TIME`, `_CLIENTS`, `_THREADS`, `_PIPELINE`, `_DATA_SIZE`, `_RATIO`, `_KEY_PATTERN`, `_KEY_MINIMUM`, `_KEY_MAXIMUM`, and `_RATE_LIMIT`. A setting left empty falls back to memtier's own default.

| Phase | Purpose | Default memtier settings |
|:--|:--|:--|
| `fill` | Populate the keyspace (write only) | 240s, 10 threads x 20 clients, pipeline 10, 1024 B values, ratio 1:0, keys 1-100000 parallel sequential (P:P) |
| `read` | Latency at a fixed load (read only) | 240s, 10 threads x 10 clients, pipeline 1, 1024 B values, ratio 0:1, keys 1-100000 parallel sequential (P:P), 500 ops/sec per connection (50K ops/sec total) |
| `mixed` | Unthrottled throughput (1:10 set:get) | 3600s, 4 threads x 50 clients, pipeline 1, 32 B values, ratio 1:10, keys 1-100000 random (R:R) over the range populated by `fill` |

`read` depends on the keys written by `fill`, so a phase failure stops the remaining phases. After `fill`, the run checks how many keys the server holds and warns if fewer than 99% of the range were written.

`fill` and `read` use the `P:P` key pattern: memtier splits the key range across all connections and each connection walks its own slice in order. With `S:S`, every connection walks the whole range on its own, so all connections touch the same keys in lockstep. Reads then mostly hit warm CPU caches, hiding memory latency, and a large key range never finishes filling.

### Sizing for memory-tier testing

The defaults reflect a small production instance (about 100 MB of values, 2.4 GiB `maxmemory`). At that size the dataset fits in any memory tier. To stress capacity, eviction, or CXL placement, raise `FILL_KEY_MAXIMUM` / `READ_KEY_MAXIMUM` (and `VALKEY_MAXMEMORY`) so that keys x value size is a meaningful fraction of the memory being tested, and lengthen `FILL_TEST_TIME` so the fill completes. The run logs a warning when the fill dataset is under half of `maxmemory`.

### Persistence

AOF is on by default to match the production config this workload is derived from. The AOF is written to the container filesystem, which adds disk I/O alongside the memory traffic. Set `VALKEY_APPENDONLY="no"` for a memory-only measurement.

## Everything else (Dockerfile, docker-compose.yml, valkey.conf, *.sh, *.py)

Look but don't `touch`, editing these files will invalidate the testing. We may eventually push the container to dockerhub or something similar but for now you're building it local.

## Building and running

When building you can either use the docker-compose command

```bash
docker-compose build
```
or just docker build

```bash
docker build -t ocp-cms-valkey-memtier-benchmark:latest .
```

`latest` versions are resolved when the image is built and cached by docker afterwards. Rebuild with `docker-compose build --no-cache` to pick up a newer release, or pin a version in `.env`. The versions used are recorded in `versions.txt` in every results directory.

Before running the benchmark, make sure the .env file exists and is configured for your testrun, then run with `sudo` docker-compose

```bash
cp EDITME.env .env
vim .env #And make your changes
sudo docker-compose up -d
```
or without docker-compose

```bash
sudo docker run -d --privileged --volume <path-to-your-host-result-dir>:/opt/valkey-bench/results --env-file ./.env --name valkey-memtier-bench ocp-cms-valkey-memtier-benchmark
```

## What it does

The container:
1. Collects comprehensive system hardware and software BOM (BIOS/firmware, CPU, memory, NUMA/CXL topology, PCI, kernel, packages, etc.)
2. Queries platform topology (sockets, cores, NUMA nodes, CXL devices, hyperthreading)
3. Starts valkey-server bound to the configured CPUs / NUMA node(s) with the specified memory policy
4. Runs each memtier phase against the local valkey-server
5. After each phase, snapshots valkey `INFO` and the per-NUMA-node memory of the valkey-server process (`numastat -p`)
6. Parses the results and generates an HTML report with a results tarball

## Output

Results are stored in the mounted results directory:
 - `results_valkey_memtier.json`: Per-phase throughput, latency percentiles, server memory, server CPU per command, and NUMA placement
 - `results_valkey_memtier.csv`: Per-phase / per-operation summary table
 - `results_valkey_memtier_numa.csv`: valkey-server memory per NUMA node at baseline and after each phase
 - `timeseries_valkey_memtier_<phase>.csv`: Per-second ops and latency for each phase
 - `memtier_<phase>.txt` / `memtier_<phase>.json`: Raw memtier output
 - `server_info_<phase>.txt`, `numastat_<phase>.txt`, `server_config.txt`, `server.log`: Server state
 - `versions.txt`: Valkey and memtier versions used
 - `results.csv`: Benchmark name, test note, and elapsed time
 - `sysinfo/`: Comprehensive system BOM (see `sysinfo/SUMMARY.txt` for overview)
 - `valkey_memtier_report.html`: HTML report with system info and results
 - `valkey_memtier_results.tar.gz`: Archive of all output files

### Latency artifacts

memtier times each request with the wall clock. If the system clock steps backwards during a run (for example a VM resyncing its time with the host), a request can be recorded with a huge latency (about 4,295 seconds, a 32-bit wraparound). That one sample corrupts the reported average and max latency, while the percentiles are unaffected. The parser detects this, because a latency longer than the phase itself is impossible, and adds a `latency_artifact` warning to the phase and to `errors` in the results JSON. When you see it, use the percentiles for that phase. The `timeseries_*` CSV shows which second was affected.
