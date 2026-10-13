##################################################################################################
# OCP SRV CMS - Cassandra + cassandra-stress Benchmark Container
#
# Inherits from ocp-cms-base:latest which provides all common system packages,
# the cms_common.sh library, collect_sysinfo.sh, and generate_report.sh at /opt/cms-utils/.
#
# This layer adds: OpenJDK 17 and the Apache Cassandra binary release, which includes
# cassandra-stress (tools/bin).
#
# CASSANDRA_VERSION defaults to "5.0", which resolves to the newest 5.0.x release at build
# time ("latest" = newest release overall, or pass x.y.z to pin). The release tarball is
# verified against its published SHA-512 checksum. The resolved version is recorded in
# versions.txt and copied into every results directory. Example:
#   docker compose build --build-arg CASSANDRA_VERSION=5.0.9
#
# If the base image is not available, build it first:
#   cd ../../utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
##################################################################################################

FROM ocp-cms-base:latest

ARG CASSANDRA_VERSION=5.0

# Benchmark-specific packages
RUN apt-get update && apt-get install -y \
    openjdk-17-jre-headless \
    python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /opt/cassandra-bench

# Resolve the Cassandra release version
COPY resolve_version.sh /opt/cassandra-bench/resolve_version.sh
RUN chmod +x /opt/cassandra-bench/resolve_version.sh

# Download, verify, and install the Cassandra binary release to /opt/cassandra
RUN set -e \
    && ver=$(./resolve_version.sh "${CASSANDRA_VERSION}") \
    && echo "[BUILD] cassandra ${ver}" \
    && tarball="apache-cassandra-${ver}-bin.tar.gz" \
    && for mirror in https://downloads.apache.org/cassandra https://archive.apache.org/dist/cassandra; do \
           curl -fsSL -o "/tmp/${tarball}" "${mirror}/${ver}/${tarball}" \
           && curl -fsSL -o "/tmp/${tarball}.sha512" "${mirror}/${ver}/${tarball}.sha512" \
           && break; \
       done \
    && echo "$(awk '{print $1}' "/tmp/${tarball}.sha512")  /tmp/${tarball}" | sha512sum -c - \
    && mkdir -p /opt/cassandra \
    && tar -xzf "/tmp/${tarball}" -C /opt/cassandra --strip-components=1 \
    && rm -f "/tmp/${tarball}" "/tmp/${tarball}.sha512" \
    && echo "cassandra=${ver}" >> /opt/cassandra-bench/versions.txt

ENV CASSANDRA_HOME=/opt/cassandra
ENV PATH="/opt/cassandra/bin:/opt/cassandra/tools/bin:${PATH}"

# Bring over the configuration, profile, run script, parser, and entrypoint
COPY cassandra-overrides.yaml   /opt/cassandra-bench/cassandra-overrides.yaml
COPY configure_cassandra.py     /opt/cassandra-bench/configure_cassandra.py
COPY blogpost.yaml              /opt/cassandra-bench/blogpost.yaml
COPY run_cassandra_stress.sh    /opt/cassandra-bench/run_cassandra_stress.sh
COPY parse_results.py           /opt/cassandra-bench/parse_results.py
COPY entrypoint.sh              /opt/cassandra-bench/entrypoint.sh

# Make them executable
RUN chmod +x configure_cassandra.py run_cassandra_stress.sh parse_results.py entrypoint.sh

# Create results and data directories
RUN mkdir -p /opt/cassandra-bench/results /data/cassandra

# Expose CQL native port (for internal container use)
EXPOSE 9042

# Default command
ENTRYPOINT ["./entrypoint.sh"]
