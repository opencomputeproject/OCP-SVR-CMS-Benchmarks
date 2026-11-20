# Cassandra + cassandra-stress Benchmark - Container Runtime

A single-node [Apache Cassandra](https://cassandra.apache.org/) server (latest 5.0.x on OpenJDK 17) and the bundled `cassandra-stress` load generator, run in one container. cassandra-stress drives the node over loopback with a blog-post data model, so no network hardware or tuning is involved. The Cassandra JVM and the stress client are each bound to NUMA nodes / CPUs with `numactl`, and the server's memory can be bound to DRAM, CXL, or an interleave of both.

## How to

Ensure that you have the necessary prerequisites installed, see root of this directory for instructions.

### Build the base image first (one-time)

```bash
cd ../../utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Make a log directory and a data directory for the benchmark

```bash
mkdir -p results data
```

Put the data directory on a fast local disk (NVMe). It holds the SSTables, commit log, and hints, and can grow to hundreds of GB on a full-length run (see [Sizing](#sizing)).

## ENV file

Copy EDITME.env to your .env file for docker-compose. You must set:
 - HOST_RESULTS_DIR: where the output from the benchmark is stored
 - HOST_DATA_DIR: where Cassandra stores its data. **The `data/`, `commitlog/`, `hints/`, `saved_caches/` and `cdc_raw/` subdirectories are wiped at the start of every run**
 - CPU_NUMA_NODE: the CPU NUMA node to bind the Cassandra JVM to
 - MEM_NUMA_NODES: the memory NUMA node(s) to allow for the Cassandra JVM (DRAM, CXL, or interleaved)

Optional fields are:

| Variable | Default | Description |
|:--|:--|:--|
| `CASSANDRA_VERSION` | `5.0` | Cassandra release to install. `5.0` = newest 5.0.x, `latest` = newest release, or pin `x.y.z` |
| `NUMA_POLICY` | | numactl memory policy for the Cassandra JVM, replaces `--membind` (e.g. `--interleave=0,2`, `--preferred=2`) |
| `SERVER_CPU_LIST` | | Pin Cassandra to specific CPUs (e.g. `0-15`) instead of the whole `CPU_NUMA_NODE` |
| `CLIENT_CPU_NUMA_NODE` | `CPU_NUMA_NODE` | CPU NUMA node for cassandra-stress |
| `CLIENT_CPU_LIST` | | Pin cassandra-stress to specific CPUs instead of a whole node |
| `CASSANDRA_HEAP_SIZE` | `8G` | JVM heap (`MAX_HEAP_SIZE`). G1 is the default collector on JDK 17 |
| `MEMTABLE_ALLOCATION_TYPE` | `heap_buffers` | `heap_buffers`, `offheap_buffers` or `offheap_objects` |
| `CASSANDRA_YAML_OVERRIDES` | | Extra `cassandra.yaml` settings, e.g. `concurrent_reads=64,trickle_fsync=false` |
| `CASSANDRA_JVM_EXTRA_OPTS` | | Extra JVM options, space separated, e.g. `-XX:+AlwaysPreTouch` |
| `DOMAIN_POPULATION` | `10000000` | Number of blog domains (partitions) written by `populate` and used by every phase |
| `STRESS_PHASES` | `populate a b c` | Phases to run, in order |
| `STRESS_CL` | `LOCAL_QUORUM` | Consistency level (a single replica with RF=1) |
| `STRESS_POP_DIST` | `gaussian` | Key access pattern for `a`/`b`/`c` over the domains: `gaussian` or `uniform` |
| `STRESS_LOG_INTERVAL` | `60` | Seconds between cassandra-stress progress lines |
| `STRESS_EXTRA_ARGS` | | Additional cassandra-stress arguments for every phase |
| `COMPACTION_WAIT` | `1800` | Max seconds to wait for compactions to settle after `populate` |
| `<PHASE>_*` | see below | Per-phase cassandra-stress settings |
| `TEST_NOTE` | `Default Settings` | Descriptive note appended to results |

## Workload

The data model is the `blogposts` table from the cassandra-stress user profile [blogpost.yaml](https://gist.github.com/tjake/fb166a659e8fe4c8d4a3): one partition per blog domain, up to 1000 posts per domain, with text bodies of 100 to 5000 bytes (about 2.8 KB per post on average). The table uses LeveledCompactionStrategy. The keyspace uses SimpleStrategy with replication factor 1.

The run starts one Cassandra node from empty data directories. It then runs the phases listed in `STRESS_PHASES` back to back. `insert` writes one post into one domain. `singlepost` reads the latest post of one domain.

| Phase | Purpose | Default cassandra-stress settings |
|:--|:--|:--|
| `populate` | Write one post into every domain | `ops(insert=1)`, `n=DOMAIN_POPULATION`, domains visited sequentially, `POPULATE_THREADS=64` |
| `a` | Read heavy | `ops(insert=20,singlepost=100)`, 120m, 20 threads |
| `b` | Blog mix | `ops(insert=2,singlepost=8)`, 120m, 80 threads |
| `c` | Write heavy | `ops(insert=60,singlepost=40)`, 120m, 20 threads |

Each profile phase is set with `<PHASE>_OPS`, `_DURATION`, `_THREADS` and `_RATE`. `_RATE` is an optional fixed ops/sec cap, and the default leaves every phase unthrottled. All phases use `cl=LOCAL_QUORUM`, `no-warmup` and `-errors ignore`.

After `populate`, the run flushes memtables and waits up to `COMPACTION_WAIT` seconds for pending compactions. This way each profile starts from a settled on-disk state. It then warns if the table holds fewer than 90% of `DOMAIN_POPULATION` partitions, based on nodetool's estimate. If a phase fails, the remaining phases are skipped.

Profiles A, B and C come from a three-node production recipe. That recipe ran each profile from a separate client, against an empty cluster, and capped profile C at 4500 ops/sec. Here a single node and a single client run all three profiles back to back after `populate`, and nothing is capped.

### Domain population

cassandra-stress does not map key seeds directly to domains. Each seed is hashed to a domain id drawn from the profile's domain `population`. With N seeds over N ids, only about 63% of the ids are ever produced. As a result, a populate pass would leave a third of the domains empty, and reads of those domains would return nothing.

The run avoids this as follows:
 - The profile's domain id space is set to 1000 x `DOMAIN_POPULATION`, so N seeds produce about N distinct domains.
 - Every phase draws seeds from the same range, 1..`DOMAIN_POPULATION`. `populate` walks it sequentially. The profiles sample it with `STRESS_POP_DIST`: `gaussian` is the cassandra-stress default shape, with a hot middle; `uniform` makes every domain equally likely.

`singlepost` therefore always reads a domain that exists. The parser reports the read hit rate per phase, and warns if it falls below 99%. That would happen, for example, if `populate` was skipped. The effective profile is saved as `stress_profile.yaml` in the results.

### Sizing

Data grows with every insert, at about 2.8 KB per post before compaction overhead:
 - `populate` writes `DOMAIN_POPULATION` posts, about 28 GB at the 10M default.
 - The profiles keep inserting for their whole duration. For example, 10K inserts/sec for 120 minutes adds about 72M posts, or roughly 200 GB.

A domain holds at most 1000 posts, so later inserts start overwriting earlier posts and compaction removes the duplicates.

With the defaults, a full run takes a little over 6 hours. To make the dataset larger than DRAM or the memory tier being tested, raise `DOMAIN_POPULATION`, and size `HOST_DATA_DIR` accordingly. For a quick functional check, use something like `DOMAIN_POPULATION=100000` with `*_DURATION=5m`.

### Server configuration

`cassandra.yaml` is generated at run time from the release's stock file. The run applies `cassandra-overrides.yaml` (the single-node equivalent of the production config) and then any `CASSANDRA_YAML_OVERRIDES`. Every changed key is logged, and the effective file is saved as `cassandra.yaml` in the results.

The JVM uses the release's `jvm17-server.options` with `MAX_HEAP_SIZE=CASSANDRA_HEAP_SIZE`. The GC log is reduced to GC events with wall-clock timestamps, in 100 MB files. The stock setting writes detailed heap logging into 10 x 10 MB files, which rotates away the early phases of a multi-hour run.

`bin/cassandra` normally re-launches the JVM under `numactl --interleave=all`, which would override the requested binding. The run instead passes the server binding through `NUMACTL_ARGS`, so the JVM runs with exactly the configured CPU and memory policy. The JVM command line is logged at startup.

## Everything else (Dockerfile, docker-compose.yml, cassandra-overrides.yaml, blogpost.yaml, *.sh, *.py)

Look but don't `touch`, editing these files will invalidate the testing. We may eventually push the container to dockerhub or something similar but for now you're building it local.

## Building and running

When building you can either use the docker-compose command

```bash
docker-compose build
```
or just docker build

```bash
docker build -t ocp-cms-cassandra-stress-benchmark:latest .
```

The Cassandra version is resolved when the image is built, and docker caches the result afterwards. To pick up a newer release, rebuild with `docker-compose build --no-cache`, or pin a version in `.env`. The release tarball is verified against its published SHA-512 checksum. The versions used are recorded in `versions.txt` in every results directory.

Before running the benchmark, make sure the .env file exists and is configured for your testrun, then run with `sudo` docker-compose

```bash
cp EDITME.env .env
vim .env #And make your changes
sudo docker-compose up -d
```
or without docker-compose

```bash
sudo docker run -d --privileged --volume <path-to-your-host-result-dir>:/opt/cassandra-bench/results --volume <path-to-your-host-data-dir>:/data/cassandra --env-file ./.env --name cassandra-stress-bench ocp-cms-cassandra-stress-benchmark
```

## What it does

The container:
1. Collects comprehensive system hardware and software BOM (BIOS/firmware, CPU, memory, NUMA/CXL topology, PCI, kernel, packages, etc.)
2. Queries platform topology (sockets, cores, NUMA nodes, CXL devices, hyperthreading)
3. Generates `cassandra.yaml` and starts one Cassandra node bound to the configured CPUs / NUMA node(s) with the specified memory policy
4. Runs each cassandra-stress phase against the local node, with the client bound to its own CPUs
5. After each phase, snapshots the per-NUMA-node memory of the Cassandra JVM (`numastat -p`), its CPU time, `nodetool info` / `tpstats` / `tablestats`, and disk usage
6. Drains and stops the node, parses the results, and generates an HTML report with a results tarball

## Output

Results are stored in the mounted results directory:
 - `results_cassandra_stress.json`: per phase, the following:
   - throughput and latency percentiles, overall and per operation
   - read hit rate
   - server CPU (cores used, and µs per operation)
   - server GC
   - heap and key cache state
   - table state (SSTables, partitions, size)
   - disk usage
   - NUMA placement
 - `results_cassandra_stress.csv`: Per-phase / per-operation summary table
 - `results_cassandra_stress_numa.csv`: Cassandra JVM memory per NUMA node at baseline and after each phase
 - `timeseries_cassandra_stress_<phase>.csv`: Per-interval throughput, latency, and server GC for each phase
 - `stress_<phase>.txt` / `stress_graph_<phase>.html`: Raw cassandra-stress output and its interactive graph
 - `numastat_<phase>.txt`, `proc_stat_<phase>*.txt`, `nodetool_*_<phase>.txt`, `disk_usage_<phase>.txt`, `phase_times.csv`: Server state
 - `cassandra.yaml`, `stress_profile.yaml`: Effective server config and stress profile
 - `cassandra_logs/`: Server `system.log`, `debug.log`, `gc.log` and stdout
 - `versions.txt`: Cassandra and Java versions used
 - `results.csv`: Benchmark name, test note, and elapsed time
 - `sysinfo/`: Comprehensive system BOM (see `sysinfo/SUMMARY.txt` for overview)
 - `cassandra_stress_report.html`: HTML report with system info and results
 - `cassandra_stress_results.tar.gz`: Archive of all output files

Server CPU is measured from `/proc/<pid>/stat` immediately before and after each stress run. Background work right after a phase, such as the post-`populate` compactions, is not charged to any phase. Server GC comes from cassandra-stress itself, which polls the node's collectors over JMX during the run.
