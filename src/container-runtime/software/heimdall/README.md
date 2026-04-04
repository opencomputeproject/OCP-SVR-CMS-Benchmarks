# Heimdall Benchmark Suite — Container Runtime

A containerized version of the [Heimdall](https://github.com/awesome-cxl/heimdall) heterogeneous memory benchmark suite, following the [OCP-SVR-CMS-Benchmarks](https://github.com/opencomputeproject/OCP-SVR-CMS-Benchmarks) container-runtime pattern.

The container inherits from `ocp-cms-base:latest` which provides Ubuntu 24.04, build tools, NUMA/CXL utilities, and the CMS common library. A single `EDITME.env` file controls which benchmark is run and with what parameters.

## Directory Structure

```
heimdall/
├── Dockerfile           # FROM ocp-cms-base:latest + heimdall-specific deps
├── docker-compose.yml   # Passes env vars into the container
├── EDITME.env           # ** Single control point ** for benchmark + params
├── entrypoint.sh        # Sources cms_common.sh, orchestrates build → run → report
├── setup_env.sh         # Generates heimdall config files from env vars
└── README.md            # This file
```

## Prerequisites

Build the OCP CMS base image (one time, from the utils directory):

```bash
cd src/container-runtime/utils
docker build -t ocp-cms-base:latest -f Dockerfile.base .
```

## Quick Start

```bash
# 1. Configure
cp EDITME.env .env
nano .env                # set BENCHMARK, CONFIG, and tune parameters

# 2. Build the container
docker compose build

# 3. Run
docker compose up

# 4. Check results
ls ./results/
```

## CMS Common Library Integration

The entrypoint script sources `/opt/cms-utils/cms_common.sh` (provided by the base image) and uses its functions throughout the benchmark lifecycle:

| CMS Function | When Used |
|---|---|
| `cms_trap_ctrlc` | Container startup — graceful Ctrl-C handling |
| `cms_init_outputs` / `cms_log_stdout_stderr` | Initialize results directory and log capture |
| `cms_display_start_info` / `cms_display_end_info` | Start/end banners with elapsed time |
| `cms_collect_sysinfo` | Before benchmark — full hardware/software BOM collection |
| `cms_query_topology` | Before benchmark — log sockets, cores, NUMA nodes, CXL devices |
| `cms_set_performance_governor` / `cms_restore_governor` | Set/restore CPU frequency governor |
| `cms_generate_report` | After benchmark — produce HTML report with sysinfo + results |
| `cms_package_results` | After benchmark — create results tarball |

## What Gets Collected

Every run automatically produces:

- **sysinfo/** — Full hardware BOM (BIOS, CPU, memory, NUMA, CXL, PCI, network, storage, kernel, packages, GPU, power/thermal) in both `.txt` and `.json` formats
- **SUMMARY.txt** — One-page system overview
- **sysinfo.json** — Combined machine-readable BOM
- **\*_report.html** — Self-contained HTML report with collapsible sysinfo categories and benchmark results
- **\*_results.tar.gz** — Archive of all raw output

## How It Works

1. **`entrypoint.sh`** sources `cms_common.sh`, runs the CMS initialization sequence (sysinfo collection, topology query, governor setup), then delegates to heimdall.

2. **`setup_env.sh`** generates heimdall's required config files (`self.env` and `$(hostname).env`) from container environment variables. If `BW_*` or `CACHE_*` variables are set, it generates custom YAML batch files that override heimdall's defaults.

3. **`entrypoint.sh`** calls `uv run heimdall bench` with the selected `BENCHMARK`, `CONFIG`, and `ACTION`, then copies results, generates the HTML report, and creates the tarball.

## Available Benchmarks

### `basic` — Basic Memory Performance

| CONFIG | Description |
|--------|-------------|
| `bw` | Bandwidth vs Latency sweep (job 100) |
| `cache` | Cache latency heatmap via kernel module (job 200) |
| `all` | Run both bw and cache |

### `llm` — LLM Inference Benchmarks

| CONFIG | Description |
|--------|-------------|
| `pytorch` | Meta LLaMA 3 with raw PyTorch |
| `llamacpp` | llama.cpp with quantized GGUF model |
| `vllm_cpu` | vLLM serving engine (CPU mode) |
| `vllm_gpu` | vLLM serving engine (GPU mode) |

First run requires `ACTION=all`. Set `HUGGING_FACE_HUB_TOKEN` for gated model access.

### `lockfree` — Lock-Free Data Structure Benchmarks

| CONFIG | Description |
|--------|-------------|
| `basic` | Minimal test (any 2-NUMA system) |
| `agamotto` | Full DIMM/CXL sweep on agamotto-class systems |
| `titan` | Full DIMM/CXL sweep on titan-class systems |

First run requires `ACTION=all` to compile folly, junction, etc.

## Actions

| ACTION | What it does |
|--------|--------------|
| `build_and_run` | Build the benchmark binary, then run it (default) |
| `build` | Compile only |
| `run` | Run only (binary must already be built) |
| `install` | Install external dependencies only |
| `all` | Full pipeline: install → build → run |

## Example: Sweep DRAM node 0 and CXL node 2

```bash
BENCHMARK=basic
CONFIG=bw
ACTION=build_and_run

BW_THREAD_NUM_TYPE=1
BW_NUMA_NODE_ARRAY=0,2
BW_CORE_SOCKET_ARRAY=0
BW_LOADSTORE_ARRAY=0,1
BW_BUFFER_SIZE_MB=512
```

## Important Notes

- **Base image required** — Build `ocp-cms-base:latest` before building this container.
- The container runs in **privileged mode** for NUMA access, MSR writes, huge pages, and kernel module loading.
- The `basic` benchmark builds at runtime because the binary encodes core-per-socket and socket count as compile-time constants.
- For `llm` and `lockfree`, first-time `ACTION=all` can take 15–60+ minutes. Use `ACTION=run` for subsequent runs within the same container lifecycle.
- Set `CMS_VERBOSITY=1` in the env file to enable debug logging from the CMS common library.

## License

The heimdall benchmark suite is released under the MIT License. See the [heimdall repository](https://github.com/awesome-cxl/heimdall) for details.
