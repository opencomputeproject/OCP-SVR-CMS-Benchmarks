#!/bin/bash

#################################################################################################
# OCP SRV CMS - Intel MLC Entrypoint
#
# Orchestrates the benchmark run:
#   1. Collect system hardware/software BOM
#   2. Run mlc.sh (the existing benchmark, unmodified)
#   3. Generate HTML report and results tarball
#
# mlc.sh handles its own argument parsing, topology checks, hugepage management,
# start/end banners, and MLC test execution internally.
#################################################################################################

source /opt/cms-utils/cms_common.sh

CMS_SCRIPT_NAME="intel-mlc"
CMS_VERSION="0.2.0"

cd results

# --- 1. Collect system BOM before the benchmark ---
cms_log_info "Collecting system information before benchmark..."
cms_collect_sysinfo ./sysinfo

# --- 2. Run the MLC benchmark (passes all env vars through as CLI args) ---
cms_log_info "Starting MLC benchmark..."
.././mlc.sh $CXL_NUMA_NODE $DRAM_NUMA_NODE $SOCKET $LOW_VERBOSITY $MID_VERBOSITY $HIGH_VERBOSITY $LOADED_LATENCY $SINGLE_THREADED $ENABLE_512_AVX
mlc_exit=$?

# --- 3. Generate report from whatever mlc.sh produced ---
# mlc.sh writes its own output directory (mlc.sh.<hostname>.<date>/) with CSV files.
# Find the most recent output directory it created.
MLC_OUTPUT_DIR=$(find . -maxdepth 1 -type d -name 'mlc.sh.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)

if [ -n "${MLC_OUTPUT_DIR}" ] && [ -d "${MLC_OUTPUT_DIR}" ]; then
    # Copy sysinfo into the MLC output directory so the report has it
    cp -r ./sysinfo "${MLC_OUTPUT_DIR}/sysinfo" 2>/dev/null || true

    # Look for any CSV results to feed the report
    MLC_CSV=$(find "${MLC_OUTPUT_DIR}" -name '*.csv' -type f | head -1)
    cms_generate_report "${MLC_OUTPUT_DIR}" intel-mlc "${MLC_CSV:-}"
else
    cms_log_warn "No MLC output directory found. Generating report from results root."
    cms_generate_report . intel-mlc ""
fi

cms_log_info "MLC benchmark complete (exit code: ${mlc_exit})"
exit ${mlc_exit}
