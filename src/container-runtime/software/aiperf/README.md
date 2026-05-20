# AIPerf + LMCache + Maru — Three-Container OCP CMS Benchmark

OCP SRV CMS container wrapper for [AIPerf](https://github.com/ai-dynamo/aiperf)
with a separated [LMCache](https://github.com/LMCache/LMCache) serving engine
and containerized [Maru](https://github.com/xcena-dev/maru) CXL shared memory
KV cache engine. Benchmarks LLM inference serving performance with KV cache
backed by CXL shared memory, fully containerized end-to-end.

## Architecture

```
┌────────────────────────┐  ┌──────────────────────────┐  ┌─────────────────────┐
│  maru                  │  │  lmcache-server-gpu      │  │  aiperf-client      │
│  (CXL KV Cache Engine) │  │  (System Under Test)     │  │  (Load Generator)   │
│                        │  │                          │  │                     │
│  maru-resource-manager │  │  vLLM inference engine   │  │  AIPerf profile     │
│  (C++, port 9850)      │  │  + LMCache KV cache      │  │  (HTTP requests)    │
│  Manages DAX pool      │  │                          │  │                     │
│                        │  │  Exposes: :30080/v1/...  │◄─│  Fires requests     │
│  maru-server           │  │                          │  │  Collects JSON/CSV  │
│  (Python, port 5555)   │◄─│  KV cache backend:       │  │                     │
│  KV metadata           │  │  maru://localhost:5555   │  │  OCP CMS reporting  │
│                        │  │                          │  │                     │
│  /dev/dax* ◄───────────│──│─ zero-copy mmap ─────────│  │                     │
└────────────────────────┘  └──────────────────────────┘  └─────────────────────┘
         ▲                           ▲
         │                           │
    CXL Device               NVIDIA GPU(s)
    (/dev/dax*)
```

Startup order: **maru** → **lmcache-server-gpu** → **aiperf-client**

## Prerequisites

### Build the OCP CMS base image (one-time)

```bash
cd src/container-runtime/utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Hardware

- NVIDIA GPU(s) with CUDA drivers + `nvidia-container-toolkit`
- For Maru: CXL device with `/dev/dax*` access

### Authentication

```bash
HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

For gated models (Llama, Mistral), you must also accept the model license at
the model's HuggingFace page before the token will work.

## Quick Start

```bash
cd src/container-runtime/software/aiperf
cp EDITME.env .env
nano .env   # set HF_TOKEN, choose LMCACHE_BACKEND

docker compose build && docker compose up
```

## Swapping Backends

Change `LMCACHE_BACKEND` in `.env`, rebuild the server only:

```bash
docker compose build lmcache-server-gpu && docker compose up
```

| `LMCACHE_BACKEND=` | What it does | Extra config |
|---|---|---|
| `none` | Plain vLLM, no caching (baseline) | — |
| `cpu_offload` | KV cache → CPU RAM (default) | — |
| `disk` | KV cache → CPU RAM + local disk | — |
| `redis` | KV cache → Redis | `LMCACHE_REMOTE_HOST`, `LMCACHE_REMOTE_PORT` |
| `lmserver` | KV cache → LMCache server | `LMCACHE_REMOTE_HOST`, `LMCACHE_REMOTE_PORT` |
| `mooncake` | KV cache → Mooncake store | `LMCACHE_REMOTE_HOST/PORT`, `LMCACHE_MOONCAKE_*` |
| `infinistore` | KV cache → InfiniStore (RDMA) | `LMCACHE_REMOTE_HOST/PORT` |
| `maru` | KV cache → Maru CXL shared memory | `LMCACHE_MARU_HOST/PORT/POOL_SIZE` + DAX devices |
| `custom` | Your own YAML | `LMCACHE_CONFIG_FILE_CONTENT` (base64) |

## Maru (CXL Shared Memory)

[Maru](https://github.com/xcena-dev/maru) stores KV cache in CXL shared memory
via `/dev/dax*` devices. Zero-copy reads, no network serialization.

Maru is fully containerized in this benchmark — no host installation required.
The `maru` container runs both the resource manager (C++ binary managing the
DAX memory pool) and the metadata server (Python, managing KV entries).

### DAX Device Mapping (CRITICAL)

Docker containers **cannot** see `/dev/dax*` devices by default, even with
`privileged: true`. You must explicitly map each DAX device in
`docker-compose.yml` under **both** the `maru` and `lmcache-server-gpu`
services:

```yaml
  maru:
    ...
    devices:
      - /dev/dax0.0:/dev/dax0.0
      - /dev/dax12.0:/dev/dax12.0

  lmcache-server-gpu:
    ...
    devices:
      - /dev/dax0.0:/dev/dax0.0
      - /dev/dax12.0:/dev/dax12.0
```

Both containers need the same DAX devices — Maru's resource manager
initializes the shared memory regions, and LMCache's handler mmaps the
same regions for zero-copy KV cache access.

Find your DAX devices with `ls /dev/dax*` on the host.

**If you skip this step**, you'll see:
```
[MARU] ERROR: No /dev/dax* devices found in container.
```
or from the vLLM/LMCache side:
```
OSError: [Errno 6] No such device or address: '/dev/dax12.0'
```

### Container Configuration

```bash
LMCACHE_BACKEND=maru
LMCACHE_MARU_HOST=localhost
LMCACHE_MARU_PORT=5555
LMCACHE_MARU_POOL_SIZE=4    # GiB per vLLM instance
```

See `examples/maru.env` for a complete ready-to-use configuration.

## Deployment: Single Machine

Both containers on the same host. Client shares server's network namespace.

```bash
docker compose up
```

## Deployment: Split Across Two Machines

Server on Machine A (SUT), client on Machine B (load generator).

**Machine A:**
```bash
docker compose up lmcache-server-gpu
# Verify: curl http://localhost:30080/v1/models
```

**Machine B:**
```bash
AIPERF_SERVER_URL=http://<machine-a-ip>:30080 \
  docker compose -f docker-compose.yml -f docker-compose.client-only.yml \
  up aiperf-client
```

Machine A must expose port 30080. Remote backends (Maru, Redis, etc.)
only need to be reachable from Machine A.

## AIPerf Configuration

### Load Pattern

AIPerf supports two modes — set one or the other:

**Concurrency mode** (default): N virtual users sending requests simultaneously.
```bash
AIPERF_CONCURRENCY=10
AIPERF_REQUEST_COUNT=100
```

**Request-rate mode**: Fixed requests per second.
```bash
AIPERF_REQUEST_RATE=32
AIPERF_REQUEST_COUNT=100
```

### Sequence Lengths

Control input/output token lengths for synthetic workloads:
```bash
AIPERF_ISL=1024    # Input sequence length (tokens)
AIPERF_OSL=512     # Output sequence length (tokens)
```

### Datasets

```bash
# Synthetic (default — random prompts)
# No extra config needed

# ShareGPT (real conversational data)
AIPERF_PUBLIC_DATASET=sharegpt

# Custom trace file
AIPERF_INPUT_FILE=/data/traces/my_trace.jsonl
AIPERF_CUSTOM_DATASET_TYPE=mooncake_trace
AIPERF_FIXED_SCHEDULE=true
```

### Multi-Run Confidence

Run the benchmark N times and get aggregate statistics with confidence intervals:
```bash
AIPERF_NUM_PROFILE_RUNS=3
```

### Goodput SLOs

Measure what fraction of requests meet latency targets:
```bash
AIPERF_GOODPUT_TTFT=370        # TTFT ≤ 370ms
AIPERF_GOODPUT_LATENCY=648     # Request latency ≤ 648ms
```

## Output

```
results/
├── aiperf-<suite>_report.html       # CMS HTML report
├── results_aiperf_<suite>.json      # Normalized JSON
├── results_aiperf_<suite>.csv       # Normalized CSV
├── sysinfo/                         # Hardware/software BOM
├── config/                          # Reproducibility artifacts
│   └── lmcache_backend_info.json    # Backend metadata
├── aiperf_results/                  # Raw AIPerf output
│   └── <model>-<endpoint>-<mode>N/
│       ├── profile_export_aiperf.json
│       ├── profile_export_aiperf.csv
│       └── profile_export.jsonl
└── container_results.tar.gz         # Complete archive
```

## Troubleshooting

**"No /dev/dax* devices found in container":**
The maru container requires CXL DAX devices. Uncomment and edit the
`devices:` section in `docker-compose.yml` for both `maru` and
`lmcache-server-gpu`. Run `ls /dev/dax*` on the host.

**"No such device or address: /dev/daxN.N":**
DAX devices not mapped into the container. Add `devices:` entries to
`docker-compose.yml`. See "DAX Device Mapping" section above.

**Maru healthcheck fails / lmcache-server won't start:**
Check maru container logs: `docker compose logs maru -f`. The resource
manager needs root and DAX devices. The metadata server connects to the
resource manager on localhost:9850.

**Healthcheck timeout / "dependency failed to start":**
vLLM takes 2-5+ minutes to load models on GPU. The healthcheck has a
5-minute start period and retries for ~60 minutes. Check server logs
with `docker compose logs lmcache-server-gpu -f`.

**HuggingFace 401/403 errors:**
401 = token not being passed. Check `HF_TOKEN` in `.env`.
403 = token works but you haven't accepted the model license. Visit the
model page on HuggingFace and click "Request access".

**AIPerf "connection refused":**
Client can't reach server. Ensure lmcache-server-gpu healthcheck
passed before client starts. If split-machine, verify `AIPERF_SERVER_URL`
is correct and port 30080 is accessible.

**No AIPerf results found by parser:**
Check `aiperf_results/` directory — AIPerf creates a subdirectory per run.
The parser looks for `profile_export_aiperf.json` recursively.

## File Inventory

```
aiperf/
├── EDITME.env                       # All configuration — copy to .env
├── Dockerfile.maru                  # Maru: resource manager + metadata server
├── Dockerfile.server                # Server: vLLM + LMCache + Maru client (GPU)
├── Dockerfile.client                # Client: AIPerf + CMS reporting
├── docker-compose.yml               # Three-container orchestration
├── docker-compose.client-only.yml   # Split-machine override
├── maru-entrypoint.sh               # Maru startup (RM + metadata server)
├── server-entrypoint.sh             # LMCache config resolution, vLLM launch
├── client-entrypoint.sh             # Server wait, AIPerf run, reporting
├── parse_results.py                 # Normalizes results → CMS JSON/CSV
├── configs/                         # Pre-baked LMCache backend configs
│   ├── cpu_offload.yaml
│   ├── disk.yaml
│   ├── redis.yaml
│   ├── lmserver.yaml
│   ├── mooncake.yaml
│   ├── infinistore.yaml
│   └── maru.yaml
├── examples/                        # Ready-to-use .env files
│   ├── maru.env
│   ├── maru-highload.env
│   └── maru-sharegpt.env
└── README.md
```
