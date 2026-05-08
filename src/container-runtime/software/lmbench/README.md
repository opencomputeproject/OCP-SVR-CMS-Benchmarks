# LMBench + LMCache — Two-Container OCP CMS Benchmark

OCP SRV CMS container wrapper for [LMBench](https://github.com/LMCache/LMBench)
with a separated [LMCache](https://github.com/LMCache/LMCache) serving engine.
Benchmarks LLM inference serving performance across configurable KV cache
backends, workload generators, and deployment topologies.

## Architecture

```
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│  lmcache-server                  │    │  lmbench-client                  │
│  (System Under Test)             │    │  (Load Generator)                │
│                                  │    │                                  │
│  vLLM inference engine           │    │  LMBench run-bench.py            │
│  + LMCache KV cache layer        │    │  (workload generators only)      │
│                                  │    │                                  │
│  Exposes: :30080/v1/...          │◄───│  Fires HTTP requests at server   │
│                                  │    │  Collects JSON results           │
│  KV cache backend (swappable):   │    │                                  │
│  • none (plain vLLM baseline)    │    │  OCP CMS integration:            │
│  • cpu_offload                   │    │  • sysinfo BOM collection        │
│  • maru (CXL shared memory)      │    │  • parse_results.py → JSON/CSV   │
│  • redis / mooncake / infinistore│    │  • generate_report.sh → HTML     │
│  • disk / lmserver / custom      │    │                                  │
└──────────────────────────────────┘    └──────────────────────────────────┘
```

## Prerequisites

### Build the OCP CMS base image (one-time)

```bash
cd src/container-runtime/utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

### Hardware

**CPU mode** (`LMBENCH_DEVICE=cpu`):
- x86_64 CPU with AVX512 or AVX2
- DRAM: model weights + KV cache (Llama 8B BF16 ≈ 16GB + `VLLM_CPU_KVCACHE_SPACE` GB)
- For Maru: CXL device with `/dev/dax*` access

**GPU mode** (`LMBENCH_DEVICE=gpu`, requires `--profile gpu`):
- NVIDIA GPU(s) with CUDA drivers + `nvidia-container-toolkit`

### Authentication

```bash
HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

For gated models (Llama, Mistral), you must also accept the model license at
the model's HuggingFace page before the token will work.

## Quick Start

```bash
cd src/container-runtime/software/lmbench
cp EDITME.env .env
nano .env   # set HF_TOKEN, choose LMCACHE_BACKEND

# CPU mode
docker compose build && docker compose up

# GPU mode
docker compose --profile gpu build && docker compose --profile gpu up
```

## Swapping Backends

Change `LMCACHE_BACKEND` in `.env`, rebuild the server only:

```bash
docker compose build lmcache-server && docker compose up
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

### Host Setup

```bash
# Install Maru on the host (not in containers)
git clone https://github.com/xcena-dev/maru && cd maru && ./install.sh

# Start maru-server
maru-server
```

### DAX Device Mapping (CRITICAL)

Docker containers **cannot** see `/dev/dax*` devices by default, even with
`privileged: true`. You must explicitly map each DAX device in
`docker-compose.yml` under the server service:

```yaml
  lmcache-server:
    ...
    devices:
      - /dev/dax0.0:/dev/dax0.0
      - /dev/dax12.0:/dev/dax12.0
```

Find your DAX devices with `ls /dev/dax*` on the host. The device paths
must match exactly — Maru's server allocates shared memory regions on
specific DAX devices and the container must access those same paths.

**If you skip this step**, you'll see:
```
OSError: [Errno 6] No such device or address: '/dev/dax12.0'
RuntimeError: Failed to connect MaruHandler to maru://localhost:5555
```

### Container Configuration

```bash
LMCACHE_BACKEND=maru
LMCACHE_MARU_HOST=localhost
LMCACHE_MARU_PORT=5555
LMCACHE_MARU_POOL_SIZE=4    # GiB per vLLM instance
```

See `examples/maru.env` for a complete ready-to-use configuration.

## CPU Mode: Important Notes

Running vLLM on CPU requires the `vllm-cpu` PyPI package, which is separate
from the GPU `vllm` package. The Dockerfile handles this automatically, but
there are several gotchas documented here for troubleshooting.

### vllm vs vllm-cpu

`pip install vllm` **always** installs the GPU wheel (CUDA binaries, GPU
platform detection). `pip install vllm-cpu` installs the CPU wheel (AVX512/
AVX2 compiled `_C.so`, CPU platform detection). They cannot coexist cleanly
because they both install into the `vllm` module namespace.

The Dockerfile solves this by installing GPU dependencies first (because
`lmcache` transitively requires `vllm`), then force-reinstalling `vllm-cpu`
last with `--no-deps` so it overwrites the GPU code without re-resolving
dependencies.

### LMCache CPU Platform Patches

LMCache was not designed for CPU-only inference. Two runtime patches are
applied by `server-entrypoint.sh` when `LMBENCH_DEVICE=cpu`:

1. **`get_vllm_torch_dev()`** — LMCache only checks for CUDA/XPU/HPU
   platforms. The patch adds a CPU branch that returns a fake torch device
   module with stub methods (`current_device`, `set_device`, etc.).

2. **`CreateGPUConnector()`** — LMCache's GPU connector creates CUDA
   streams internally. The patch routes CPU mode to `MockGPUConnector`
   which bypasses all GPU machinery. KV cache offloading to Maru/Redis/etc.
   still works through the storage backend layer.

### Tensor Parallelism on CPU

`VLLM_CPU_TP=2` with `--distributed-executor-backend mp` currently fails
due to gloo TCP transport issues with `network_mode: host`. The gloo
backend resolves the container hostname to `127.0.1.1` instead of
`127.0.0.1`, causing `Connection reset by peer` on the distributed barrier.

**Workaround**: Use `VLLM_CPU_TP=1` (default). Single-process mode uses
all available cores via OpenMP.

### Thread Binding for NUMA

For multi-socket systems with discontinuous core numbering:

```bash
# Example: 2-socket, 384 cores, socket 0 = 0-95,192-287, socket 1 = 96-191,288-383
VLLM_CPU_OMP_THREADS_BIND=0-95,192-287|96-191,288-383
```

This only applies when `VLLM_CPU_TP=2` is working. With TP=1, use `auto`.

## Deployment: Single Machine

Both containers on the same host. Client shares server's network namespace.

```bash
docker compose up        # CPU
docker compose --profile gpu up   # GPU
```

## Deployment: Split Across Two Machines

Server on Machine A (SUT), client on Machine B (load generator).

**Machine A:**
```bash
docker compose up lmcache-server
# Verify: curl http://localhost:30080/v1/models
```

**Machine B:**
```bash
LMBENCH_SERVER_URL=http://<machine-a-ip>:30080 \
  docker compose -f docker-compose.yml -f docker-compose.client-only.yml \
  up lmbench-client
```

Machine A must expose port 30080. Remote backends (Maru, Redis, etc.)
only need to be reachable from Machine A.

## Workloads

Set `LMBENCH_WORKLOADS` to a comma-separated list: `synthetic`, `sharegpt`,
`agentic`, `random`, `vllm_benchmark`, `strict_synthetic`, `trace_replayer`.

See `EDITME.env` for all tunable parameters per workload.

Example configurations are in `examples/`:
- `maru.env` — Maru backend, minimal config
- `maru-synthetic.env` — Maru + synthetic workload, tuned for CPU
- `maru-vllmbench.env` — Maru + vLLM benchmark, QPS sweep

## Output

```
results/
├── lmbench-<suite>_report.html       # CMS HTML report
├── results_lmbench_<suite>.json      # Normalized JSON
├── results_lmbench_<suite>.csv       # Normalized CSV
├── sysinfo/                          # Hardware/software BOM
├── config/                           # Reproducibility artifacts
├── lmbench_results/                  # Raw LMBench JSON output
└── lmbench-<suite>_results.tar.gz   # Complete archive
```

## Troubleshooting

**"Failed to infer device type":**
GPU vllm is installed instead of vllm-cpu. Check `pip list | grep vllm`
inside the container. Both `vllm` and `vllm-cpu` should be listed, and
`python3 -c "import importlib.metadata; print(importlib.metadata.version('vllm'))"`
should show a version ending in `+cpu`.

**"No such device or address: /dev/daxN.N":**
DAX devices not mapped into the container. Add `devices:` entries to
`docker-compose.yml`. See "DAX Device Mapping" section above.

**"Unsupported device platform for LMCache engine":**
LMCache CPU patch didn't apply. Check server logs for `[SERVER] Patched
LMCache utils.py` message. If missing, the patch target string may have
changed in a newer LMCache version.

**"No supported connector found for the current platform":**
GPU connector patch didn't apply. Check for `[SERVER] Patched
gpu_connector/__init__.py` in logs.

**Healthcheck timeout / "dependency failed to start":**
vLLM takes 5-10+ minutes to load models on CPU. The healthcheck has a
5-minute start period and retries for ~60 minutes. Check server logs
with `docker compose logs lmcache-server -f`.

**"Connection reset by peer" with TP=2:**
Gloo transport bug with `network_mode: host`. Use `VLLM_CPU_TP=1`.

**HuggingFace 401/403 errors:**
401 = token not being passed. Check `HF_TOKEN` in `.env`.
403 = token works but you haven't accepted the model license. Visit the
model page on HuggingFace and click "Request access".

**"libiomp is not found in LD_PRELOAD":**
Install `intel-openmp` via pip (included in Dockerfile).

## File Inventory

```
lmbench/
├── EDITME.env                       # All configuration — copy to .env
├── Dockerfile.server                # Server: vLLM + LMCache + Maru
├── Dockerfile.client                # Client: LMBench + CMS reporting
├── docker-compose.yml               # Single-machine orchestration
├── docker-compose.client-only.yml   # Split-machine override
├── server-entrypoint.sh             # Config resolution, patches, vLLM launch
├── client-entrypoint.sh             # Server wait, workloads, reporting
├── setup_env.sh                     # Generates run-bench.yaml from env
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
│   ├── maru-synthetic.env
│   └── maru-vllmbench.env
└── README.md
```
