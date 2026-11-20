##################################################################################################
# OCP SRV CMS - Redis + Memtier Benchmark Container
#
# Inherits from ocp-cms-base:latest which provides all common system packages,
# the cms_common.sh library, collect_sysinfo.sh, and generate_report.sh at /opt/cms-utils/.
#
# This layer adds: redis-server/redis-cli and memtier_benchmark, both built from source.
#
# REDIS_VERSION / MEMTIER_VERSION default to "latest", which resolves to the newest stable
# x.y.z release tag at build time. The resolved versions are recorded in versions.txt and
# copied into every results directory. Pass a specific tag to pin, e.g.:
#   docker compose build --build-arg REDIS_VERSION=8.2.2
#
# If the base image is not available, build it first:
#   cd ../../utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
##################################################################################################

FROM ocp-cms-base:latest

ARG REDIS_VERSION=latest
ARG MEMTIER_VERSION=latest

# Benchmark-specific packages
RUN apt-get update && apt-get install -y \
    git \
    libevent-dev \
    libssl-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /opt/redis-bench

# Resolve "latest" to the newest stable release tag (x.y.z only, no rc/milestone tags)
COPY resolve_tag.sh /opt/redis-bench/resolve_tag.sh
RUN chmod +x /opt/redis-bench/resolve_tag.sh

# Build and install redis-server / redis-cli
RUN set -e \
    && tag=$(./resolve_tag.sh https://github.com/redis/redis.git "${REDIS_VERSION}") \
    && echo "[BUILD] redis ${tag}" \
    && git clone --depth 1 --branch "${tag}" https://github.com/redis/redis.git /tmp/redis \
    && make -C /tmp/redis -j"$(nproc)" \
    && make -C /tmp/redis install \
    && rm -rf /tmp/redis \
    && echo "redis=${tag}" >> /opt/redis-bench/versions.txt

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
    && cd /opt/redis-bench \
    && rm -rf /tmp/memtier \
    && echo "memtier_benchmark=${tag}" >> /opt/redis-bench/versions.txt

# Bring over the server config, run script, parser, and entrypoint
COPY redis.conf             /opt/redis-bench/redis.conf
COPY run_redis_memtier.sh   /opt/redis-bench/run_redis_memtier.sh
COPY parse_results.py       /opt/redis-bench/parse_results.py
COPY entrypoint.sh          /opt/redis-bench/entrypoint.sh

# Make them executable
RUN chmod +x run_redis_memtier.sh parse_results.py entrypoint.sh

# Create results and data directories
RUN mkdir -p /opt/redis-bench/results /opt/redis-bench/data

# Expose redis port (for internal container use)
EXPOSE 6379

# Default command
ENTRYPOINT ["./entrypoint.sh"]
