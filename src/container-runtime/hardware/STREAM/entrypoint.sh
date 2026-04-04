#!/bin/bash

#################################################################################################
# OCP SRV CMS - STREAM Benchmark Entrypoint
#
# Orchestrates the benchmark run:
#   1. Archive any previous run data
#   2. Collect system hardware/software BOM
#   3. Run STREAM or STREAM scaling, capturing output
#   4. Parse results into standardized CSV via parse_results.py
#   5. Generate HTML report and results tarball
#################################################################################################

source /opt/cms-utils/cms_common.sh

CMS_SCRIPT_NAME="stream"
CMS_VERSION="0.1.0"

RAW_OUTPUT="raw_results.txt"
RESULTS_DIR="/opt/stream/results"

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

cd "${RESULTS_DIR}"

# --- 1. Collect system BOM before the benchmark ---
cms_log_info "Collecting system information before benchmark..."
cms_collect_sysinfo ./sysinfo

# --- 2. Run the STREAM benchmark, capture output while preserving console ---
if [ "$BENCHMARK" = 'stream' ]; then
	cms_log_info "Running STREAM benchmark..."
	numactl $STREAM_CPU_NODE_BIND .././stream_c.exe $STREAM_NUMA_NODES $STREAM_NUM_LOOPS $STREAM_ARRAY_SIZE $STREAM_OFFSET $STREAM_MALLOC $STREAM_AUTO_ARRAY_SIZE 2>&1 | tee "${RAW_OUTPUT}"
	bench_exit=${PIPESTATUS[0]}

elif [ "$BENCHMARK" = 'scaling' ]; then
	cms_log_info "Running STREAM scaling benchmark..."
	.././run-stream-scaling.sh $SCALING_TEST $SCALING_CXL_NODE $SCALING_DRAM_NODE $SCALING_NUM_TIMES $SCALING_ARRAY_SIZE 2>&1 | tee "${RAW_OUTPUT}"
	bench_exit=${PIPESTATUS[0]}

else
	cms_log_error "BENCHMARK not set. Set BENCHMARK to 'stream' or 'scaling' in .env"
	bench_exit=1
fi

# --- 3. Parse results into standardized CSV ---
if [ -f "${RAW_OUTPUT}" ]; then
	cms_log_info "Parsing STREAM results into CSV..."
	python3 /opt/stream/parse_results.py "${RESULTS_DIR}" || \
		cms_log_warn "Results parser returned non-zero"
fi

# --- 4. Generate report ---
cms_generate_report . stream || true

cms_log_info "STREAM benchmark complete (exit code: ${bench_exit})"
exit ${bench_exit}
