#!/bin/bash
#################################################################################################
# Resolve an Apache Cassandra release version for a build.
#
# Usage: ./resolve_version.sh <version>
#
#   x.y.z   printed unchanged (pinned release)
#   x.y     newest x.y.z release in that series, e.g. "5.0" -> "5.0.9"
#   latest  newest release overall
#
# Versions are read from the Apache release listings (current releases first, then the archive).
#################################################################################################

set -e -o pipefail

VERSION="${1:-latest}"

if [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${VERSION}"
    exit 0
fi

if [ "${VERSION}" = "latest" ]; then
    pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
elif [[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
    pattern="^${VERSION//./\\.}\.[0-9]+$"
else
    echo "[ERROR] Unrecognized Cassandra version '${VERSION}' (expected x.y.z, x.y or latest)" >&2
    exit 1
fi

for listing in https://downloads.apache.org/cassandra/ https://archive.apache.org/dist/cassandra/; do
    resolved=$(curl -fsSL "${listing}" 2>/dev/null \
                 | grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+/"' \
                 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
                 | grep -E "${pattern}" \
                 | sort -V \
                 | tail -1) || true
    if [ -n "${resolved}" ]; then
        echo "${resolved}"
        exit 0
    fi
done

echo "[ERROR] Could not resolve Cassandra version '${VERSION}'" >&2
exit 1
