#!/bin/bash

#################################################################################################
# OCP SRV CMS - STREAM Benchmark Entrypoint
#
# Orchestrates the benchmark run:
#   1. Collect system hardware/software BOM
#   2. Run STREAM or STREAM scaling, capturing output
#   3. Parse results into CSV
#   4. Generate HTML report and results tarball
#################################################################################################

source /opt/cms-utils/cms_common.sh

CMS_SCRIPT_NAME="stream"
CMS_VERSION="0.1.0"

RAW_OUTPUT="raw_results.txt"
RESULTS_CSV="results.csv"

cd results

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

# --- 3. Parse results into CSV ---
if [ -f "${RAW_OUTPUT}" ]; then
	cms_log_info "Parsing STREAM results into CSV..."
	echo "function,direction,best_rate_mb_s,avg_time,min_time,max_time" > "${RESULTS_CSV}"
	grep -E '^(Copy|Scale|Add|Triad):' "${RAW_OUTPUT}" | while read -r line; do
		func=$(echo "${line}" | awk -F: '{print $1}')
		direction=$(echo "${line}" | awk '{print $2}')
		rate=$(echo "${line}" | awk '{print $3}')
		avg=$(echo "${line}" | awk '{print $4}')
		min=$(echo "${line}" | awk '{print $5}')
		max=$(echo "${line}" | awk '{print $6}')
		echo "${func},${direction},${rate},${avg},${min},${max}" >> "${RESULTS_CSV}"
	done
	cms_log_info "Results written to ${RESULTS_CSV}"
fi

# --- 4. Generate report ---
cms_generate_report . stream "./${RESULTS_CSV}"

cms_log_info "STREAM benchmark complete (exit code: ${bench_exit})"
exit ${bench_exit}
