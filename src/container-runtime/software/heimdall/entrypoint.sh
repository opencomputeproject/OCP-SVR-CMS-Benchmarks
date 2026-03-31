#!/usr/bin/env bash
# =============================================================================
# Heimdall Container Entrypoint
#
# Reads BENCHMARK, CONFIG, and ACTION environment variables to determine
# which benchmark to build/install/run using the heimdall CLI.
#
# Integrates with OCP CMS common utilities:
#   - cms_common.sh for logging, banners, topology, sysinfo, reporting
#   - collect_sysinfo.sh for hardware BOM collection
#   - generate_report.sh for HTML report generation
#
# BENCHMARK: basic | llm | lockfree
# CONFIG:    (depends on benchmark, see EDITME.env)
# ACTION:    build_and_run | build | run | install | all
# =============================================================================

# NOTE: We intentionally do NOT use `set -euo pipefail` here.
# Many CMS functions and system queries return non-zero on missing
# hardware, missing tools, or permission issues — those are warnings,
# not fatal errors. The heimdall uv commands are the only ones we
# explicitly check for failure.

# -------------------------------------------------------------------------
# Source the OCP CMS common library
# -------------------------------------------------------------------------
if [ -f /opt/cms-utils/cms_common.sh ]; then
    source /opt/cms-utils/cms_common.sh
else
    echo "[ERROR] CMS common library not found at /opt/cms-utils/cms_common.sh"
    echo "[ERROR] Was the container built FROM ocp-cms-base:latest?"
    exit 1
fi

# Set benchmark identity (used by CMS banners and logging)
CMS_SCRIPT_NAME="heimdall"
CMS_VERSION="1.0.0"

# -------------------------------------------------------------------------
# Read control variables
# -------------------------------------------------------------------------
BENCHMARK="${BENCHMARK:-basic}"
CONFIG="${CONFIG:-bw}"
ACTION="${ACTION:-build_and_run}"
RESULTS_MOUNT="/opt/heimdall/container_results"

# -------------------------------------------------------------------------
# CMS initialization
#
# IMPORTANT: We do NOT call cms_init_outputs here because it does
# rm -rf on CMS_OUTPUT_PATH, which would destroy the Docker volume
# mount point. Instead we just ensure the directory exists and is
# clean of stale files from a previous run.
# -------------------------------------------------------------------------
CMS_OUTPUT_PATH="${RESULTS_MOUNT}"
mkdir -p "${CMS_OUTPUT_PATH}"

cms_trap_ctrlc

# Start logging to file (tee's to both terminal and log file so that
# 'docker logs' still shows output).
cms_log_stdout_stderr "${CMS_OUTPUT_PATH}"

cms_display_start_info "${BENCHMARK} ${CONFIG} ${ACTION}"

cms_log_info "BENCHMARK : ${BENCHMARK}"
cms_log_info "CONFIG    : ${CONFIG}"
cms_log_info "ACTION    : ${ACTION}"

# -------------------------------------------------------------------------
# Collect system BOM (hardware/software inventory)
# -------------------------------------------------------------------------
cms_log_info "Collecting system information..."
cms_collect_sysinfo "${RESULTS_MOUNT}/sysinfo"

# -------------------------------------------------------------------------
# Query and log system topology
# -------------------------------------------------------------------------
cms_query_topology

# -------------------------------------------------------------------------
# Set performance governor for stable benchmark results
# (will warn but not fail if cpufreq is not available)
# -------------------------------------------------------------------------
cms_set_performance_governor

# -------------------------------------------------------------------------
# Generate heimdall environment files from container env vars
# -------------------------------------------------------------------------
cd /opt/heimdall
source /opt/heimdall/setup_env.sh

# -------------------------------------------------------------------------
# Execute the requested action
# -------------------------------------------------------------------------
run_install() {
    cms_log_info "Installing ${BENCHMARK} / ${CONFIG}..."
    uv run heimdall bench install "${BENCHMARK}" "${CONFIG}"
}

run_build() {
    cms_log_info "Building ${BENCHMARK} / ${CONFIG}..."
    uv run heimdall bench build "${BENCHMARK}" "${CONFIG}"
}

run_run() {
    cms_log_info "Running ${BENCHMARK} / ${CONFIG}..."
    uv run heimdall bench run "${BENCHMARK}" "${CONFIG}"
}

BENCH_EXIT=0
case "${ACTION}" in
    install)
        run_install || BENCH_EXIT=$?
        ;;
    build)
        run_build || BENCH_EXIT=$?
        ;;
    run)
        run_run || BENCH_EXIT=$?
        ;;
    build_and_run)
        run_build || BENCH_EXIT=$?
        if [ ${BENCH_EXIT} -eq 0 ]; then
            run_run || BENCH_EXIT=$?
        fi
        ;;
    all)
        run_install || BENCH_EXIT=$?
        if [ ${BENCH_EXIT} -eq 0 ]; then
            run_build || BENCH_EXIT=$?
        fi
        if [ ${BENCH_EXIT} -eq 0 ]; then
            run_run || BENCH_EXIT=$?
        fi
        ;;
    *)
        cms_log_error "Unknown ACTION '${ACTION}'"
        cms_log_error "Valid actions: install | build | run | build_and_run | all"
        exit 1
        ;;
esac

if [ ${BENCH_EXIT} -ne 0 ]; then
    cms_log_error "Benchmark exited with code ${BENCH_EXIT}"
    cms_log_error "Check the log above for details"
fi

# -------------------------------------------------------------------------
# Copy heimdall results into the mounted volume
# (always attempt this, even if the benchmark failed, so partial
# results and logs are preserved for debugging)
# -------------------------------------------------------------------------
cms_log_info "Copying benchmark results to ${RESULTS_MOUNT}..."

if [ -d "/opt/heimdall/results" ]; then
    cp -r /opt/heimdall/results/* "${RESULTS_MOUNT}/" 2>/dev/null || true
    cms_log_info "Copied: results/"
fi

if [ -d "/opt/heimdall/benchmark/llm_bench/logs" ]; then
    mkdir -p "${RESULTS_MOUNT}/llm_bench_logs"
    cp -r /opt/heimdall/benchmark/llm_bench/logs/* "${RESULTS_MOUNT}/llm_bench_logs/" 2>/dev/null || true
    cms_log_info "Copied: llm_bench/logs/"
fi

if [ -d "/opt/heimdall/benchmark/lockfree_bench/results" ]; then
    mkdir -p "${RESULTS_MOUNT}/lockfree_bench_results"
    cp -r /opt/heimdall/benchmark/lockfree_bench/results/* "${RESULTS_MOUNT}/lockfree_bench_results/" 2>/dev/null || true
    cms_log_info "Copied: lockfree_bench/results/"
fi

# -------------------------------------------------------------------------
# Generate HTML report and results tarball
# -------------------------------------------------------------------------
cms_generate_report "${RESULTS_MOUNT}" "heimdall-${BENCHMARK}-${CONFIG}" || true

# -------------------------------------------------------------------------
# Restore system state
# -------------------------------------------------------------------------
cms_restore_governor

# -------------------------------------------------------------------------
# Display end banner with elapsed time
# -------------------------------------------------------------------------
cms_display_end_info

# -------------------------------------------------------------------------
# Package all results into a tarball
# -------------------------------------------------------------------------
cms_package_results "${RESULTS_MOUNT}" || true

# Exit with the benchmark's exit code (not a CMS utility failure)
exit ${BENCH_EXIT}
