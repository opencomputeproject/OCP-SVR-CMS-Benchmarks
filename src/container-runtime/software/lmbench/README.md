# LMBench + LMCache — Two-Container OCP CMS Benchmark

OCP SRV CMS container wrapper for [LMBench](https://github.com/LMCache/LMBench)
with a separated [LMCache](https://github.com/LMCache/LMCache) serving engine.
Benchmarks LLM inference serving performance across configurable KV cache
backends, workload generators, and deployment topologies.

## Architecture

This benchmark uses two containers with distinct responsibilities:

```
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│  lmcache-server                  │    │  lmbench-client                  │
│  (System Under Test)             │    │  (Load Generator)                │
│                                  │    │                                  │
│  vLLM inference engine           │    │  LMBench run-bench.py            │
│  + LMCache KV cache layer        │    │  (workload generators only,      │
│                                  │    │   stages 1-2 skipped)            │
│  Exposes: :30080/v1/models       │    │                                  │
│           :30080/v1/completions   │◄───│  Fires HTTP requests at server   │
│           :30080/v1/chat          │    │  Collects JSON results           │
│                                  │    │                                  │
│  KV cache backend (swappable):   │    │  OCP CMS integration:            │
│  ┌────────────────────────────┐  │    │  • sysinfo BOM collection        │
│  │ configs/<backend>.yaml     │  │    │  • parse_results.py → JSON/CSV   │
│  │                            │  │    │  • generate_report.sh → HTML     │
│  │ cpu_offload  (default)     │  │    │  • cms_package_results → tarball │
│  │ disk                       │  │    │                                  │
│  │ redis                      │  │    │  No vLLM. No LMCache.            │
│  │ lmserver                   │  │    │  Pure traffic generation +       │
│  │ mooncake                   │  │    │  results reporting.              │
│  │ infinistore                │  │    │                                  │
│  │ maru  (CXL shared memory)  │  │    └──────────────────────────────────┘
│  │ custom                     │  │
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

**Why two containers?** The LMCache backend changes independently of the
benchmark workloads. Swapping backends (e.g., testing Maru vs cpu_offload
vs Redis) means editing one line in `.env` and rebuilding only the server.
The client image never changes. Optionally, the containers can run on
separate machines so the load generator doesn't compete with the SUT for
CPU, memory, or PCIe bandwidth.

---

## Prerequisites

### Build the OCP CMS base image (one-time)

Both containers inherit from `ocp-cms-base:latest`. Build it first:

```bash
cd src/container-runtime/utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Hardware requirements

**CPU mode** (`LMBENCH_DEVICE=cpu`, default):
- x86_64 CPU with AVX512 or AVX2
- DRAM for model weights + KV cache. Sizing guide:
  - Llama 3.1 8B (BF16): ~16 GB weights + `VLLM_CPU_KVCACHE_SPACE` GB
  - Llama 3.1 70B (BF16): ~140 GB weights + KV cache
- Keep total under single NUMA node capacity when `VLLM_CPU_TP=1`

**GPU mode** (`LMBENCH_DEVICE=gpu`, requires `--profile gpu`):
- NVIDIA GPU(s) with CUDA drivers
- `nvidia-container-toolkit` installed and configured for Docker
- VRAM sufficient for model + KV cache at `VLLM_GPU_MEMORY_UTILIZATION`

### Authentication

A HuggingFace token is required for gated models (Llama, Mistral, etc.):
```bash
HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```
Get one at https://huggingface.co/settings/tokens.

---

## Quick Start (Single Machine, CPU Mode)

```bash
cd src/container-runtime/software/lmbench

# 1. Configure
cp EDITME.env .env
nano .env
#   Required: set HF_TOKEN
#   Optional: change LMCACHE_BACKEND, LMBENCH_MODEL_URL, workload params

# 2. Build both containers
docker compose build

# 3. Run
docker compose up
```

The server starts vLLM + LMCache and waits for readiness on port 30080.
The client waits for the server healthcheck to pass, then runs the
configured workloads. Results land in `./results/`.

To stop: `Ctrl-C` or `docker compose down`.

---

## Configuration

All configuration lives in a single `.env` file. Copy `EDITME.env` to
`.env` and edit the values you need. The same `.env` is read by both
containers via `env_file:` in docker-compose.

### Model and Device

| Variable | Default | Description |
|---|---|---|
| `LMBENCH_DEVICE` | `cpu` | `cpu` or `gpu`. Controls which vLLM wheel is installed and which vllm serve flags are used. |
| `LMBENCH_MODEL_URL` | `meta-llama/Llama-3.1-8B-Instruct` | Any HuggingFace model ID. Must match your available compute. |
| `VLLM_MAX_MODEL_LEN` | `4096` | Maximum context length. Lower values use less memory. Llama 3.1 supports up to 128k. |
| `HF_TOKEN` | *(required)* | HuggingFace token for gated model access. |

### CPU Tuning (when `LMBENCH_DEVICE=cpu`)

| Variable | Default | Description |
|---|---|---|
| `VLLM_CPU_KVCACHE_SPACE` | `4` | vLLM internal KV cache in GiB. More = longer contexts, more concurrent requests. |
| `VLLM_CPU_OMP_THREADS_BIND` | `auto` | CPU core binding. `auto` for NUMA-aware. `0-31` to bind to specific cores. `0-31\|32-63` for TP across two NUMA nodes. |
| `VLLM_CPU_DTYPE` | `auto` | Inference precision. `bfloat16` on AVX512 CPUs, `float32` on older CPUs, `auto` to let vLLM decide. |
| `VLLM_CPU_TP` | `1` | Tensor parallelism degree. Set to 2 for dual-socket systems. Each TP rank's threads must be on the same NUMA node. |

### GPU Tuning (when `LMBENCH_DEVICE=gpu`)

| Variable | Default | Description |
|---|---|---|
| `CUDA_VISIBLE_DEVICES` | `0` | GPU device IDs. `0,1` for two GPUs. |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.8` | Fraction of VRAM for KV cache. 0.0–1.0. |

---

## LMCache Backend Configuration

The backend determines how LMCache stores and retrieves KV cache data.
Each backend has a pre-baked YAML config template in `configs/`. At
server startup, `envsubst` injects your connection parameters, and the
resolved config is passed to vLLM via `LMCACHE_CONFIG_FILE`.

**To swap backends:** change `LMCACHE_BACKEND` in `.env`, rebuild the
server container, run. The client container does not need rebuilding.

```bash
# Example: switch from cpu_offload to maru
# 1. Edit .env:
LMCACHE_BACKEND=maru
LMCACHE_MARU_HOST=localhost
LMCACHE_MARU_POOL_SIZE=8

# 2. Rebuild server only:
docker compose build lmcache-server

# 3. Run:
docker compose up
```

### Backend Reference

#### `none` — Plain vLLM (baseline)

No LMCache. Runs vLLM without any KV cache offloading. Use this as
the performance baseline when comparing backends.

```bash
LMCACHE_BACKEND=none
```

No additional configuration.

#### `cpu_offload` — CPU RAM (default)

KV cache offloaded to pinned CPU RAM. No external services required.
Good default for testing and single-machine deployments.

```bash
LMCACHE_BACKEND=cpu_offload
```

Config template (`configs/cpu_offload.yaml`):
```yaml
chunk_size: 256
local_cpu: true
max_local_cpu_size: 5.0    # GiB of pinned CPU RAM
```

#### `disk` — Local Disk

Extends CPU offloading with a disk tier. KV cache spills to local
disk when CPU RAM is full. No external services.

```bash
LMCACHE_BACKEND=disk
```

#### `redis` — Redis Remote Store

KV cache stored in a Redis instance. Enables sharing across multiple
vLLM instances. You provide the Redis server.

```bash
LMCACHE_BACKEND=redis
LMCACHE_REMOTE_HOST=my-redis-server    # default: localhost
LMCACHE_REMOTE_PORT=6379               # default: 6379
```

#### `lmserver` — LMCache Server

KV cache stored via LMCache's native `lm://` protocol. You run the
LMCache server separately.

```bash
LMCACHE_BACKEND=lmserver
LMCACHE_REMOTE_HOST=my-lmcache-server  # default: localhost
LMCACHE_REMOTE_PORT=65432              # default: 65432
```

#### `mooncake` — Mooncake Distributed Store

KV cache stored in Mooncake, a distributed key-value engine for LLM
inference. Requires Mooncake master + metadata server.

```bash
LMCACHE_BACKEND=mooncake
LMCACHE_REMOTE_HOST=mooncake-master          # default: localhost
LMCACHE_REMOTE_PORT=50051                    # default: 50051
LMCACHE_MOONCAKE_METADATA_SERVER=http://mooncake-master:8080/metadata
LMCACHE_MOONCAKE_PROTOCOL=tcp               # default: tcp
```

#### `infinistore` — InfiniStore (RDMA)

KV cache stored in InfiniStore for RDMA-speed remote access.

```bash
LMCACHE_BACKEND=infinistore
LMCACHE_REMOTE_HOST=infinistore-server   # default: localhost
LMCACHE_REMOTE_PORT=12345               # default: 12345
LMCACHE_INFINISTORE_DEVICE=mlx5_1       # optional: RDMA device
```

#### `maru` — Maru CXL Shared Memory

[Maru](https://github.com/xcena-dev/maru) is a CXL shared memory KV
cache engine. Data lives directly in CXL mmap memory. Gets are
zero-copy — no network I/O, no serialization. Designed for
multi-instance KV cache sharing with minimal latency.

**Host prerequisites:**
- CXL device accessible via `/dev/dax*`
- `maru-server` running on the host

```bash
# Install Maru on the host (outside containers):
git clone https://github.com/xcena-dev/maru
cd maru && ./install.sh

# Start the Maru server:
maru-server
```

**Container configuration:**
```bash
LMCACHE_BACKEND=maru
LMCACHE_MARU_HOST=localhost    # default: localhost
LMCACHE_MARU_PORT=5555         # default: 5555
LMCACHE_MARU_POOL_SIZE=4       # GiB of CXL memory per vLLM instance
```

The server container installs `maru` and `maru-lmcache` Python packages
at startup. If pip packages are unavailable, it falls back to a source
install from the Maru GitHub repository.

Config template (`configs/maru.yaml`):
```yaml
chunk_size: 256
local_cpu: false              # CXL replaces CPU hot cache
max_local_cpu_size: 0
save_unfull_chunk: true
maru_path: "maru://localhost:5555"
maru_pool_size: 4
```

Advanced Maru tuning (via `LMCACHE_CONFIG_FILE_CONTENT` custom override):

| Parameter | Default | Description |
|---|---|---|
| `maru_instance_id` | auto UUID | Client instance identifier |
| `maru_timeout_ms` | 5000 | ZMQ RPC timeout (ms) |
| `maru_use_async_rpc` | true | Async DEALER-ROUTER RPC |
| `maru_max_inflight` | 64 | Max concurrent async RPCs |
| `maru_eager_map` | true | Pre-map all shared regions on connect |

#### `custom` — User-Provided Config

Full control. Provide a complete LMCache config YAML encoded as base64:

```bash
LMCACHE_BACKEND=custom
LMCACHE_CONFIG_FILE_CONTENT=$(base64 -w0 my-lmcache-config.yaml)
```

Or mount a file into the server container at `/opt/server/custom_config.yaml`.

---

## Workload Configuration

The client runs [LMBench](https://github.com/LMCache/LMBench) workload
generators against the server's OpenAI-compatible API. Workloads are
configured via environment variables in `.env`.

### Selecting Workloads

Set `LMBENCH_WORKLOADS` to a comma-separated list:

```bash
# Single workload
LMBENCH_WORKLOADS=synthetic

# Multiple workloads (run sequentially)
LMBENCH_WORKLOADS=synthetic,sharegpt,random
```

### Available Workloads

**`synthetic`** — LMCache's multi-round synthetic generator. Simulates
users with shared system prompts and chat history, targeting KV cache
reuse scenarios.

| Variable | Default | Description |
|---|---|---|
| `SYNTHETIC_NUM_USERS_WARMUP` | 650 | Users for cache warmup phase |
| `SYNTHETIC_NUM_USERS` | 350 | Users for measurement phase |
| `SYNTHETIC_NUM_ROUNDS` | 20 | Conversation rounds per user |
| `SYNTHETIC_SYSTEM_PROMPT` | 0 | System prompt token length |
| `SYNTHETIC_CHAT_HISTORY` | 20000 | Chat history token length |
| `SYNTHETIC_ANSWER_LEN` | 1000 | Expected answer token length |
| `SYNTHETIC_QPS` | 0.7 | Queries per second (comma-separated for sweep) |
| `SYNTHETIC_USE_SHAREGPT` | false | Use ShareGPT data for prompts |

**`sharegpt`** — Real conversation data from ShareGPT.

| Variable | Default | Description |
|---|---|---|
| `SHAREGPT_LIMIT` | 1000 | Max conversations to sample |
| `SHAREGPT_MIN_ROUNDS` | 10 | Minimum rounds per conversation |
| `SHAREGPT_START_ROUND` | 0 | Starting round index |
| `SHAREGPT_QPS` | 1.34 | Queries per second |

**`agentic`** — Simulates agentic workflows with tool-calling patterns.

| Variable | Default | Description |
|---|---|---|
| `AGENTIC_NUM_AGENTS` | 10 | Number of concurrent agents |
| `AGENTIC_NUM_ROUNDS` | 20 | Rounds per agent |
| `AGENTIC_CHAT_HISTORY` | 256 | Context window per agent |
| `AGENTIC_ANSWER_LEN` | 20 | Short answers (tool calls) |
| `AGENTIC_NEW_USER_INTERVALS` | 1 | Seconds between new users |

**`random`** — Uniform random prompts with fixed token lengths.

| Variable | Default | Description |
|---|---|---|
| `RANDOM_NUM_USERS` | 100 | Concurrent users |
| `RANDOM_NUM_ROUNDS` | 10 | Rounds per user |
| `RANDOM_PROMPT_LEN` | 200 | Input token length |
| `RANDOM_ANSWER_LEN` | 100 | Output token length |
| `RANDOM_QPS` | 1.0 | Queries per second |

**`vllm_benchmark`** — vLLM's native `benchmark_serving.py` workload.

| Variable | Default | Description |
|---|---|---|
| `VLLM_BENCH_NUM_PROMPTS` | 100 | Number of prompts |
| `VLLM_BENCH_REQUEST_RATES` | 1.0 | Requests/sec (comma-separated for sweep) |
| `VLLM_BENCH_DATASET_NAME` | random | `random` or `sharegpt` |
| `VLLM_BENCH_RANDOM_INPUT_LEN` | 1024 | Input length (random dataset) |
| `VLLM_BENCH_RANDOM_OUTPUT_LEN` | 128 | Output length (random dataset) |

**`strict_synthetic`** — Deterministic synthetic with precise timing control.

| Variable | Default | Description |
|---|---|---|
| `STRICT_NUM_CONCURRENT_USERS` | 10 | Exact concurrent user count |
| `STRICT_NUM_ROUNDS_PER_USER` | 5 | Rounds per user |
| `STRICT_TIME_BETWEEN_REQUESTS` | 10 | Seconds between requests (comma-separated for sweep) |
| `STRICT_KV_REUSE_RATIO` | 1.0 | Fraction of KV cache to reuse |

**`trace_replayer`** — Replays production traffic traces.

| Variable | Default | Description |
|---|---|---|
| `TRACE_FILE` | `traces/gmi_trace.jsonl` | Path to trace file |
| `TRACE_DURATION` | `full` | Duration to replay (`full` or seconds) |
| `TRACE_SPEED_UP` | 1.0 | Speedup factor |
| `TRACE_PRESERVE_TIMING` | true | Maintain original inter-request timing |

### QPS Sweep Testing

Most QPS/rate parameters accept comma-separated values. LMBench runs
each value as a separate experiment:

```bash
SYNTHETIC_QPS=0.5,1.0,2.0,5.0
VLLM_BENCH_REQUEST_RATES=1.0,2.0,5.0,10.0
```

### Suite Naming

Results are organized by suite name:

```bash
LMBENCH_SUITE_NAME=ocp-cms-lmbench    # default
```

---

## Deployment Mode 1: Single Machine

Both containers on the same host. The client shares the server's network
namespace via `network_mode: "service:lmcache-server"`, so LMBench's
hardcoded `localhost:30080` reaches vLLM without patching.

```bash
# CPU mode (default)
docker compose build
docker compose up

# GPU mode
docker compose --profile gpu build
docker compose --profile gpu up
```

The client container has `depends_on` with `condition: service_healthy`.
It will not start until the server's healthcheck passes (vLLM responds
on `/v1/models`). Server startup can take 2–15 minutes depending on
model download and loading time.

## Deployment Mode 2: Split Across Two Machines

Server on Machine A (system under test), client on Machine B (load
generator). This isolates the SUT from load generation overhead —
the benchmark client won't compete for CPU, memory, or PCIe bandwidth.

### Machine A — Server (SUT)

```bash
cd src/container-runtime/software/lmbench
cp EDITME.env .env
nano .env
#   Set: HF_TOKEN, LMCACHE_BACKEND, LMBENCH_DEVICE, model config
#   Set backend-specific vars (LMCACHE_MARU_*, LMCACHE_REMOTE_*, etc.)

# Build and start server only
docker compose build lmcache-server
docker compose up lmcache-server

# For GPU mode:
docker compose --profile gpu build lmcache-server-gpu
docker compose --profile gpu up lmcache-server-gpu
```

Verify the server is up from any machine:
```bash
curl http://<machine-a-ip>:30080/v1/models
```

Port 30080 is exposed on the host via `ports: "30080:30080"`.

### Machine B — Client (Load Generator)

Copy the project files (`lmbench/` directory) to Machine B. Then:

```bash
cd src/container-runtime/software/lmbench
cp EDITME.env .env
nano .env
#   Set: HF_TOKEN (same as Machine A)
#   Set: workload parameters (LMBENCH_WORKLOADS, SYNTHETIC_*, etc.)
#   Do NOT set LMCACHE_BACKEND — the client doesn't use it

# Build client only
docker compose build lmbench-client

# Run with the split-machine override
LMBENCH_SERVER_URL=http://<machine-a-ip>:30080 \
  docker compose \
    -f docker-compose.yml \
    -f docker-compose.client-only.yml \
    up lmbench-client
```

**What the override does:**
- `docker-compose.client-only.yml` removes `network_mode: "service:lmcache-server"`
  and `depends_on` from the client (server is on a different host)
- Sets `network_mode: "host"` so the client can reach Machine A directly
- The client entrypoint detects `LMBENCH_SERVER_URL` is set and patches
  all hardcoded `localhost:30080` references in LMBench's Python code
  via `sed` before running workloads

### Network Requirements

| Direction | Port | Protocol | Purpose |
|---|---|---|---|
| Machine B → Machine A | 30080 | HTTP | vLLM OpenAI-compatible API |

Remote KV cache backends (Redis, Mooncake, InfiniStore, Maru) only need
to be reachable from Machine A. The client never talks to them.

---

## Output and Reporting

After a benchmark run, the client produces the following in `./results/`
(or wherever `HOST_RESULTS_DIR` points):

```
results/
├── lmbench-<suite>_report.html       # CMS HTML report (primary deliverable)
├── results_lmbench_<suite>.json      # Normalized results (structured)
├── results_lmbench_<suite>.csv       # Normalized results (flat table)
├── lmbench.log                       # Full console log
├── sysinfo/                          # Hardware/software BOM from CMS
│   ├── cpu_info.txt
│   ├── mem_info.txt
│   ├── pci_topology.txt
│   └── ...
├── config/                           # Reproducibility artifacts
│   ├── run-bench.yaml                # Generated LMBench top-level config
│   ├── custom/ocp-cms-spec.yaml      # Generated benchmark spec
│   └── lmcache_backend_info.json     # Backend + device + model metadata
├── lmbench_results/                  # Raw LMBench JSON output per experiment
│   └── <suite-name>/
│       └── <baseline>_<workload>_<qps>_<timestamp>.json
└── lmbench-<suite>_results.tar.gz   # Complete archive of everything above
```

### Key Metrics in Reports

| Metric | Unit | Description |
|---|---|---|
| Request Throughput | req/s | Completed requests per second |
| Output Token Throughput | tok/s | Generated tokens per second |
| Total Token Throughput | tok/s | Input + output tokens per second |
| TTFT (Time To First Token) | ms | Latency until first output token (mean, median, P99) |
| TPOT (Time Per Output Token) | ms | Average time between successive tokens (mean, median, P99) |
| ITL (Inter-Token Latency) | ms | Per-token generation latency (mean, median, P99) |

The HTML report includes system BOM data (CPU, memory, topology) alongside
benchmark results. Results are also available as JSON and CSV for
programmatic analysis or comparison across runs.

Previous run results are automatically archived into `results/previous_runs/`
with timestamps, so you can run multiple backend configurations sequentially
without losing data.

---

## Typical Workflows

### Compare backends on the same machine

```bash
# Run 1: baseline (no LMCache)
LMCACHE_BACKEND=none docker compose up
# results archived automatically

# Run 2: CPU offload
LMCACHE_BACKEND=cpu_offload docker compose up

# Run 3: Maru CXL
LMCACHE_BACKEND=maru docker compose up

# Compare the three HTML reports in ./results/ and ./results/previous_runs/
```

### Isolate load generation from SUT

```bash
# Machine A (SUT with GPU + Maru):
LMCACHE_BACKEND=maru docker compose --profile gpu up lmcache-server-gpu

# Machine B (load gen — any hardware):
LMBENCH_SERVER_URL=http://machine-a:30080 \
  docker compose -f docker-compose.yml -f docker-compose.client-only.yml \
  up lmbench-client
```

### QPS sweep for latency-throughput curve

```bash
# In .env:
LMBENCH_WORKLOADS=synthetic
SYNTHETIC_QPS=0.5,1.0,2.0,4.0,8.0

docker compose up
# Produces one JSON result per QPS value — plot TTFT vs throughput
```

---

## Troubleshooting

**Server takes a long time to start:**
First run downloads the model from HuggingFace (Llama 8B ≈ 16 GB). The
healthcheck has a 120-second start period and retries for up to 15 minutes.
Check logs with `docker compose logs lmcache-server -f`.

**Client exits immediately with "Timed out waiting for serving endpoint":**
Server didn't pass healthcheck within 15 minutes. Check server logs for
errors. Common causes: insufficient memory for model weights, missing
`HF_TOKEN`, network issues downloading the model.

**"vLLM died" in server logs:**
Usually out-of-memory. For CPU mode, reduce `VLLM_MAX_MODEL_LEN` or use a
smaller model. For GPU mode, reduce `VLLM_GPU_MEMORY_UTILIZATION`.

**Maru: "Failed to connect MaruHandler":**
`maru-server` isn't running on the host, or the port/host is wrong.
Verify with `maru-server` on the host and check `LMCACHE_MARU_HOST`
and `LMCACHE_MARU_PORT`.

**Redis/Mooncake/InfiniStore connection refused:**
The remote backend service isn't reachable from the server container.
These services must be accessible from Machine A (server), not Machine B
(client). Check `LMCACHE_REMOTE_HOST` and firewall rules.

**Split-machine: "connection refused" from client:**
Check that Machine A's port 30080 is open and reachable. Verify with
`curl http://<machine-a-ip>:30080/v1/models` from Machine B.

---

## File Inventory

```
lmbench/
├── EDITME.env                     # All configuration — copy to .env
├── Dockerfile.server              # Server image: vLLM + LMCache
├── Dockerfile.client              # Client image: LMBench + CMS reporting
├── docker-compose.yml             # Single-machine orchestration
├── docker-compose.client-only.yml # Split-machine override for client
├── server-entrypoint.sh           # Resolves backend config, starts vLLM
├── client-entrypoint.sh           # Waits for server, runs workloads, reports
├── setup_env.sh                   # Generates run-bench.yaml + spec from env
├── parse_results.py               # Normalizes LMBench JSON → CMS JSON/CSV
├── configs/                       # Pre-baked LMCache backend configs
│   ├── cpu_offload.yaml           #   CPU RAM offloading (default)
│   ├── disk.yaml                  #   CPU + local disk offloading
│   ├── redis.yaml                 #   Redis remote store
│   ├── lmserver.yaml              #   LMCache server (lm:// protocol)
│   ├── mooncake.yaml              #   Mooncake distributed store
│   ├── infinistore.yaml           #   InfiniStore (RDMA)
│   └── maru.yaml                  #   Maru CXL shared memory
└── README.md                      #   This file
```
