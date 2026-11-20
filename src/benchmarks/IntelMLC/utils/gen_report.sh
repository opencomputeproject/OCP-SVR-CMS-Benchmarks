#!/usr/bin/env bash
#
# gen_report.sh - Generate a Markdown summary report from an mlc.sh output directory.
#
# Usage: gen_report.sh <mlc.sh-output-directory>
#
# Writes <directory>/summary_report.md summarizing the run: system info,
# which tests ran and whether they succeeded, and tables comparing peak
# latency/bandwidth per Socket->Node and per DRAM+CXL interleave pair.
# Pure bash/awk/grep - no Python, no new dependencies. Safe to re-run
# standalone at any time against an existing output directory.

set -u

SCRIPT_NAME=${0##*/}

usage() {
  echo "Usage: ${SCRIPT_NAME} <mlc.sh-output-directory>"
  echo
  echo "Writes <directory>/summary_report.md summarizing an mlc.sh benchmark run."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

DIR="${1%/}"

if [[ ! -d "${DIR}" ]]; then
  echo "ERROR: '${DIR}' is not a directory" >&2
  exit 1
fi

LOG="${DIR}/mlc.sh.log"
REPORT="${DIR}/summary_report.md"
REPORT_JSON="${DIR}/summary_report.json"

# Exclude the report itself (and any prior copy) from every scan below.
is_report_file() {
  case "${1##*/}" in
    summary_report.md|*_report.md|summary_report.json|*_report.json) return 0 ;;
    *) return 1 ;;
  esac
}

#################################################################################################
# JSON helpers - build summary_report.json in pure bash, no jq/python required.
# Mirrors the pattern used by src/container-runtime/utils/collect_sysinfo.sh.
#################################################################################################

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s=$(printf '%s' "$s" | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {print}')
  printf '%s' "$s"
}

# "key": "value" (value escaped; null if empty or "n/a")
_json_str() {
  local key="$1" val="$2"
  if [[ -z "${val}" || "${val}" == "n/a" ]]; then
    printf '"%s": null' "${key}"
  else
    printf '"%s": "%s"' "${key}" "$(_json_escape "${val}")"
  fi
}

# "key": value (bare numeric; null if empty/non-numeric/"n/a")
_json_num() {
  local key="$1" val="$2"
  if [[ "${val}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '"%s": %s' "${key}" "${val}"
  else
    printf '"%s": null' "${key}"
  fi
}

# Render a bash array (nameref, arg1 = array name) whose elements are already
# pre-rendered "{ ... }" JSON objects into a single "[ {..}, {..} ]" string.
_json_array_of_objects() {
  local -n arr="$1"
  local n=${#arr[@]} i
  if [[ ${n} -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '[\n'
  for ((i = 0; i < n; i++)); do
    printf '    %s' "${arr[$i]}"
    [[ $i -lt $((n - 1)) ]] && printf ',\n' || printf '\n'
  done
  printf '  ]'
}

# Render a bash array (nameref, arg1 = array name) of plain strings into a
# single "[ "a", "b" ]" JSON string array.
_json_array_of_strings() {
  local -n arr="$1"
  local n=${#arr[@]} i
  if [[ ${n} -eq 0 ]]; then
    printf '[]'
    return
  fi
  printf '[\n'
  for ((i = 0; i < n; i++)); do
    printf '    "%s"' "$(_json_escape "${arr[$i]}")"
    [[ $i -lt $((n - 1)) ]] && printf ',\n' || printf '\n'
  done
  printf '  ]'
}

# Recognizability gate: refuse to write a garbage report against an
# unrelated directory.
recognizable=0
for pattern in 'idle_latency_*.txt' 'bw_node*.txt' 'bw_ramp.results.*.csv' 'bw_ramp_interleave.results.*.csv'; do
  for f in "${DIR}"/${pattern}; do
    if [[ -e "${f}" ]]; then
      recognizable=1
      break 2
    fi
  done
done
if [[ "${recognizable}" -eq 0 ]]; then
  echo "ERROR: '${DIR}' contains no recognizable mlc.sh output files" >&2
  exit 1
fi

#################################################################################################
# System info (from mlc.sh.log; degrades to n/a if the log is missing)
#################################################################################################

sut_hostname="n/a"
sut_platform="n/a"
sut_mlc_ver="n/a"
sut_mlc_sh_ver="n/a"
sut_invocation="n/a"
sut_sockets_in_system="n/a"
sut_cores_per_socket="n/a"
sut_numa_nodes="n/a"
sut_started="n/a"
sut_ended="n/a"
sut_duration="n/a"
run_status="Unknown (log missing)"
log_missing_note=""

base_dir_name="${DIR##*/}"
if [[ "${base_dir_name}" =~ ^mlc\.sh\.(.+)\.[0-9]{4}-[0-9]{4}$ ]]; then
  sut_hostname="${BASH_REMATCH[1]}"
fi

log_error_lines=()
if [[ -f "${LOG}" ]]; then
  sut_mlc_sh_ver=$(grep -m1 '^mlc.sh Version ' "${LOG}" | awk '{print $3}')
  sut_invocation=$(grep -m1 -E '^mlc\.sh .*-' "${LOG}")
  sut_started=$(grep -m1 '^Started: ' "${LOG}" | cut -d' ' -f2-)
  sut_sockets_in_system=$(grep -m1 'Number of Physcial Sockets:' "${LOG}" | awk -F: '{print $NF}' | xargs)
  sut_cores_per_socket=$(grep -m1 '^CPU cores per socket:' "${LOG}" | awk -F: '{print $NF}' | xargs)
  sut_numa_nodes=$(grep -m1 'Number of NUMA Node(s):' "${LOG}" | awk -F: '{print $NF}' | xargs)
  sut_platform=$(grep -m1 -oE 'Detected .* platform' "${LOG}")
  sut_mlc_ver=$(grep -m1 -oE 'Intel\(R\) Memory Latency Checker - v[0-9.]+' "${LOG}" | grep -oE 'v[0-9.]+')

  if grep -q '^mlc.sh Completed' "${LOG}"; then
    run_status="Completed"
    sut_ended=$(grep -m1 '^Ended: ' "${LOG}" | cut -d' ' -f2-)
    sut_duration=$(grep -m1 '^Duration: ' "${LOG}" | cut -d' ' -f2-)
  else
    run_status="In progress / incomplete"
  fi

  mapfile -t log_error_lines < <(grep -iE 'error|fail|cannot|denied|not found' "${LOG}" \
    | grep -viE 'latency optimized mode|Random bandwidth option is supported only' \
    | sort -u | head -10)

  [[ -z "${sut_mlc_sh_ver}" ]] && sut_mlc_sh_ver="n/a"
  [[ -z "${sut_invocation}" ]] && sut_invocation="n/a"
  [[ -z "${sut_started}" ]] && sut_started="n/a"
  [[ -z "${sut_sockets_in_system}" ]] && sut_sockets_in_system="n/a"
  [[ -z "${sut_cores_per_socket}" ]] && sut_cores_per_socket="n/a"
  [[ -z "${sut_numa_nodes}" ]] && sut_numa_nodes="n/a"
  [[ -z "${sut_platform}" ]] && sut_platform="n/a"
  [[ -z "${sut_mlc_ver}" ]] && sut_mlc_ver="n/a"
  [[ -z "${sut_ended}" ]] && sut_ended="n/a"
  [[ -z "${sut_duration}" ]] && sut_duration="n/a"
else
  log_missing_note="\`mlc.sh.log\` not found in this directory - system info and log-based error scanning are unavailable."
fi

#################################################################################################
# Topology discovery + peak bandwidth/latency per (socket, node)
#################################################################################################

declare -A NODE_TYPE      # NODE_TYPE[socket:node] = DRAM|CXL|unknown
declare -A IDLE_SEQ       # IDLE_SEQ[socket:node]  = ns
declare -A IDLE_RAND      # IDLE_RAND[socket:node] = ns
declare -A PEAK_BW        # PEAK_BW[socket:node]   = "bw|cores|lat|maxcores" (ramp-wide max - may still be a cache-residency artifact if the buffer-size cap engaged, see SUSTAINED_BW/observations)
declare -A SUSTAINED_BW   # SUSTAINED_BW[socket:node] = "bw|cores" (bandwidth at the highest core count tested - the tail-of-ramp value, unaffected by any early cache-residency)

for f in "${DIR}"/bw_ramp.results.node_*.R.seq.*.socket_*.csv; do
  [[ -e "${f}" ]] || continue
  base="${f##*/}"
  node=$(echo "${base}" | sed -E 's/^bw_ramp\.results\.node_([0-9]+)\..*/\1/')
  sock=$(echo "${base}" | sed -E 's/.*\.socket_([0-9]+)\.csv$/\1/')
  key="${sock}:${node}"

  ratio=$(awk -F, 'NR==2{gsub(/"/,"",$3); print $3; exit}' "${f}")
  case "${ratio}" in
    100:0) NODE_TYPE[${key}]="DRAM" ;;
    0:100) NODE_TYPE[${key}]="CXL" ;;
    *) NODE_TYPE[${key}]="unknown" ;;
  esac

  PEAK_BW[${key}]=$(awk -F, 'NR>1 && $9!="" {
      v=$9+0
      if (v>mb) { mb=v; c=$5; l=$8 }
      last=$5
    }
    END { if (mb>0) printf "%.1f|%s|%s|%s", mb, c, l, last }' "${f}")

  # Tail-of-ramp: the bandwidth at the highest core count tested (rows are
  # written in increasing core-count order by bandwidth_ramp()). This is
  # never a cache-residency artifact - by the max core count, the aggregate
  # working set is at its largest, so if anything is going to spill out of
  # cache it already has. Ground truth for DRAM/CXL comparisons even when
  # PEAK_BW above was measured at a low, possibly cache-resident, core count.
  SUSTAINED_BW[${key}]=$(awk -F, 'NR>1 && $9!="" { bw=$9+0; cores=$5 } END { if (cores!="") printf "%.1f|%s", bw, cores }' "${f}")

  idle_seq_file="${DIR}/idle_latency_seq_numa_node_${node}.socket_${sock}.txt"
  idle_rand_file="${DIR}/idle_latency_rand_numa_node_${node}.socket_${sock}.txt"
  [[ -f "${idle_seq_file}" ]] && IDLE_SEQ[${key}]=$(awk '/Each iteration took/{print $(NF-1); exit}' "${idle_seq_file}")
  [[ -f "${idle_rand_file}" ]] && IDLE_RAND[${key}]=$(awk '/Each iteration took/{print $(NF-1); exit}' "${idle_rand_file}")
done

node_keys_sorted=$(printf '%s\n' "${!PEAK_BW[@]}" | sort -t: -k1,1n -k2,2n)

#################################################################################################
# Interleave pair discovery + peak bandwidth/latency (seq only)
#################################################################################################

declare -A ILEAVE_PEAK       # ILEAVE_PEAK[socket:dnode:cnode:wtype]      = "bw|cores|lat|ratio" (ramp-wide max across all ratios - may still be a cache-residency artifact, see ILEAVE_SUSTAINED)
declare -A ILEAVE_SUSTAINED  # ILEAVE_SUSTAINED[socket:dnode:cnode:wtype] = "bw|cores|lat|ratio" (best tail-of-ramp bandwidth across all ratios - ground truth)
declare -A ILEAVE_SEEN
ileave_keys=()

for f in "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.seq.*.socket_*.csv; do
  [[ -e "${f}" ]] || continue
  base="${f##*/}"
  dnode=$(echo "${base}" | sed -E 's/^bw_ramp_interleave\.results\.node_([0-9]+)\.node_[0-9]+\..*/\1/')
  cnode=$(echo "${base}" | sed -E 's/^bw_ramp_interleave\.results\.node_[0-9]+\.node_([0-9]+)\..*/\1/')
  wtype=$(echo "${base}" | sed -E 's/^bw_ramp_interleave\.results\.node_[0-9]+\.node_[0-9]+\.(W[0-9]+)\..*/\1/')
  sock=$(echo "${base}" | sed -E 's/.*\.socket_([0-9]+)\.csv$/\1/')
  key="${sock}:${dnode}:${cnode}:${wtype}"
  if [[ -z "${ILEAVE_SEEN[${key}]:-}" ]]; then
    ILEAVE_SEEN[${key}]=1
    ileave_keys+=("${key}")
  fi
done

if [[ "${#ileave_keys[@]}" -gt 0 ]]; then
  ileave_keys_sorted=$(printf '%s\n' "${ileave_keys[@]}" | sort -t: -k1,1n -k2,2n -k3,3n -k4,4)
else
  ileave_keys_sorted=""
fi

for key in ${ileave_keys_sorted}; do
  IFS=':' read -r sock dnode cnode wtype <<< "${key}"
  files=("${DIR}"/bw_ramp_interleave.results.node_${dnode}.node_${cnode}.${wtype}.seq.*.socket_${sock}.csv)
  ILEAVE_PEAK[${key}]=$(awk -F, 'FNR>1 && $8!="" {
      gsub(/"/,"",$3)
      v=$8+0
      if (v>mb) { mb=v; c=$4; l=$7; r=$3 }
    }
    END { if (mb>0) printf "%.1f|%s|%s|%s", mb, c, l, r }' "${files[@]}")

  # Tail-of-ramp per ratio, then best across ratios: each file (one per
  # ratio) has its rows in increasing core-count order, so its *last* row is
  # that ratio's steady-state value. FNR==1 marks the start of a new file -
  # at that point the previously-buffered row was the prior file's last row,
  # so compare it then; the END block handles the final file the same way.
  ILEAVE_SUSTAINED[${key}]=$(awk -F, '
      FNR==1 {
        if (NR>1 && prev_bw!="") { if (prev_bw+0>mb) { mb=prev_bw+0; c=prev_c; l=prev_l; r=prev_r } }
        next
      }
      $8!="" { gsub(/"/,"",$3); prev_bw=$8; prev_c=$4; prev_l=$7; prev_r=$3 }
      END {
        if (prev_bw!="") { if (prev_bw+0>mb) { mb=prev_bw+0; c=prev_c; l=prev_l; r=prev_r } }
        if (mb>0) printf "%.1f|%s|%s|%s", mb, c, l, r
      }' "${files[@]}")
done

# Known MLC limitation: interleave rand files (from pre-fix mlc.sh runs) can
# never contain real data - random access is unsupported for W21/W23/W27.
rand_interleave_present=0
for f in "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.rand.*.socket_*.csv; do
  if [[ -e "${f}" ]]; then
    rand_interleave_present=1
    break
  fi
done

#################################################################################################
# Data-completeness scan (flag genuinely unexplained blank data)
#################################################################################################

unexplained_blank_files=()
for f in "${DIR}"/bw_ramp.results.*.csv "${DIR}"/bw_ramp_interleave.results.*.seq.*.csv; do
  [[ -e "${f}" ]] || continue
  blank=$(awk -F, 'NR>1 { n++; if ($NF=="") b++ } END { print (n>0 && n==b) ? "1" : "0" }' "${f}")
  if [[ "${blank}" == "1" ]]; then
    unexplained_blank_files+=("${f##*/}")
  fi
done

if [[ "${#log_error_lines[@]}" -gt 0 || "${#unexplained_blank_files[@]}" -gt 0 ]] && [[ "${run_status}" == "Completed" ]]; then
  run_status="Completed with warnings"
fi

#################################################################################################
# Anomaly detection: bandwidth that peaks early then declines >20% by the
# highest core count tested. This pattern is the signature of a
# cache-residency artifact, not a genuine memory-tier saturation effect: at
# low core counts the aggregate working set (buffer size x active threads)
# can still fit inside a modern multi-hundred-MB LLC, so the measurement is
# cache bandwidth (several x faster than a single DRAM/CXL channel) rather
# than real DRAM/CXL bandwidth. mlc.sh sizes its buffer to avoid this (see
# compute_buf_sz_kb() in mlc.sh), but a small target NUMA node's capacity can
# still force a smaller buffer than ideal - if that happened, the run log
# contains a "Buffer size capped" warning (surfaced separately below).
#################################################################################################

anomalies=()
for key in ${node_keys_sorted}; do
  IFS='|' read -r bw cores lat maxcores <<< "${PEAK_BW[${key}]:-}"
  [[ -z "${bw:-}" ]] && continue
  IFS='|' read -r tail_bw tail_cores <<< "${SUSTAINED_BW[${key}]:-}"
  [[ -z "${tail_bw:-}" ]] && continue
  IFS=':' read -r sock node <<< "${key}"
  drop_pct=$(awk -v peak="${bw}" -v tail="${tail_bw}" 'BEGIN { if (peak>0) printf "%.0f", ((peak-tail)/peak)*100; else print 0 }')
  if [[ "${drop_pct}" -gt 20 ]]; then
    anomalies+=("Socket ${sock} -> Node ${node} (${NODE_TYPE[${key}]:-unknown}) bandwidth peaks at ${cores} of ${maxcores} cores tested (${bw} MB/s) then drops ${drop_pct}% to ${tail_bw} MB/s by ${maxcores} cores - almost certainly a cache-residency artifact at the low core count, not a genuine memory-tier bandwidth peak. Treat the Sustained BW (${tail_bw} MB/s @ ${tail_cores} cores) as ground truth for this node, not Peak BW.")
  fi
done

#################################################################################################
# Buffer-size-capped warnings: mlc.sh's compute_buf_sz_kb() prints one of
# these whenever a target NUMA node's free capacity was too small to fit a
# fully cache-defeating buffer, so the low-core-count region of that
# particular test may still contain some cache-residency effect. Surface
# them explicitly in Observations rather than leaving them buried in the log.
#################################################################################################

buf_capped_lines=()
if [[ -f "${LOG}" ]]; then
  mapfile -t buf_capped_lines < <(grep '^WARNING: Buffer size capped' "${LOG}" | sort -u)
fi

#################################################################################################
# Charts
#################################################################################################

png_files=()
for f in "${DIR}"/*.png; do
  [[ -e "${f}" ]] && png_files+=("${f##*/}")
done

#################################################################################################
# Raw output file inventory (grouped counts, not an itemized list)
#################################################################################################

human_size() {
  awk -v b="${1}" 'BEGIN {
    if (b>=1048576) printf "%.1f MiB", b/1048576
    else if (b>=1024) printf "%.1f KiB", b/1024
    else printf "%d B", b
  }'
}

group_stats() {  # prints "count|totalbytes" for the given glob patterns
  local n=0 total=0 sz
  for f in "$@"; do
    [[ -e "${f}" ]] || continue
    is_report_file "${f}" && continue
    n=$((n + 1))
    sz=$(stat -c '%s' "${f}" 2>/dev/null || echo 0)
    total=$((total + sz))
  done
  echo "${n}|${total}"
}

read -r idle_count idle_bytes <<< "$(group_stats "${DIR}"/idle_latency_*.txt | tr '|' ' ')"
read -r bwtxt_count bwtxt_bytes <<< "$(group_stats "${DIR}"/bw_node*.txt | tr '|' ' ')"
read -r ramp_count ramp_bytes <<< "$(group_stats "${DIR}"/bw_ramp.results.*.csv | tr '|' ' ')"
read -r ileave_count ileave_bytes <<< "$(group_stats "${DIR}"/bw_ramp_interleave.results.*.csv | tr '|' ' ')"
read -r png_count png_bytes <<< "$(group_stats "${DIR}"/*.png | tr '|' ' ')"
log_bytes=0
log_count=0
if [[ -f "${LOG}" ]]; then
  log_count=1
  log_bytes=$(stat -c '%s' "${LOG}" 2>/dev/null || echo 0)
fi

# Everything else not matched above and not the report itself.
declare -A KNOWN_BASENAMES
for f in "${DIR}"/idle_latency_*.txt "${DIR}"/bw_node*.txt "${DIR}"/bw_ramp.results.*.csv \
         "${DIR}"/bw_ramp_interleave.results.*.csv "${DIR}"/*.png "${LOG}"; do
  [[ -e "${f}" ]] && KNOWN_BASENAMES["${f##*/}"]=1
done
other_count=0
other_bytes=0
for f in "${DIR}"/*; do
  [[ -f "${f}" ]] || continue
  base="${f##*/}"
  is_report_file "${f}" && continue
  [[ -n "${KNOWN_BASENAMES[${base}]:-}" ]] && continue
  other_count=$((other_count + 1))
  sz=$(stat -c '%s' "${f}" 2>/dev/null || echo 0)
  other_bytes=$((other_bytes + sz))
done

total_count=$((idle_count + bwtxt_count + ramp_count + ileave_count + png_count + log_count + other_count))
total_bytes=$((idle_bytes + bwtxt_bytes + ramp_bytes + ileave_bytes + png_bytes + log_bytes + other_bytes))

#################################################################################################
# Tests Run status per socket
#################################################################################################

sockets_sorted=$(printf '%s\n' "${!PEAK_BW[@]}" | cut -d: -f1 | sort -n -u)

has_match() {  # $1 = glob pattern (already expanded by caller context)
  local f
  for f in "$@"; do
    [[ -e "${f}" ]] && return 0
  done
  return 1
}

#################################################################################################
# Write the report
#################################################################################################

{
  echo "# Intel MLC Benchmark Summary"
  echo
  echo "- **Report generated:** $(date -u '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- **Source directory:** \`${DIR}\`"
  echo "- **Run status:** ${run_status}"
  echo

  echo "## System Under Test"
  echo
  echo "| Field | Value |"
  echo "|-------|-------|"
  echo "| Hostname | ${sut_hostname} |"
  echo "| Platform (MLC-detected) | ${sut_platform} |"
  echo "| MLC version | ${sut_mlc_ver} |"
  echo "| mlc.sh version | ${sut_mlc_sh_ver} |"
  echo "| Invocation | \`${sut_invocation}\` |"
  echo "| Physical sockets in system | ${sut_sockets_in_system} |"
  echo "| Cores per socket | ${sut_cores_per_socket} |"
  echo "| NUMA nodes in system | ${sut_numa_nodes} |"
  echo "| Started | ${sut_started} |"
  echo "| Ended | ${sut_ended} |"
  echo "| Duration | ${sut_duration} |"
  echo
  if [[ -n "${log_missing_note}" ]]; then
    echo "> ${log_missing_note}"
    echo
  fi

  echo "## Topology Tested"
  echo
  echo "| Socket | Node | Type |"
  echo "|--------|------|------|"
  for key in ${node_keys_sorted}; do
    IFS=':' read -r sock node <<< "${key}"
    echo "| ${sock} | ${node} | ${NODE_TYPE[${key}]:-unknown} |"
  done
  echo

  echo "## Tests Run"
  echo
  echo "| Socket | Test | Status |"
  echo "|--------|------|--------|"
  for sock in ${sockets_sorted}; do
    if has_match "${DIR}"/idle_latency_*_numa_node_*.socket_${sock}.txt; then
      echo "| ${sock} | Idle Latency | Done |"
    else
      echo "| ${sock} | Idle Latency | Not run |"
    fi
    if has_match "${DIR}"/bw_node*.socket_${sock}.txt; then
      echo "| ${sock} | Fixed-pattern Bandwidth | Done |"
    else
      echo "| ${sock} | Fixed-pattern Bandwidth | Not run |"
    fi
    if has_match "${DIR}"/bw_ramp.results.*.socket_${sock}.csv; then
      echo "| ${sock} | Bandwidth Ramp | Done |"
    else
      echo "| ${sock} | Bandwidth Ramp | Not run |"
    fi
    if has_match "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.seq.*.socket_${sock}.csv; then
      echo "| ${sock} | Interleave Ramp (seq) | Done |"
    else
      echo "| ${sock} | Interleave Ramp (seq) | Not run |"
    fi
    if has_match "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.rand.*.socket_${sock}.csv; then
      echo "| ${sock} | Interleave Ramp (rand) | Known MLC limitation |"
    fi
  done
  echo

  echo "## Peak Results by Socket -> Node"
  echo
  echo "Peak BW is the highest bandwidth seen anywhere in the core-count ramp -"
  echo "at low core counts this can still be a cache-residency artifact (see"
  echo "Observations below) rather than real DRAM/CXL bandwidth. **Sustained BW**"
  echo "is the bandwidth at the highest core count tested, which is never"
  echo "cache-resident - treat it as ground truth for DRAM/CXL comparisons."
  echo
  echo "| Socket | Node | Type | Idle Lat seq (ns) | Idle Lat rand (ns) | Peak BW (MB/s) | @ Cores | Lat @ Peak (ns) | Sustained BW (MB/s) | Max Cores Tested |"
  echo "|--------|------|------|--------------------|---------------------|----------------|---------|------------------|----------------------|-------------------|"
  for key in ${node_keys_sorted}; do
    IFS=':' read -r sock node <<< "${key}"
    IFS='|' read -r bw cores lat maxcores <<< "${PEAK_BW[${key}]:-}"
    IFS='|' read -r sustained_bw sustained_cores <<< "${SUSTAINED_BW[${key}]:-}"
    echo "| ${sock} | ${node} | ${NODE_TYPE[${key}]:-unknown} | ${IDLE_SEQ[${key}]:-n/a} | ${IDLE_RAND[${key}]:-n/a} | ${bw:-no data} | ${cores:-} | ${lat:-} | ${sustained_bw:-no data} | ${maxcores:-} |"
  done
  echo

  if [[ -n "${ileave_keys_sorted}" ]]; then
    echo "## Interleave Peak Results (DRAM + CXL, seq)"
    echo
    echo "Peak BW/Best Ratio are the highest bandwidth seen anywhere across every"
    echo "ratio's core-count ramp - at low core counts this can still be a"
    echo "cache-residency artifact rather than a genuine DRAM:CXL tiering result."
    echo "**Sustained BW/Ratio** picks the best *tail-of-ramp* (highest core count)"
    echo "value across ratios instead - never cache-resident, so this is the"
    echo "number to trust when deciding which ratio genuinely performs best."
    echo
    echo "| Socket | DRAM Node | CXL Node | Traffic | Peak BW (MB/s) | @ Cores | Lat @ Peak (ns) | Best Ratio (DRAM:CXL) | Sustained BW (MB/s) | Sustained Ratio (DRAM:CXL) |"
    echo "|--------|-----------|----------|---------|----------------|---------|------------------|------------------------|----------------------|------------------------------|"
    for key in ${ileave_keys_sorted}; do
      IFS=':' read -r sock dnode cnode wtype <<< "${key}"
      IFS='|' read -r bw cores lat ratio <<< "${ILEAVE_PEAK[${key}]:-}"
      IFS='|' read -r sustained_bw sustained_cores sustained_lat sustained_ratio <<< "${ILEAVE_SUSTAINED[${key}]:-}"
      echo "| ${sock} | ${dnode} | ${cnode} | ${wtype} | ${bw:-no data} | ${cores:-} | ${lat:-} | ${ratio:-} | ${sustained_bw:-no data} | ${sustained_ratio:-} |"
    done
    echo
  fi

  echo "## Observations / Potential Issues"
  echo
  obs_any=0
  for a in "${anomalies[@]:-}"; do
    [[ -z "${a}" ]] && continue
    echo "- ${a}"
    obs_any=1
  done
  if [[ "${rand_interleave_present}" -eq 1 ]]; then
    echo "- Interleave random-access (W21/W23/W27) data found with blank Latency/Bandwidth fields - this is a documented, permanent MLC restriction (random access is only supported for traffic types R, W2, W5, W6), not a failure. Current mlc.sh no longer attempts this combination."
    obs_any=1
  fi
  if [[ "${#buf_capped_lines[@]}" -gt 0 ]]; then
    echo "- Buffer size was capped below the cache-defeating target by target NUMA node capacity for ${#buf_capped_lines[@]} test(s) - some low-core-count results below may retain partial cache residency. Trust the Sustained BW/Ratio columns above over Peak BW/Best Ratio for these:"
    for bl in "${buf_capped_lines[@]}"; do
      echo "  - ${bl#WARNING: }"
    done
    obs_any=1
  fi
  if [[ "${#unexplained_blank_files[@]}" -gt 0 ]]; then
    echo "- The following result file(s) contain no usable data and do not match a known limitation - worth investigating:"
    for bf in "${unexplained_blank_files[@]}"; do
      echo "  - \`${bf}\`"
    done
    obs_any=1
  fi
  if [[ "${#log_error_lines[@]}" -gt 0 ]]; then
    echo "- ${#log_error_lines[@]} distinct error/warning line(s) found in \`mlc.sh.log\`:"
    for el in "${log_error_lines[@]}"; do
      echo "  - \`${el}\`"
    done
    obs_any=1
  fi
  if [[ -n "${log_missing_note}" ]]; then
    echo "- ${log_missing_note}"
    obs_any=1
  fi
  if [[ "${obs_any}" -eq 0 ]]; then
    echo "- None detected."
  fi
  echo

  echo "## Charts"
  echo
  if [[ "${#png_files[@]}" -gt 0 ]]; then
    for p in "${png_files[@]}"; do
      echo "- \`${p}\`"
    done
  else
    echo "No chart images found. Generate them with:"
    echo
    echo "\`\`\`"
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
    echo "${script_dir}/.venv/bin/python ${script_dir}/gen_plot.py -d \"${DIR}\""
    echo "\`\`\`"
  fi
  echo

  echo "## Raw Output Files"
  echo
  echo "| Group | Count | Total Size |"
  echo "|-------|-------|------------|"
  echo "| Idle latency (idle_latency_*.txt) | ${idle_count} | $(human_size "${idle_bytes}") |"
  echo "| Fixed-pattern bandwidth (bw_node*.txt) | ${bwtxt_count} | $(human_size "${bwtxt_bytes}") |"
  echo "| Per-node bandwidth ramp (bw_ramp.results.*.csv) | ${ramp_count} | $(human_size "${ramp_bytes}") |"
  echo "| Interleave ramp (bw_ramp_interleave.results.*.csv) | ${ileave_count} | $(human_size "${ileave_bytes}") |"
  echo "| Charts (*.png) | ${png_count} | $(human_size "${png_bytes}") |"
  echo "| Log (mlc.sh.log) | ${log_count} | $(human_size "${log_bytes}") |"
  if [[ "${other_count}" -gt 0 ]]; then
    echo "| Other files | ${other_count} | $(human_size "${other_bytes}") |"
  fi
  echo "| **Total** | ${total_count} | $(human_size "${total_bytes}") |"
} > "${REPORT}"

#################################################################################################
# Write the machine-readable JSON report (same data as above, second emission pass)
#################################################################################################

TOPOLOGY_JSON=()
for key in ${node_keys_sorted}; do
  IFS=':' read -r sock node <<< "${key}"
  TOPOLOGY_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_num "node" "${node}"), $(_json_str "type" "${NODE_TYPE[${key}]:-unknown}") }")
done

TESTS_RUN_JSON=()
for sock in ${sockets_sorted}; do
  if has_match "${DIR}"/idle_latency_*_numa_node_*.socket_${sock}.txt; then st="Done"; else st="Not run"; fi
  TESTS_RUN_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_str "test" "Idle Latency"), $(_json_str "status" "${st}") }")

  if has_match "${DIR}"/bw_node*.socket_${sock}.txt; then st="Done"; else st="Not run"; fi
  TESTS_RUN_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_str "test" "Fixed-pattern Bandwidth"), $(_json_str "status" "${st}") }")

  if has_match "${DIR}"/bw_ramp.results.*.socket_${sock}.csv; then st="Done"; else st="Not run"; fi
  TESTS_RUN_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_str "test" "Bandwidth Ramp"), $(_json_str "status" "${st}") }")

  if has_match "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.seq.*.socket_${sock}.csv; then st="Done"; else st="Not run"; fi
  TESTS_RUN_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_str "test" "Interleave Ramp (seq)"), $(_json_str "status" "${st}") }")

  if has_match "${DIR}"/bw_ramp_interleave.results.node_*.node_*.*.rand.*.socket_${sock}.csv; then
    TESTS_RUN_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_str "test" "Interleave Ramp (rand)"), $(_json_str "status" "Known MLC limitation") }")
  fi
done

PEAK_RESULTS_JSON=()
for key in ${node_keys_sorted}; do
  IFS=':' read -r sock node <<< "${key}"
  IFS='|' read -r bw cores lat maxcores <<< "${PEAK_BW[${key}]:-}"
  IFS='|' read -r sustained_bw sustained_cores <<< "${SUSTAINED_BW[${key}]:-}"
  PEAK_RESULTS_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_num "node" "${node}"), $(_json_str "type" "${NODE_TYPE[${key}]:-unknown}"), $(_json_num "idle_lat_seq_ns" "${IDLE_SEQ[${key}]:-}"), $(_json_num "idle_lat_rand_ns" "${IDLE_RAND[${key}]:-}"), $(_json_num "peak_bw_mbs" "${bw:-}"), $(_json_num "at_cores" "${cores:-}"), $(_json_num "lat_at_peak_ns" "${lat:-}"), $(_json_num "sustained_bw_mbs" "${sustained_bw:-}"), $(_json_num "max_cores_tested" "${maxcores:-}") }")
done

INTERLEAVE_JSON=()
for key in ${ileave_keys_sorted}; do
  IFS=':' read -r sock dnode cnode wtype <<< "${key}"
  IFS='|' read -r bw cores lat ratio <<< "${ILEAVE_PEAK[${key}]:-}"
  IFS='|' read -r sustained_bw sustained_cores sustained_lat sustained_ratio <<< "${ILEAVE_SUSTAINED[${key}]:-}"
  INTERLEAVE_JSON+=("{ $(_json_num "socket" "${sock}"), $(_json_num "dram_node" "${dnode}"), $(_json_num "cxl_node" "${cnode}"), $(_json_str "traffic" "${wtype}"), $(_json_num "peak_bw_mbs" "${bw:-}"), $(_json_num "at_cores" "${cores:-}"), $(_json_num "lat_at_peak_ns" "${lat:-}"), $(_json_str "best_ratio" "${ratio:-}"), $(_json_num "sustained_bw_mbs" "${sustained_bw:-}"), $(_json_str "sustained_ratio" "${sustained_ratio:-}") }")
done

# Same content as the "Observations / Potential Issues" Markdown section, flattened to strings.
OBS_LINES=()
for a in "${anomalies[@]:-}"; do
  [[ -z "${a}" ]] && continue
  OBS_LINES+=("${a}")
done
if [[ "${rand_interleave_present}" -eq 1 ]]; then
  OBS_LINES+=("Interleave random-access (W21/W23/W27) data found with blank Latency/Bandwidth fields - this is a documented, permanent MLC restriction (random access is only supported for traffic types R, W2, W5, W6), not a failure. Current mlc.sh no longer attempts this combination.")
fi
for bl in "${buf_capped_lines[@]:-}"; do
  [[ -z "${bl}" ]] && continue
  OBS_LINES+=("${bl#WARNING: }")
done
for bf in "${unexplained_blank_files[@]:-}"; do
  [[ -z "${bf}" ]] && continue
  OBS_LINES+=("Result file with no usable data and no known limitation match: ${bf}")
done
for el in "${log_error_lines[@]:-}"; do
  [[ -z "${el}" ]] && continue
  OBS_LINES+=("Log error/warning line: ${el}")
done
if [[ -n "${log_missing_note}" ]]; then
  OBS_LINES+=("${log_missing_note}")
fi

CHARTS_JSON=("${png_files[@]:-}")

RAW_FILES_JSON=(
  "{ $(_json_str "group" "idle_latency"), $(_json_num "count" "${idle_count}"), $(_json_num "total_bytes" "${idle_bytes}") }"
  "{ $(_json_str "group" "fixed_pattern_bandwidth"), $(_json_num "count" "${bwtxt_count}"), $(_json_num "total_bytes" "${bwtxt_bytes}") }"
  "{ $(_json_str "group" "bandwidth_ramp"), $(_json_num "count" "${ramp_count}"), $(_json_num "total_bytes" "${ramp_bytes}") }"
  "{ $(_json_str "group" "interleave_ramp"), $(_json_num "count" "${ileave_count}"), $(_json_num "total_bytes" "${ileave_bytes}") }"
  "{ $(_json_str "group" "charts"), $(_json_num "count" "${png_count}"), $(_json_num "total_bytes" "${png_bytes}") }"
  "{ $(_json_str "group" "log"), $(_json_num "count" "${log_count}"), $(_json_num "total_bytes" "${log_bytes}") }"
)
if [[ "${other_count}" -gt 0 ]]; then
  RAW_FILES_JSON+=("{ $(_json_str "group" "other"), $(_json_num "count" "${other_count}"), $(_json_num "total_bytes" "${other_bytes}") }")
fi

{
  printf '{\n'
  printf '  %s,\n' "$(_json_str "report_generated" "$(date -u '+%Y-%m-%d %H:%M:%S %Z')")"
  printf '  %s,\n' "$(_json_str "source_directory" "${DIR}")"
  printf '  %s,\n' "$(_json_str "run_status" "${run_status}")"
  printf '  "system": {\n'
  printf '    %s,\n' "$(_json_str "hostname" "${sut_hostname}")"
  printf '    %s,\n' "$(_json_str "platform" "${sut_platform}")"
  printf '    %s,\n' "$(_json_str "mlc_version" "${sut_mlc_ver}")"
  printf '    %s,\n' "$(_json_str "mlc_sh_version" "${sut_mlc_sh_ver}")"
  printf '    %s,\n' "$(_json_str "invocation" "${sut_invocation}")"
  printf '    %s,\n' "$(_json_num "sockets_in_system" "${sut_sockets_in_system}")"
  printf '    %s,\n' "$(_json_num "cores_per_socket" "${sut_cores_per_socket}")"
  printf '    %s,\n' "$(_json_num "numa_nodes_in_system" "${sut_numa_nodes}")"
  printf '    %s,\n' "$(_json_str "started" "${sut_started}")"
  printf '    %s,\n' "$(_json_str "ended" "${sut_ended}")"
  printf '    %s\n'  "$(_json_str "duration" "${sut_duration}")"
  printf '  },\n'
  printf '  "topology": %s,\n' "$(_json_array_of_objects TOPOLOGY_JSON)"
  printf '  "tests_run": %s,\n' "$(_json_array_of_objects TESTS_RUN_JSON)"
  printf '  "peak_results": %s,\n' "$(_json_array_of_objects PEAK_RESULTS_JSON)"
  printf '  "interleave_peak_results": %s,\n' "$(_json_array_of_objects INTERLEAVE_JSON)"
  printf '  "observations": %s,\n' "$(_json_array_of_strings OBS_LINES)"
  printf '  "charts": %s,\n' "$(_json_array_of_strings CHARTS_JSON)"
  printf '  "raw_files": %s,\n' "$(_json_array_of_objects RAW_FILES_JSON)"
  printf '  %s,\n' "$(_json_num "total_files" "${total_count}")"
  printf '  %s\n' "$(_json_num "total_bytes" "${total_bytes}")"
  printf '}\n'
} > "${REPORT_JSON}"

echo "Report written to: ${REPORT}"
echo "JSON report written to: ${REPORT_JSON}"
