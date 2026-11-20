##################################################################################################
# OCP SRV CMS - Valkey + Memtier Benchmark Container
#
# Inherits from ocp-cms-base:latest which provides all common system packages,
# the cms_common.sh library, collect_sysinfo.sh, and generate_report.sh at /opt/cms-utils/.
#
# This layer adds: valkey-server/valkey-cli and memtier_benchmark, both built from source.
#
# VALKEY_VERSION / MEMTIER_VERSION default to "latest", which resolves to the newest stable
# x.y.z release tag at build time. The resolved versions are recorded in versions.txt and
# copied into every results directory. Pass a specific tag to pin, e.g.:
#   docker compose build --build-arg VALKEY_VERSION=9.0.0
#
# If the base image is not available, build it first:
#   cd ../../utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
##################################################################################################

FROM ocp-cms-base:latest

ARG VALKEY_VERSION=latest
ARG MEMTIER_VERSION=latest

# Benchmark-specific packages
RUN apt-get update && apt-get install -y \
    git \
    libevent-dev \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /opt/valkey-bench

# Resolve "latest" to the newest stable release tag (x.y.z only, no rc/milestone tags)
COPY resolve_tag.sh /opt/valkey-bench/resolve_tag.sh
RUN chmod +x /opt/valkey-bench/resolve_tag.sh

# Build and install valkey-server / valkey-cli
RUN set -e \
    && tag=$(./resolve_tag.sh https://github.com/valkey-io/valkey.git "${VALKEY_VERSION}") \
    && echo "[BUILD] valkey ${tag}" \
    && git clone --depth 1 --branch "${tag}" https://github.com/valkey-io/valkey.git /tmp/valkey \
    && make -C /tmp/valkey -j"$(nproc)" \
    && make -C /tmp/valkey install \
    && rm -rf /tmp/valkey \
    && echo "valkey=${tag}" >> /opt/valkey-bench/versions.txt

# Build and install memtier_benchmark
RUN set -e \
    && tag=$(./resolve_tag.sh https://github.com/RedisLabs/memtier_benchmark.git "${MEMTIER_VERSION}") \
    && echo "[BUILD] memtier_benchmark ${tag}" \
    && git clone --depth 1 --branch "${tag}" https://github.com/RedisLabs/memtier_benchmark.git /tmp/memtier \
    && cd /tmp/memtier \
    && autoreconf -ivf \
    && ./configure \
    && make -j"$(nproc)" \
    && make install \
    && cd /opt/valkey-bench \
    && rm -rf /tmp/memtier \
    && echo "memtier_benchmark=${tag}" >> /opt/valkey-bench/versions.txt

# Bring over the server config, run script, parser, and entrypoint
COPY valkey.conf            /opt/valkey-bench/valkey.conf
COPY run_valkey_memtier.sh  /opt/valkey-bench/run_valkey_memtier.sh
COPY parse_results.py       /opt/valkey-bench/parse_results.py
COPY entrypoint.sh          /opt/valkey-bench/entrypoint.sh

# Make them executable
RUN chmod +x run_valkey_memtier.sh parse_results.py entrypoint.sh

# Create results and data directories
RUN mkdir -p /opt/valkey-bench/results /opt/valkey-bench/data

# Expose valkey port (for internal container use)
EXPOSE 6379

# Default command
ENTRYPOINT ["./entrypoint.sh"]
