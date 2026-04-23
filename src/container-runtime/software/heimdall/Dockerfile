##################################################################################################
# Heimdall Heterogeneous Memory Benchmark Suite - Container Runtime
#
# Inherits from the OCP CMS base image which provides:
#   - Ubuntu 24.04 LTS with build toolchain, NUMA/CXL tools, hardware inspection
#   - /opt/cms-utils/ (cms_common.sh, collect_sysinfo.sh, generate_report.sh)
#
# This layer adds heimdall-specific requirements:
#   - uv (Python project manager)
#   - git + git-lfs (repo clone and LFS model weights)
#   - Lockfree bench dependencies (libboost, libcds)
#   - MSR tools (prefetch/DVFS control)
#   - The full heimdall repo, Python environment, and container orchestration scripts
#
# Based on: https://github.com/awesome-cxl/heimdall
# Following OCP-SVR-CMS-Benchmarks container-runtime pattern
#
# Build (after building the base image):
#   cd src/container-runtime/utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
#   cd src/container-runtime/hardware/heimdall && docker compose build
##################################################################################################

FROM ocp-cms-base:latest

ARG HEIMDALL_VERSION=main
ARG DEBIAN_FRONTEND=noninteractive

# -- Heimdall-specific system packages (not in base image) --------------------
RUN apt-get update && apt-get install -y \
    # Python project manager
    git \
    git-lfs \
    # MSR tools for prefetch / DVFS control
    msr-tools \
    # Lockfree bench C++ dependencies
    libboost-all-dev \
    libcds-dev \
    # Folly build dependencies (required by lockfree bench)
    binutils-dev \
    libdouble-conversion-dev \
    libdwarf-dev \
    libevent-dev \
    libfast-float-dev \
    libgflags-dev \
    libgmock-dev \
    libgtest-dev \
    liblz4-dev \
    libssl-dev \
    libsnappy-dev \
    libsodium-dev \
    libzstd-dev \
    ninja-build \
    openssl \
    sudo \
    zlib1g-dev \
    zstd \
    # Python dev headers (needed for some pip builds)
    python3-dev \
    python3-venv \
    # LLM bench: vLLM CPU build requires gcc-12/g++-12
    gcc-12 \
    g++-12 \
    # LLM bench: vLLM CPU runtime uses tcmalloc via LD_PRELOAD
    libtcmalloc-minimal4t64 \
    && rm -rf /var/lib/apt/lists/*

# -- Install uv (Python package & project manager) ----------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# -- Clone heimdall ------------------------------------------------------------
RUN git clone --branch ${HEIMDALL_VERSION} \
        https://github.com/awesome-cxl/heimdall.git /opt/heimdall && \
    cd /opt/heimdall && \
    git submodule update --init --recursive && \
    git lfs install

WORKDIR /opt/heimdall

# -- Apply container-runtime compatibility patches ----------------------------
COPY patches/ /tmp/heimdall-patches/
RUN git apply --unidiff-zero /tmp/heimdall-patches/*.patch

# -- Install heimdall Python environment via uv -------------------------------
RUN uv sync
# Ensure pip is available inside the venv — heimdall's LLM install scripts
# call bare `pip install` which fails on Ubuntu 24.04 (PEP 668) without it.
RUN uv pip install pip

# -- Create directories the framework expects ---------------------------------
RUN mkdir -p /opt/heimdall/results/basic_performance/100 \
             /opt/heimdall/results/basic_performance/200 \
             /opt/heimdall/benchmark/llm_bench/models \
             /opt/heimdall/benchmark/llm_bench/logs \
             /opt/heimdall/benchmark/lockfree_bench/results

# -- Copy in container-runtime scripts ----------------------------------------
COPY entrypoint.sh      /opt/heimdall/entrypoint.sh
COPY setup_env.sh       /opt/heimdall/setup_env.sh
COPY parse_results.py   /opt/heimdall/parse_results.py
RUN chmod +x entrypoint.sh setup_env.sh parse_results.py

# -- Default results mount point ----------------------------------------------
RUN mkdir -p /opt/heimdall/container_results

ENTRYPOINT ["/opt/heimdall/entrypoint.sh"]
