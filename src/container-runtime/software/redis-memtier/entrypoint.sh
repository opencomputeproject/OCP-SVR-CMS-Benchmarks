#!/bin/bash

#################################################################################################
# OCP SRV CMS - Redis + Memtier Benchmark Entrypoint
#
# Orchestrates the benchmark run:
#   1. Archive any previous run data
#   2. Run the benchmark (run_redis_memtier.sh handles the CMS lifecycle internally,
#      including parsing results before the HTML report is generated)
#################################################################################################

RESULTS_DIR="/opt/redis-bench/results"

# -------------------------------------------------------------------------
# Archive previous run data if the results directory is not empty
# -------------------------------------------------------------------------
_existing_files=$(find "${RESULTS_DIR}" -mindepth 1 -maxdepth 1 -not -name "previous_runs" 2>/dev/null)
if [ -n "${_existing_files}" ]; then
    _archive_ts=$(date '+%Y%m%d-%H%M%S')
    _archive_dir="${RESULTS_DIR}/previous_runs/${_archive_ts}"
    mkdir -p "${_archive_dir}"
    echo "[INFO] Results directory not empty — archiving previous run to previous_runs/${_archive_ts}"
    for _item in "${RESULTS_DIR}"/*; do
        _basename=$(basename "${_item}")
        [ "${_basename}" = "previous_runs" ] && continue
        mv "${_item}" "${_archive_dir}/" 2>/dev/null || true
    done
    echo "[INFO] Archived $(find "${_archive_dir}" -type f | wc -l) files from previous run"
fi

# -------------------------------------------------------------------------
# Run the benchmark
# (run_redis_memtier.sh sources cms_common.sh and handles sysinfo, topology,
#  redis start/stop, memtier phases, result parsing, and report generation)
# -------------------------------------------------------------------------
cd "${RESULTS_DIR}"
/opt/redis-bench/run_redis_memtier.sh
exit $?
