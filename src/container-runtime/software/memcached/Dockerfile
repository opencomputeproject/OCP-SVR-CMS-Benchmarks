##################################################################################################
# OCP SRV CMS - Memcached Benchmark Container
#
# Inherits from ocp-cms-base:latest which provides all common system packages,
# the cms_common.sh library, collect_sysinfo.sh, and generate_report.sh at /opt/cms-utils/.
#
# This layer adds: memcached server, libmemcached/memaslap client build.
#
# If the base image is not available, build it first:
#   cd ../utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
##################################################################################################

FROM ocp-cms-base:latest

# Benchmark-specific packages
RUN apt-get update && apt-get install -y \
    memcached \
    libevent-dev \
    libsasl2-dev \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /opt/memcached-bench

# Download and extract libmemcached (provides memaslap)
RUN wget https://launchpad.net/libmemcached/1.0/1.0.18/+download/libmemcached-1.0.18.tar.gz \
    && tar -xvzf libmemcached-1.0.18.tar.gz \
    && rm libmemcached-1.0.18.tar.gz

# Patch libmemcached for modern compilers and memaslap build.
# Instead of fragile sed one-liners, use a patch script that verifies each step.
COPY patch_libmemcached.sh /opt/memcached-bench/patch_libmemcached.sh
RUN chmod +x /opt/memcached-bench/patch_libmemcached.sh \
    && /opt/memcached-bench/patch_libmemcached.sh /opt/memcached-bench/libmemcached-1.0.18

# Build libmemcached with memaslap enabled
RUN cd /opt/memcached-bench/libmemcached-1.0.18 \
    && ./configure --enable-memaslap CFLAGS="-fpermissive -Wno-error" CXXFLAGS="-fpermissive -Wno-error" \
    && make -j$(nproc) \
    && cp clients/memaslap /usr/local/bin/memaslap \
    && make install \
    && ldconfig

# Bring over the run script and entrypoint
COPY run_memcached.sh    /opt/memcached-bench/run_memcached.sh
COPY entrypoint.sh       /opt/memcached-bench/entrypoint.sh

# Make them executable
RUN chmod +x run_memcached.sh
RUN chmod +x entrypoint.sh

# Create results directory
RUN mkdir -p /opt/memcached-bench/results

# Expose memcached port (for internal container use)
EXPOSE 11211

# Default command
ENTRYPOINT ["./entrypoint.sh"]
#CMD
