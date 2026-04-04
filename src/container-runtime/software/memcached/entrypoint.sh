#!/bin/bash

#################################################################################################
# OCP SRV CMS - Memcached Benchmark Entrypoint
#
# Orchestrates the benchmark run:
#   1. Archive any previous run data
#   2. Run the memcached benchmark (run_memcached.sh handles CMS lifecycle internally)
#   3. Parse results into standardized JSON + CSV
#################################################################################################

RESULTS_DIR="/opt/memcached-bench/results"

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
# Run the memcached benchmark
# (run_memcached.sh sources cms_common.sh and handles sysinfo, topology,
#  memcached start/stop, memaslap execution, and report generation)
# -------------------------------------------------------------------------
cd "${RESULTS_DIR}"
/opt/memcached-bench/run_memcached.sh
bench_exit=$?

# -------------------------------------------------------------------------
# Parse results into standardized JSON + CSV
# (run_memcached.sh already writes raw_results.txt and a basic results.csv)
# -------------------------------------------------------------------------
if [ -f "${RESULTS_DIR}/raw_results.txt" ]; then
    echo "[INFO] Parsing memcached results into JSON..."
    python3 /opt/memcached-bench/parse_results.py "${RESULTS_DIR}" || \
        echo "[WARN] Results parser returned non-zero"
fi

exit ${bench_exit}
