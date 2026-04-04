#!/bin/bash

#################################################################################################
# OCP SRV CMS - Intel MLC Entrypoint
#
# Orchestrates the benchmark run:
#   1. Archive any previous run data
#   2. Collect system hardware/software BOM
#   3. Run mlc.sh (the existing benchmark, unmodified)
#   4. Parse results into standardized CSV
#   5. Generate HTML report and results tarball
#
# mlc.sh handles its own argument parsing, topology checks, hugepage management,
# start/end banners, and MLC test execution internally.
#################################################################################################

source /opt/cms-utils/cms_common.sh

CMS_SCRIPT_NAME="intel-mlc"
CMS_VERSION="0.2.0"

RESULTS_DIR="/opt/mlc/results"

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

# --- 2. Run the MLC benchmark (passes all env vars through as CLI args) ---
cms_log_info "Starting MLC benchmark..."
.././mlc.sh $CXL_NUMA_NODE $DRAM_NUMA_NODE $SOCKET $LOW_VERBOSITY $MID_VERBOSITY $HIGH_VERBOSITY $LOADED_LATENCY $SINGLE_THREADED $ENABLE_512_AVX
mlc_exit=$?

# --- 3. Parse results into standardized CSV ---
# mlc.sh writes its own output directory (mlc.sh.<hostname>.<date>/) with .txt and .csv files.
# Find the most recent output directory it created.
MLC_OUTPUT_DIR=$(find . -maxdepth 1 -type d -name 'mlc.sh.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)

if [ -n "${MLC_OUTPUT_DIR}" ] && [ -d "${MLC_OUTPUT_DIR}" ]; then
    # Copy sysinfo into the MLC output directory so the report has it
    cp -r ./sysinfo "${MLC_OUTPUT_DIR}/sysinfo" 2>/dev/null || true

    # Run the parser against the MLC output directory
    cms_log_info "Parsing MLC results into CSV..."
    python3 /opt/mlc/parse_results.py "${MLC_OUTPUT_DIR}" || \
        cms_log_warn "Results parser returned non-zero"

    # --- 4. Generate report ---
    cms_generate_report "${MLC_OUTPUT_DIR}" intel-mlc || true
else
    cms_log_warn "No MLC output directory found. Generating report from results root."
    cms_generate_report . intel-mlc "" || true
fi

cms_log_info "MLC benchmark complete (exit code: ${mlc_exit})"
exit ${mlc_exit}
