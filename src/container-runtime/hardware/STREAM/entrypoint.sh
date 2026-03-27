#!/bin/bash

#################################################################################################
# OCP SRV CMS - STREAM Benchmark Entrypoint
#
# Orchestrates the benchmark run:
#   1. Collect system hardware/software BOM
#   2. Run STREAM or STREAM scaling (the existing benchmark logic, unmodified)
#   3. Generate HTML report and results tarball
#################################################################################################

source /opt/cms-utils/cms_common.sh

CMS_SCRIPT_NAME="stream"
CMS_VERSION="0.1.0"

cd results

# --- 1. Collect system BOM before the benchmark ---
cms_log_info "Collecting system information before benchmark..."
cms_collect_sysinfo ./sysinfo

# --- 2. Run the STREAM benchmark ---
if [ "$BENCHMARK" = 'stream' ]; then
	cms_log_info "Running STREAM benchmark..."
	numactl $STREAM_CPU_NODE_BIND .././stream_c.exe $STREAM_NUMA_NODES $STREAM_NUM_LOOPS $STREAM_ARRAY_SIZE $STREAM_OFFSET $STREAM_MALLOC $STREAM_AUTO_ARRAY_SIZE
	bench_exit=$?

elif [ "$BENCHMARK" = 'scaling' ]; then
	cms_log_info "Running STREAM scaling benchmark..."
	.././run-stream-scaling.sh $SCALING_TEST $SCALING_CXL_NODE $SCALING_DRAM_NODE $SCALING_NUM_TIMES $SCALING_ARRAY_SIZE
	bench_exit=$?

else
	cms_log_error "BENCHMARK not set. Set BENCHMARK to 'stream' or 'scaling' in .env"
	bench_exit=1
fi

# --- 3. Generate report ---
cms_generate_report . stream ""

cms_log_info "STREAM benchmark complete (exit code: ${bench_exit})"
exit ${bench_exit}
