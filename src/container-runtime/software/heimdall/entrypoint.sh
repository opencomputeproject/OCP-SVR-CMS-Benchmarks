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

set -euo pipefail

# -------------------------------------------------------------------------
# Source the OCP CMS common library
# -------------------------------------------------------------------------
source /opt/cms-utils/cms_common.sh

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

# Set the CMS output path to the results mount so logs land there
CMS_OUTPUT_PATH="${RESULTS_MOUNT}"

# -------------------------------------------------------------------------
# CMS initialization
# -------------------------------------------------------------------------
cms_trap_ctrlc
cms_init_outputs
cms_log_stdout_stderr
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

case "${ACTION}" in
    install)
        run_install
        ;;
    build)
        run_build
        ;;
    run)
        run_run
        ;;
    build_and_run)
        run_build
        run_run
        ;;
    all)
        run_install
        run_build
        run_run
        ;;
    *)
        cms_log_error "Unknown ACTION '${ACTION}'"
        cms_log_error "Valid actions: install | build | run | build_and_run | all"
        exit 1
        ;;
esac

# -------------------------------------------------------------------------
# Copy heimdall results into the mounted volume
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
cms_generate_report "${RESULTS_MOUNT}" "heimdall-${BENCHMARK}-${CONFIG}"

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
cms_package_results "${RESULTS_MOUNT}"
