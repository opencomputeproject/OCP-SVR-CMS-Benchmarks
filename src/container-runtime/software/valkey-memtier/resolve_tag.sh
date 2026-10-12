#!/bin/bash
#################################################################################################
# Resolve a git release tag for a build.
#
# Usage: ./resolve_tag.sh <git-repo-url> <version>
#
# If <version> is "latest" (or empty), prints the newest stable x.y.z tag in the repo,
# ignoring release candidates and milestone tags. Otherwise prints <version> unchanged.
#################################################################################################

set -e -o pipefail

REPO="${1:?Usage: $0 <git-repo-url> <version>}"
VERSION="${2:-latest}"

if [ "${VERSION}" != "latest" ]; then
    echo "${VERSION}"
    exit 0
fi

tag=$(git ls-remote --tags --refs "${REPO}" \
        | awk -F/ '{print $NF}' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -1)

if [ -z "${tag}" ]; then
    echo "[ERROR] Could not resolve latest release tag for ${REPO}" >&2
    exit 1
fi

echo "${tag}"
