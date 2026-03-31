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

# Patch clients/memflush.cc - fix NULL pointer checks
RUN sed -i 's/if (opt_servers == false)/if (!opt_servers)/g' \
    /opt/memcached-bench/libmemcached-1.0.18/clients/memflush.cc

# Patch clients/memaslap.c - add global variable definitions
RUN sed -i '/#include "ms_memslap.h"/a \\n/* global structure */\nms_global_t ms_global;\n\n/* global stats information structure */\nms_stats_t ms_stats;\n\n/* global statistic structure */\nms_statistic_t ms_statistic;' \
    /opt/memcached-bench/libmemcached-1.0.18/clients/memaslap.c

# Patch clients/ms_memslap.h - add extern to global variable declarations
RUN sed -i 's/^ms_global_t ms_global;/extern ms_global_t ms_global;/' \
    /opt/memcached-bench/libmemcached-1.0.18/clients/ms_memslap.h \
    && sed -i 's/^ms_stats_t ms_stats;/extern ms_stats_t ms_stats;/' \
    /opt/memcached-bench/libmemcached-1.0.18/clients/ms_memslap.h \
    && sed -i 's/^ms_statistic_t ms_statistic;/extern ms_statistic_t ms_statistic;/' \
    /opt/memcached-bench/libmemcached-1.0.18/clients/ms_memslap.h

# Build libmemcached with memaslap enabled
RUN cd /opt/memcached-bench/libmemcached-1.0.18 \
    && ./configure --enable-memaslap CFLAGS="-fpermissive -Wno-error" CXXFLAGS="-fpermissive -Wno-error" \
    && make -j$(nproc) || true \
    && cp clients/memaslap /usr/local/bin/memaslap 2>/dev/null; \
    make install 2>/dev/null; \
    ldconfig

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
