#!/usr/bin/env bash 

# Add the current working directory to $PATH
pushd $PWD &> /dev/null

# This script will run a series of Intel(R) MLC peak bandwidth tests
# using DRAM and CXL memory expansion.

#################################################################################################
# Global Variables
#################################################################################################

VERSION="0.3.0"             # version string

SCRIPT_NAME=${0##*/}        # Name of this script
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]:-$0}"; )" &> /dev/null && pwd 2> /dev/null; )"  # Provides the full directory name of the script no matter where it is being called from

OUTPUT_PATH="./${SCRIPT_NAME}.$(hostname).$(date +"%m%d-%H%M")" # output directory created by this script
STDOUT_LOG_FILE="${SCRIPT_NAME}.log"      # Filename to save STDOUT and STDERR

CXLCLI=("$(command -v cxl)")        # Path to cxl, use -c option to specify the location of the cxl binary
NUMACTL=("$(command -v numactl)")   # Path to numactl
LSCPU=("$(command -v lscpu)")       # Path to lscpu
AWK=("$(command -v awk)")           # Path to awk
GREP=("$(command -v grep)")         # Path to grep
SED=("$(command -v sed)")           # Path to sed
TPUT=("$(command -v tput)")         # Path to tput
CP=("$(command -v cp)")             # Path to cp
FIND=("$(command -v find)")         # Path to find
TEE=("$(command -v tee)")           # Path to tee
TAIL=("$(command -v tail)")         # Path to tail
MLC=("$(command -v mlc)")           # Path to Intel MLC

# Command line arguments
socket=                       # -s argument to specify the CPU socket to run MLC, default is the first DRAM (or CXL) node
OPT_VERBOSITY=0               # default, -v, -vv, -vvv option to increase verbose output
OPT_LOADED_LATENCY=false      # default, -l to override and perform loaded latency testing
OPT_X=""                      # default, -X to override and use all cpu threads on all cores
OPT_Z="-Z"                    # default, -Z to override and AVX-512 64-byte load/store instructions
CXL_NODES=()                  # default empty, -c to specify one or more (comma-separated) NUMA Node(s) backed by CXL
DRAM_NODES=()                 # default empty, -d to specify one or more (comma-separated) NUMA Node(s) backed by DRAM
SOCKETS=()                    # default empty, -s to specify one or more (comma-separated) CPU socket(s)

# MLC Options
SAMPLE_TIME=30                # default, -t argument to MLC

# Buffer sizing (auto-tuned per platform - see compute_buf_sz_kb())
# -------------------------------------------------------------------------
# MLC allocates one buffer of this size *per thread* (see `mlc --help`'s "-o"
# and "-u" - "-u" is what would change that). A buffer size tuned for an
# older generation's small L3 becomes a cache-residency trap on modern CPUs:
# at low core counts the *aggregate* footprint (buffer x active threads) can
# fit entirely inside a modern multi-hundred-MB L3, so the test measures
# cache bandwidth (2-3x faster than a single DDR5/CXL channel) instead of
# real DRAM/CXL bandwidth. compute_buf_sz_kb() sizes the buffer per-run from
# the actually-detected LLC size and the target NUMA node's free capacity
# instead of a hardcoded constant. See README "Buffer sizing" section.
CACHE_DEFEAT_MARGIN=${MLC_SH_CACHE_MARGIN:-3}                         # Buffer = this many x the detected LLC size, so even 1 active thread's own buffer exceeds it. Override: MLC_SH_CACHE_MARGIN
NODE_CAPACITY_SAFE_FRACTION_PCT=${MLC_SH_CAPACITY_FRACTION_PCT:-75}   # Never let (buffer x max threads tested) exceed this % of a target node's free memory. Override: MLC_SH_CAPACITY_FRACTION_PCT
BUF_SZ_LEGACY_DEFAULT=40000    # Fallback only - used if LLC auto-detection fails entirely (e.g. unsupported platform)
OPT_BUF_SZ_OVERRIDE=""         # -b <KiB> forces an explicit buffer size and skips auto-detection/capping entirely

# Global Variables
NUMA_NODES_IN_SYSTEM=0        # Number of NUMA Nodes in the host
NUM_CXL_DEVICES=0             # Number of CXL endpoint Devices in the host
SOCKETS_IN_SYSTEM=0           # Number of CPU Sockets in the host
CORES_PER_SOCKET=0            # Number of CPU Cores per Socket
THREADS_PER_CORE=0            # Number of CPU Threads per Core
CPU_HYPERTHREADING=false      # CPU Hyperthreading Enabled (Ture) or Disabled (false)
IncCPU=2                      # If Hyperthreading is Enabled and '-X' is not used, then use only one thread of each core
nr_hugepages=$(cat /proc/sys/vm/nr_hugepages)    # Number of Huge (2MiB) pages in the system. Latency tests require 2MiB pages for accuracy.

#################################################################################################
# Helper Functions
#################################################################################################

# Handle Ctrl-C User Input
trap ctrl_c INT
function ctrl_c() {
  echo "INFO: Received CTRL+C - aborting"
  restore_output_ownership
  display_end_info
  exit 1
}

# Display test start information
# arg1: The command arguments for the script. Pass to this function using 'display_start_info $@'
function display_start_info() {
  START_TIME=$(date +%s)
  echo "======================================================================="
  echo "Starting ${SCRIPT_NAME}"
  echo "${SCRIPT_NAME} Version ${VERSION}"
  if [[ -n "$1" ]]; then
    echo "${SCRIPT_NAME} $1"
  fi
  echo "Started: $(date --date @${START_TIME})"
  echo "======================================================================="
}

# Display test end information
function display_end_info() {
  END_TIME=$(date +%s)
  TEST_DURATION=$((${END_TIME}-${START_TIME}))
  echo "======================================================================="
  echo "${SCRIPT_NAME} Completed"
  echo "Ended: $(date --date @${END_TIME})"
  print_time "${TEST_DURATION}" "Duration:"
  echo "Results: ${OUTPUT_PATH}"
  echo "Logfile: ${LOG_FILE}"
  if [[ -f "${OUTPUT_PATH}/summary_report.md" ]]; then
    echo "Report: ${OUTPUT_PATH}/summary_report.md"
  fi
  echo "======================================================================="
}

# Verify the required commands and utilities exist on the system
# We use either the defaults or user specified paths
function verify_cmds() {
   err_state=false
   if [ ! -x "${MLC}" ]; then
     echo "ERROR: mlc command not found! Use -m to specify the path."
     err_state=true
   else 
     echo "Using MLC command: ${MLC}"
     TOKENS=( $($MLC --version 2>&1 | head -n 1) )
     MLC_VER=${TOKENS[5]}
     echo "MLC version: $MLC_VER"
   fi
   if [ ${OPT_Z} == 1 ]; then
     echo "Using MLC AVX512: Yes"
   else
     echo "Using MLC AVX512: No"
   fi

   for CMD in numactl lscpu lspci grep cut bc awk; do
    CMD_PATH=($(command -v ${CMD}))
    if [ ! -x "${CMD_PATH}" ]; then
      echo "ERROR: ${CMD} command not found! Please install the ${CMD} package."
      err_state=true
    fi
   done

   if ${err_state}; then
     echo "Exiting due to previous error(s)"
     exit 1
   fi
}

# Display the help information
function display_usage() {
   echo " "
   echo "Usage: $0 -c <CXL NUMA Node ID(s)> -d <DRAM NUMA Node ID(s)> [optional args]"
   echo " "
   echo "Runs bandwidth and latency tests on DRAM and CXL Type 3 Memory using Intel MLC"
   echo "Run with root privilege (MLC needs it)"
   echo " "
   echo "Optional args:"
   echo " "
   echo "   -b <KiB>"
   echo "      Force the MLC per-thread buffer size (KiB) instead of auto-detecting"
   echo "      it from the target CPU's LLC size and the target NUMA node's free"
   echo "      memory. Use this to override the auto-tuned value, e.g. to reproduce"
   echo "      a prior run's exact buffer size, or if auto-detection is wrong for"
   echo "      your platform. By default the buffer is sized to ${CACHE_DEFEAT_MARGIN}x the"
   echo "      detected last-level cache so results are DRAM/CXL-bound rather than"
   echo "      cache-resident, capped to ${NODE_CAPACITY_SAFE_FRACTION_PCT}% of the target node's free memory."
   echo " "
   echo "   -c <CXL NUMA Node(s)>"
   echo "      Specify the NUMA Node(s) backed by CXL for testing."
   echo "      Accepts a single node or a comma-separated list, e.g. -c 2,3"
   echo " "
   echo "   -d <DRAM NUMA Node(s)>"
   echo "      Specify the NUMA Node(s) backed by DRAM for testing."
   echo "      Accepts a single node or a comma-separated list, e.g. -d 0,1"
   echo " "
   echo "      Providing both -c and -d sweeps every DRAM x CXL node pair"
   echo "      for the interleave tests, in addition to per-node tests."
   echo " "
   echo "   -m <Path to MLC executable>"
   echo "      Specify the path to the MLC executable"
   echo " "
   echo "   -s <Socket(s)>"
   echo "      Specify which CPU socket(s) should be used for running mlc."
   echo "      Accepts a single socket or a comma-separated list, e.g. -s 0,1"
   echo "      Each socket runs the full test sequence; output files are tagged with .socket_<n>."
   echo "      By default, the first DRAM (or CXL) node id is used."
   echo " "
   echo "   -v"
   echo "      Print verbose output. Use -v, -vv, and -vvv to increase verbosity."
   echo " "
   echo "   -X"
   echo "      For bandwidth tests, mlc will use all cpu threads on each Hyperthread enabled core."
   echo "      Use this option to use only one thread on the core"
   echo " "
   echo "   -Z <Specify whether to enable or disable the AVX_512 option>"
   echo "      Values:"
   echo "        0: AVX_512 Option Disabled"
   echo "        1: AVX_512 Option Enabled - Default"
   echo "      By default, the AVX_512 option is enabled. If the non-AVX512"
   echo "      version of MLC is being used, this option shall be set to 0"
   echo " "
   echo "Compare mode:"
   echo " "
   echo "   $0 --compare <run_A_dir_or_json> <run_B_dir_or_json> [-o <output.md>] [-t <threshold_pct>]"
   echo "      Compare two prior mlc.sh output directories (or their"
   echo "      summary_report.json files directly) and write a Markdown"
   echo "      report highlighting which metrics got better or worse -"
   echo "      useful for regression testing (run1 vs run2) or comparing"
   echo "      one system to another. Needs neither root nor MLC itself."
   echo "      See utils/gen_compare.py --help for all options."
   exit 0
}

# Process command arguments and options
function process_args() {

   # getopts has no concept of long options, so handle --help explicitly
   for arg in "$@"; do
     if [[ "$arg" == "--help" ]]; then
       display_usage "$0"
     fi
   done

   # Process the command arguments and options
   while getopts "h?b:c:d:m:s:vXZ:" opt; do
      case "$opt" in
      h|\?)
        display_usage "$0"
        ;;
      b) # Force an explicit per-thread buffer size (KiB), skipping auto-detection
        if ! [[ $OPTARG =~ ^[0-9]+$ ]]; then
          echo "Error: Invalid value for '-b'. Requires an integer (KiB)."
          exit 1
        fi
        OPT_BUF_SZ_OVERRIDE=$OPTARG
        ;;
      c) # Set the CXL NUMA Node ID(s) to test
        # Validate input is a numeric value or comma-separated list of numeric values
        if ! [[ $OPTARG =~ ^[0-9]+(,[0-9]+)*$ ]]
        then
          echo "Error: Invalid value for '-c'. Requires an integer or comma-separated list of integers."
          exit 1
        fi
        IFS=',' read -ra CXL_NODES <<< "$OPTARG"
        ;;
      d) # Set the DRAM NUMA Node ID(s) to test
        # Validate input is a numeric value or comma-separated list of numeric values
        if ! [[ $OPTARG =~ ^[0-9]+(,[0-9]+)*$ ]]; then
          echo "Error: Invalid value for '-d'. Requires an integer or comma-separated list of integers."
          exit 1
        fi
        IFS=',' read -ra DRAM_NODES <<< "$OPTARG"
        ;;
      m) # Set the location of the mlc binary 
        MLC=$OPTARG
        ;;
      s) # Specify which CPU socket(s) to execute MLC on
        # Validate input is a numeric value or comma-separated list of numeric values
        if ! [[ $OPTARG =~ ^[0-9]+(,[0-9]+)*$ ]]; then
          echo "Error: Invalid value for '-s'. Requires an integer or comma-separated list of integers."
          exit 1
        fi
        IFS=',' read -ra SOCKETS <<< "$OPTARG"
        # Validate every entry is a real socket on this system
        for s in "${SOCKETS[@]}"; do
          socket="$s"
          verify_cpu_socket
        done
         ;;
      v) # Each -v should increase OPT_VERBOSITY level
         OPT_VERBOSITY=$((OPT_VERBOSITY+1))
         ;;
      X) # Use all CPU threads on all cores
         OPT_X="-X"
         IncCPU=1
         ;;
      Z) # Enable/Disable AVX512 instructions 
        OPT_Z=$OPTARG
        # Validate input is a 0 or 1
        if ! [[ $OPT_Z =~ ^[0-1] ]]; then
          echo "Error: Invalid value for '-Z'. Requires 0 or 1."
          exit 1
        fi
        case $OPT_Z in
          0) OPT_Z=""
            ;;
          1) OPT_Z="-Z"
            ;;
        esac
        ;;    
      *) # Invalid argument
        display_usage "$0"
        exit 1
        ;;
      esac
   done

   # Sanity check verbosity levels
   if [ ${OPT_VERBOSITY} -gt 3 ]; then
     OPT_VERBOSITY=3
   fi

   # Ensure the user provided one of -c or -d options
   if [[ ${#CXL_NODES[@]} -eq 0 ]] && [[ ${#DRAM_NODES[@]} -eq 0 ]]; then
     echo "Error! You must provide either the '-c' or '-d' arguments with values"
     exit 1
   fi

   if [ ${#SOCKETS[@]} -eq 0 ]; then
     SOCKETS=("${DRAM_NODES[0]:-${CXL_NODES[0]}}")
   fi
}

# Create output directory
function init_outputs() {
   rm -rf "${OUTPUT_PATH}" 2> /dev/null
   mkdir "${OUTPUT_PATH}"
}

# Save STDOUT and STDERR to a log file
# arg1 = path to log file. If empty, save to current directory
function log_stdout_stderr {
  local LOG_PATH
  if [[ $1 != "" ]]; then
    # Use the specified path
    LOG_PATH=${1}
  else
    # Use current working directory
    LOG_PATH=$(pwd)
  fi
  LOG_FILE="${LOG_PATH}/${STDOUT_LOG_FILE}"
  # Capture STDOUT and STDERR to a log file, and display to the terminal
  if [[ ${TEE} != "" ]]; then
    # Use the tee approach
    exec &> >(${TEE} -a "${LOG_FILE}")
  else
    # Use the tail approach
    exec &> "${LOG_FILE}" && ${TAIL} "${LOG_FILE}"
  fi
}

# Review the system configuration and verify it meets the minimum requirements
function validate_config() {
  err_state=false # Used for error reporting

  # Confirm the system has at least two NUMA nodes. Exit if we find only one(1)
  NUMA_NODES_IN_SYSTEM=$(lscpu | ${GREP} "NUMA node(s)" | awk -F: '{print $2}' | xargs)
  if [[ "${NUMA_NODES_IN_SYSTEM}" -lt 2 ]]
  then
    echo "[Error] Only one NUMA Node found. A minumum of two(2) NUMA Nodes is required. Exiting!"
    err_state=true
    exit 1
  fi
  echo "INFO: Number of NUMA Node(s): ${NUMA_NODES_IN_SYSTEM}"

  # if the -c option is specified, confirm the system has at least one CXL device.
  NUM_CXL_DEVICES=$(lspci | ${GREP} -c "CXL")
  if [[ ${#CXL_NODES[@]} -gt 0 ]] && [[ "${NUM_CXL_DEVICES}" -lt 1 ]]
  then
    echo "[Error] No CXL devices found! A minimum of one CXL device is required. Exiting"
    err_state=true
    exit 1
  fi
}

function check_cpus() {
   TOKENS=( $(lscpu | ${GREP} "Core(s) per socket:") )
   CORES_PER_SOCKET=${TOKENS[3]}

   # Only using the CPUs on this NUMA node
   CPUS=$CORES_PER_SOCKET

   echo "CPU cores per socket: $CPUS"

   # One CPU used to measure latency, so the rest can be for bandwidth generation
   BW_CPUS=$((CPUS-1))
}

# Verify the user supplied socket number is valid on this system
function verify_cpu_socket() {
   SOCKETS_IN_SYSTEM=$( lscpu | ${GREP} "Socket(s):" | ${AWK} '{print $2}' )
   if [ -z "${SOCKETS_IN_SYSTEM}" ]; then
     echo "ERROR: verify_cpu_socket: Could not identify the number of sockets in this system. Exiting."
     exit 1
   fi
   if (( socket >= $SOCKETS_IN_SYSTEM )); then
      echo "ERROR: Socket ${socket} does not exist in this system. Valid sockets are 0-$(( SOCKETS_IN_SYSTEM - 1 )). Exiting."
      exit 1
   fi
}

# TODO: Auto-detect platform topology and run without requiring -s/-c/-d.
#   Today the caller must already know and pass every CPU socket, DRAM NUMA
#   node, and CXL NUMA node explicitly (this is why verify_numa_node() below
#   can only range-check a node id, not classify it - see its TODO). A full
#   auto-detect mode would need to:
#     - Enumerate CPU sockets from `lscpu -e` / `lscpu | grep "Socket(s):"`
#       (already partially done in get_cpu_socket_count) and populate
#       SOCKETS with every socket found, instead of requiring -s.
#     - Enumerate NUMA nodes from `numactl -H` / `lscpu -e=NODE` and classify
#       each as DRAM- or CXL-backed, e.g. by cross-referencing `cxl list -M`
#       (maps CXL memory devices/regions to their target NUMA node) and/or
#       `daxctl list`, or heuristically flagging CPU-less memory-only nodes
#       as CXL candidates - then populate DRAM_NODES/CXL_NODES automatically
#       instead of requiring -d/-c.
#     - Fall back to the current manual -s/-c/-d flags when detection is
#       ambiguous or the required tooling (cxl/daxctl) isn't installed,
#       rather than guessing wrong and mislabeling a node.
#     - Print the discovered topology (sockets, DRAM nodes, CXL nodes) as
#       part of the existing "Sweep plan" summary before running, so the
#       user can confirm/abort before a potentially large auto-swept run.
#   This would let mlc.sh be invoked with no topology args at all, e.g.
#   `sudo ./mlc.sh --auto`, and sweep everything the platform actually has.

# Verify the user supplied a DRAM/CXL NUMA node that is valid on this system
# TODO: Check if the specified NUMA node is DRAM or CXL. For now, we just make sure the user input is within the range of NUMA nodes for this system
function verify_numa_node() {
  NUMA_NODES_IN_SYSTEM=$( lscpu | ${GREP} "NUMA node(s):" | ${AWK} '{print $2}' )
  if [ -z "${NUMA_NODES_IN_SYSTEM}" ]; then
    echo "ERROR: verify_numa_node: Could not identify the number of NUMA nodes in this system. Exiting."
    exit 1
  fi
  if [[ OPT_CXL_NUMA_NODE -ge NUMA_NODES_IN_SYSTEM-1 ]] || 
     [[ OPT_CXL_NUMA_NODE -lt 0 ]]; then 
    echo "ERROR: CXL NUMA Node ${OPT_CXL_NUMA_NODE} does not exist in this system. Exiting"
  fi
  if [[ OPT_DRAM_NUMA_NODE -ge NUMA_NODES_IN_SYSTEM-1 ]] ||
     [[ OPT_DRAM_NUMA_NODE -lt 0 ]]; then
    echo "ERROR: DRAM NUMA Node ${OPT_DRAM_NUMA_NODE} does not exist in this system. Exiting"
  fi
}

# Verify if CPU Hyperthreading is enabled or disabled
function check_hyperthreading_enabled() {
   THREADS_PER_CORE=$( lscpu | ${GREP} "Thread(s) per core" | cut -f2 -d ":")
   if [ "${THREADS_PER_CORE}" -gt 1 ]; then
     CPU_HYPERTHREADING=true
   else
     CPU_HYPERTHREADING=false
   fi
   if [ "${OPT_VERBOSITY}" -ge 3 ]; then
     echo "DEBUG: check_hyperthreading_enabled: CPU Hyperthreading = ${CPU_HYPERTHREADING}"
   fi
}

function get_cpu_socket_count(){
  # Get the number of CPU Sockets within the platform
  SOCKETS_IN_SYSTEM=$(lscpu | ${GREP} "Socket(s)" | awk -F: '{print $2}' | xargs)
  echo "INFO: Number of Physcial Sockets: ${SOCKETS_IN_SYSTEM}"
}

function get_cores_per_socket_count() {
  # Get the number of cores per CPU Socket within the platform
  CORES_PER_SOCKET=$(lscpu | ${GREP} "Core(s) per socket:" | awk -F: '{print $2}' | xargs)
  echo "INFO: Number of Cores per Socke: ${CORES_PER_SOCKET}"
}

# Identify the CPU IDs per socket.
function get_cpu_range_per_socket(){
   CPU_RANGE=$( lscpu | ${GREP} "NUMA node${socket} CPU(s)" | cut -f2 -d ":" )
   if [ -z "${CPU_RANGE}" ]; then
     echo "ERROR: get_cpu_range_per_socket: Could not identify cpu range for socket ${socket}. Exiting"
     exit 1
   fi
   echo "CPUs on Socket $socket: $CPU_RANGE"
}

# Identifies the first CPU ID for the specified socket
function get_first_cpu_in_socket() {
   NUMA_CPUS=$( ${NUMACTL} --hardware | ${GREP} "node ${socket} cpus" | cut -f2 -d ":" )
   if [ -z "${NUMA_CPUS}" ]; then
     echo "ERROR: get_first_cpu_in_socket: Could not identify cpus for numa node ${socket}. Exiting"
     exit 1
   fi
   TOK=( ${NUMA_CPUS} )
   FIRST_CPU_ON_SOCKET=${TOK[0]}
}

# Identify the number of CPU Core(s) per socket
function get_cpu_cores_per_socket() {
   CPU_CORES_PER_SOCKET=$( lscpu | ${GREP} "Core(s) per socket" | cut -f2 -d ":" )
   if [ -z "${CPU_CORES_PER_SOCKET}" ]; then
     echo "ERROR: get_cpu_cores_per_socket: Could not identify cpu cores per socket for socket ${socket}. Exiting"
     exit 1
   fi
   if [ ${OPT_VERBOSITY} -ge 3 ]; then
     echo "DEBUG: get_cpu_cores_per_socket: Core(s) per socket = ${CPU_CORES_PER_SOCKET}"
   fi
}

# Identify the number of CPU Thread(s) per core
function get_cpu_threads_per_core() {
   CPU_THREADS_PER_CORE=$( lscpu | ${GREP} "Thread(s) per core" | cut -f2 -d ":" )
   if [ -z "${CPU_THREADS_PER_CORE}" ] ; then
     echo "ERROR: get_cpu_threads_per_core: Could not identify cpu threads for per core on socket ${socket}. Exiting"
     exit 1
   fi
   if [ ${OPT_VERBOSITY} -ge 3 ]; then
     echo "DEBUG: get_cpu_threads_per_core: Thread(s) per core = ${CPU_THREADS_PER_CORE}"
   fi
}

# Get the first vCPU on each socket
# Return the result in a global associative array
function get_first_vcpu_per_socket() {
  declare -a first_vcpu_on_socket

  for ((s=0; s<=$((SOCKETS_IN_SYSTEM-1)); s++))
  do
    first_vcpu=$(cat /sys/devices/system/node/node${s}/cpulist | cut -f1 -d"-")
    if [ -z "${first_vcpu}" ]; then
      echo "ERROR: Cannot determine the first vCPU on socket ${s}. Exiting."
      #exit 1
    fi
    first_vcpu_on_socket[${s}]=${first_vcpu}
    echo "First CPU on Socket ${s}: ${first_vcpu}"
  done
}

# Convert seconds to days, hours, minutes, and seconds
# Only print the days, hours, and mins if they are non-zero
# Input: arg1 = time in seconds (int), arg2 (optional) = String prefix, e.g. "Duration"
# Output: Prints a string with the conversion
function print_time() {
    local seconds=$1
    local prefix_str=$2
    local days=$((seconds / 86400))
    local hours=$((seconds / 3600 % 24))
    local minutes=$((seconds / 60 % 60))
    local seconds=$((seconds % 60))

    if [[ ! -z "${prefix_str}" ]]; then
      printf '%s ' $prefix_str
    fi

    if [[ $days -gt 0 ]]; then
      if [[ $days -eq 1 ]]; then
        printf '%d day ' $days
      elif [[ $days -gt 1 ]]; then
        printf '%d days ' $days
      fi
    fi

    if [[ $hours -gt 0 ]]; then
      if [[ $hours -eq 1 ]]; then
        printf '%d hour ' $hours
      elif [[ $hours -gt 1 ]]; then
        printf '%d hours ' $hours
      fi
    fi

    if [[ $minutes -gt 0 ]];then
      if [[ $minutes -eq 1 ]]; then
        printf '%d minute ' $minutes
      elif [[ $minutes -gt 1 ]]; then
        printf '%d minutes ' $minutes
      fi
    fi

    if [[ $seconds -eq 1 ]]; then
        printf '%d second\n' $seconds
    else
        printf '%d seconds\n' $seconds
    fi
}

# MLC Latency tests need at least 1000 x 2MiB pages per NUMA Node
function create_huge_pages() {
  # Hugepages need to be allocated using /proc/sys/vm/nr_hugepages 
  # Without large pages, the latencies are not accurate
  echo ""
  echo "--- Latency Matrix Tests ---"
  echo "Detected ${nr_hugepages} Huge pages."

  # Calculate how many large pages we need
  local nr_huge_pages_needed=$(( NUMA_NODES_IN_SYSTEM * 1001 ))

  # Intel recommends a minimum of 4000
  if [[ $nr_huge_pages_needed -lt 4000 ]]
  then
    nr_huge_pages_needed=4000
  fi

  if [[ $nr_hugepages -lt $nr_huge_pages_needed ]]
  then
    echo -n "The latency tests requires a minimum of ${nr_huge_pages_needed} hugepages for accuracy."
    if echo "${nr_huge_pages_needed}" > /proc/sys/vm/nr_hugepages
    then
      # Creating huge pages was successful 
      echo " Huge Pages Created Successfuly"
    else
      # Creating huge pages failed
      echo " Creation of Huge Pages Failed!"

      # Restore the original nr_hugepages value
      echo "${nr_hugepages}" > /proc/sys/vm/nr_hugepages
      return 1
    fi  
  fi 
}

# Restore the original huge page count when we're done testing
# so we don't cause any issues and leave a clean system
function restore_huge_page_count() {
  # Restore the original nr_hugepages value
  echo -n "Restoring original huge page config..."
  if echo "${nr_hugepages}" > /proc/sys/vm/nr_hugepages
  then
    # Restoring original values was successful
    echo " Success"
  else
    # Restoring failed
    echo " Failed"
  fi
}

# mlc.sh must run as root, so every file it writes ends up owned by root.
# Post-processing (gen_plot.py/gen_excel.py) is documented to run without
# root, so hand ownership of the output directory back to the invoking user
# (available via $SUDO_UID/$SUDO_USER when run as 'sudo ./mlc.sh ...') so
# they can read and write into it afterward.
function restore_output_ownership() {
  if [[ ! -d "${OUTPUT_PATH}" ]]; then
    return
  fi
  if [[ -n "${SUDO_UID:-}" ]] && [[ -n "${SUDO_GID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "${OUTPUT_PATH}"
  elif [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${OUTPUT_PATH}"
  else
    # Not invoked via sudo (e.g. logged in directly as root) - there's no
    # non-root user to hand ownership to, so just make sure it's accessible.
    chmod -R a+rwX "${OUTPUT_PATH}"
  fi
}

#################################################################################################
# Buffer sizing helpers (cache/capacity-aware)
#################################################################################################

# Count how many CPU IDs are covered by a range string like "0-95" or
# "0-23,48-71" (comma-separated list of single IDs and/or dash-ranges).
function count_cpus_in_range() {
  local range="$1"
  local total=0
  local part start end
  IFS=',' read -ra parts <<< "${range}"
  for part in "${parts[@]}"; do
    if [[ "${part}" == *-* ]]; then
      start=${part%-*}
      end=${part#*-}
      total=$(( total + end - start + 1 ))
    elif [[ -n "${part}" ]]; then
      total=$(( total + 1 ))
    fi
  done
  echo "${total}"
}

# Detect the size (KiB) of the last-level cache (LLC) for the socket that
# CPU <cpu_id> belongs to.
# Sets: LLC_SIZE_KB, LLC_LEVEL, LLC_SOURCE ("undetected" if nothing worked)
function detect_llc_size_kb() {
  local cpu_id="${1:-0}"
  LLC_SIZE_KB=0
  LLC_LEVEL=0
  LLC_SOURCE="undetected"

  # Preferred: `lscpu -C` (util-linux >= 2.37). ONE-SIZE is the size of a
  # single cache instance (i.e. this socket's LLC) - ALL-SIZE would be the
  # sum across every socket's instance, which is not what we want here.
  if lscpu -C=NAME,ONE-SIZE,LEVEL -B &> /dev/null; then
    local name size_b level
    while read -r name size_b level; do
      [[ "${level}" =~ ^[0-9]+$ ]] || continue
      [[ "${size_b}" =~ ^[0-9]+$ ]] || continue
      if (( level > LLC_LEVEL )) || { (( level == LLC_LEVEL )) && (( size_b / 1024 > LLC_SIZE_KB )); }; then
        LLC_LEVEL=${level}
        LLC_SIZE_KB=$(( size_b / 1024 ))
        LLC_SOURCE="lscpu -C"
      fi
    done < <(lscpu -C=NAME,ONE-SIZE,LEVEL -B 2> /dev/null | tail -n +2)
  fi

  if (( LLC_SIZE_KB == 0 )); then
    # Fallback for util-linux < 2.37 (no 'lscpu -C'): read cacheinfo directly
    # from a CPU on the target socket. Linux reports the *total* size of a
    # cache instance under every CPU that shares it, so reading cpu<cpu_id>
    # gives that socket's real LLC size, not a per-CPU share of it.
    local cache_dir level size_str size_kb
    for cache_dir in /sys/devices/system/cpu/cpu${cpu_id}/cache/index*; do
      [[ -d "${cache_dir}" ]] || continue
      level=$(cat "${cache_dir}/level" 2> /dev/null)
      size_str=$(cat "${cache_dir}/size" 2> /dev/null)
      [[ -z "${level}" || -z "${size_str}" ]] && continue
      size_kb=$(printf '%s' "${size_str}" | ${AWK} '
        /K$/ { gsub(/K/,""); print $0+0; next }
        /M$/ { gsub(/M/,""); print ($0+0)*1024; next }
        /G$/ { gsub(/G/,""); print ($0+0)*1024*1024; next }
        { print $0+0 }')
      [[ -z "${size_kb}" ]] && continue
      if (( level > LLC_LEVEL )) || { (( level == LLC_LEVEL )) && (( size_kb > LLC_SIZE_KB )); }; then
        LLC_LEVEL=${level}
        LLC_SIZE_KB=${size_kb}
        LLC_SOURCE="/sys cacheinfo (cpu${cpu_id})"
      fi
    done
  fi

  if (( LLC_SIZE_KB > 0 )); then
    echo "INFO: Detected L${LLC_LEVEL} (LLC) size: ${LLC_SIZE_KB} KiB ($(( LLC_SIZE_KB / 1024 )) MiB) via ${LLC_SOURCE}"
  else
    LLC_SOURCE="undetected"
    echo "WARNING: Could not auto-detect LLC size on this platform. Falling back to the legacy default buffer size (${BUF_SZ_LEGACY_DEFAULT} KiB/thread) - low-core-count bandwidth results may include cache-residency effects. Use -b to force an explicit buffer size instead."
  fi
}

# Detect free memory (KiB) on NUMA node <node_id> - the safety ceiling for
# buffer sizing so a cache-defeating buffer never tries to allocate more
# than the node under test actually has (e.g. a single small DRAM/CXL DIMM).
# Sets: NODE_FREE_KB (0 if undetectable)
function detect_node_capacity_kb() {
  local node_id="$1"
  NODE_FREE_KB=0
  local meminfo="/sys/devices/system/node/node${node_id}/meminfo"
  if [[ -r "${meminfo}" ]]; then
    NODE_FREE_KB=$(${AWK} -v n="${node_id}" '$0 ~ ("Node "n" MemFree:") {print $4}' "${meminfo}")
  fi
  if [[ -z "${NODE_FREE_KB}" || "${NODE_FREE_KB}" -eq 0 ]]; then
    # Fallback: parse `numactl -H`'s "node N free: X MB" line
    NODE_FREE_KB=$(${NUMACTL} -H 2> /dev/null | ${AWK} -v n="node ${node_id} free:" 'tolower($0) ~ n {print $4*1024}')
  fi
  NODE_FREE_KB=${NODE_FREE_KB:-0}
}

# Compute the per-thread MLC buffer size (KiB) for a bandwidth test:
# - Large enough that a single thread's own buffer already exceeds the
#   target socket's LLC by CACHE_DEFEAT_MARGIN, so the ramp is memory-bound
#   from the very first (1-thread) data point onward, not just at the tail.
# - Capped so the *aggregate* footprint at the highest thread count this
#   test will use (max_threads x buffer) never exceeds
#   NODE_CAPACITY_SAFE_FRACTION_PCT of any involved NUMA node's free memory -
#   critical for small pools (e.g. a single DIMM's worth of DRAM or CXL
#   capacity), where a full cache-defeating buffer simply will not fit.
# When the cap binds, low-core-count ramp points may retain some cache
# residency; this prints a clear warning so that is never silent, and
# gen_report.sh's sustained (tail-of-ramp) bandwidth column remains a valid
# ground truth regardless of whether the cap engaged.
# Usage: compute_buf_sz_kb <max_threads> <node_id> [<node_id2> ...]
# Requires: detect_llc_size_kb has already been called for the target socket
# Sets: BUF_SZ_KB, BUF_SZ_CAPPED (true/false)
function compute_buf_sz_kb() {
  local max_threads="$1"; shift
  local nodes=("$@")

  if [[ -n "${OPT_BUF_SZ_OVERRIDE}" ]]; then
    BUF_SZ_KB=${OPT_BUF_SZ_OVERRIDE}
    BUF_SZ_CAPPED=false
    echo "INFO: Using user-specified buffer size (-b): ${BUF_SZ_KB} KiB/thread"
    return
  fi

  local desired_kb
  if [[ "${LLC_SOURCE}" != "undetected" ]] && (( LLC_SIZE_KB > 0 )); then
    desired_kb=$(( LLC_SIZE_KB * CACHE_DEFEAT_MARGIN ))
  else
    desired_kb=${BUF_SZ_LEGACY_DEFAULT}
  fi

  local cap_kb=-1 node_cap n undetected_node=false
  for n in "${nodes[@]}"; do
    detect_node_capacity_kb "${n}"
    if (( NODE_FREE_KB > 0 )); then
      node_cap=$(( (NODE_FREE_KB * NODE_CAPACITY_SAFE_FRACTION_PCT / 100) / max_threads ))
      if (( cap_kb == -1 )) || (( node_cap < cap_kb )); then
        cap_kb=${node_cap}
      fi
    else
      undetected_node=true
    fi
  done
  if ${undetected_node}; then
    echo "WARNING: Could not determine free memory for at least one target NUMA node (${nodes[*]}) - proceeding without a capacity cap from that node."
  fi

  BUF_SZ_KB=${desired_kb}
  BUF_SZ_CAPPED=false
  if (( cap_kb >= 0 )) && (( cap_kb < desired_kb )); then
    BUF_SZ_KB=${cap_kb}
    BUF_SZ_CAPPED=true
  fi

  # Round down to the nearest MiB for a clean number; never below 1 MiB/thread
  # (a hard sanity floor, not a target - if capacity forces us this low,
  # cache-defeat is effectively unachievable and the warning below says so).
  BUF_SZ_KB=$(( (BUF_SZ_KB / 1024) * 1024 ))
  if (( BUF_SZ_KB < 1024 )); then
    BUF_SZ_KB=1024
  fi

  if ${BUF_SZ_CAPPED}; then
    echo "WARNING: Buffer size capped to ${BUF_SZ_KB} KiB/thread ($(( BUF_SZ_KB / 1024 )) MiB) by target NUMA node capacity (node(s): ${nodes[*]}) - wanted ${desired_kb} KiB/thread ($(( desired_kb / 1024 )) MiB, ${CACHE_DEFEAT_MARGIN}x detected LLC) to fully defeat the L${LLC_LEVEL} cache (${LLC_SIZE_KB} KiB) at every core count tested. Low-core-count results for this test may retain partial cache residency - treat the sustained (max-core) bandwidth as ground truth."
  else
    echo "INFO: Buffer size: ${BUF_SZ_KB} KiB/thread ($(( BUF_SZ_KB / 1024 )) MiB) - ${CACHE_DEFEAT_MARGIN}x detected L${LLC_LEVEL} LLC (${LLC_SIZE_KB} KiB / $(( LLC_SIZE_KB / 1024 )) MiB) via ${LLC_SOURCE}"
  fi
}

#################################################################################################
# Metric measuring functions
#################################################################################################

# Run the latency matrix test where the latency from CPU 'C' to memory node 'M' is tested
function latency_matrix() {
  # Run the test
  ${MLC} --latency_matrix ${OPT_X} > "${OUTPUT_PATH}/latency_matrix.txt"
  # Display the results
  awk '$1 ~ /^[0-9]+$/ || $1 == "numa"' "${OUTPUT_PATH}/latency_matrix.txt"
}

# Run idle latency test against a specified NUMA node (DRAM or CXL)
# idle_latency(NUMANode)
function idle_latency() {
   get_first_cpu_in_socket

   echo ""
   echo "--- Idle Latency Tests ---"
   echo "Using CPU ${FIRST_CPU_ON_SOCKET}"
   echo "Using NUMA Node $1"
   echo -n "Idle sequential latency: "
   ${MLC} --idle_latency -c"${FIRST_CPU_ON_SOCKET}" -j$1 ${OPT_X} > "$OUTPUT_PATH/idle_latency_seq_numa_node_$1.socket_${socket}.txt"
   ${GREP} "Each iteration took" $OUTPUT_PATH/idle_latency_seq_numa_node_$1.socket_${socket}.txt

   echo -n "Idle random latency: "
   ${MLC} --idle_latency -c"${FIRST_CPU_ON_SOCKET}" -l256 -j"$1" -r ${OPT_X} > "$OUTPUT_PATH/idle_latency_rand_numa_node_$1.socket_${socket}.txt"
   ${GREP} "Each iteration took" $OUTPUT_PATH/idle_latency_rand_numa_node_$1.socket_${socket}.txt
   echo "--- End ---"
}

# Use all available CPUs on the specified socket to run MLC
# Note: Depending on the number of PMem devices, power budget, BIOS settings, and other factors, this may not 
#       yield the maximum bandwidth. Use ramp_bandwidth() to check bandwidth using different CPU counts.
#
# MLC Traffic Type
# ----------------
# Instead of generating 100% reads as in the default case, -W3 will select 3 reads and 1
# write to memory. The following are the possible options for –Wn where n can take the
# following values (reads and writes are as observed on the memory controller):
# W2 =  2 reads and 1 write22
# W3 =  3 reads and 1 write
# W5 =  1 read and 1 write
# W6 =  100% non-temporal write
# W7 =  2 reads and 1 non-temporal write
# W8 =  1 read and 1 non-temporal write
# W9 =  3 reads and 1 non-temporal write
# W10 = 2 reads and 1 non-temporal write (similar to stream triad)
#    (same as -W7 but the 2 reads are from 2 different buffers while those 2
#    reads are from a single buffer on –W7)
# W11 = 3 reads and 1 write
#    (same as –W3 but the 2 reads are from 2 different buffers while those 2
#    reads are from a single buffer on –W3)
# W12 = 4 reads and 1 write

# Arg0: DRAM or CXL NUMA Node to test
# TODO: If '-X' was specified, use all CPU threads, otherwise use the first thread on each core in ${CPU_RANGE}
function bandwidth() {
   get_first_cpu_in_socket
   echo ""
   echo "--- Bandwidth Tests ---"
   echo "Using CPUs: ${CPU_RANGE}"
   echo "Using Memory NUMA Node $1"
   detect_llc_size_kb "${FIRST_CPU_ON_SOCKET}"
   compute_buf_sz_kb "$(count_cpus_in_range "${CPU_RANGE}")" "$1"
   BW_ARRAY=(
      #CPUs         Traffic type   seq or rand  buffer size   dram           dram node     output filename
      "${CPU_RANGE} R              seq          $BUF_SZ_KB    dram           $1            bw_node$1_seq_READ.socket_${socket}.txt"
      "${CPU_RANGE} R              rand         $BUF_SZ_KB    dram           $1            bw_node$1_rnd_READ.socket_${socket}.txt"
      "${CPU_RANGE} W6             seq          $BUF_SZ_KB    dram           $1            bw_node$1_seq_WRITE_NT.socket_${socket}.txt"
      "${CPU_RANGE} W6             rand         $BUF_SZ_KB    dram           $1            bw_node$1_rnd_WRITE_NT.socket_${socket}.txt"
      "${CPU_RANGE} W7             seq          $BUF_SZ_KB    dram           $1            bw_node$1_seq_2READ_1WRITE_NT.socket_${socket}.txt"
      "${CPU_RANGE} W7             rand         $BUF_SZ_KB    dram           $1            bw_node$1_rnd_2READ_1WRITE_NT.socket_${socket}.txt"
      "${CPU_RANGE} W5             seq          $BUF_SZ_KB    dram           $1            bw_node$1_seq_1READ_1WRITE.socket_${socket}.txt"
      "${CPU_RANGE} W5             rand         $BUF_SZ_KB    dram           $1            bw_node$1_rnd_1READ_1WRITE.socket_${socket}.txt"
      "${CPU_RANGE} W2             seq          $BUF_SZ_KB    dram           $1            bw_node$1_seq_2READ_1WRITE.socket_${socket}.txt"
      "${CPU_RANGE} W2             rand         $BUF_SZ_KB    dram           $1            bw_node$1_rnd_2READ_1WRITE.socket_${socket}.txt"
   )
  
   # Run a test for each entry in the BW_ARRAY
   for LN in "${BW_ARRAY[@]}"; do
      TOK=( $LN )
      echo ${TOK[0]} ${TOK[1]} ${TOK[2]} ${TOK[3]} ${TOK[4]} ${TOK[5]} > tmp_bw_testfile
      echo -n "Memory bandwidth for ${TOK[6]} (MiB/sec): "
      ${NUMACTL} -N ${socket} ${MLC} --loaded_latency -d0 -otmp_bw_testfile -t${SAMPLE_TIME} -T ${OPT_Z} ${OPT_X} > ${OUTPUT_PATH}/${TOK[6]}
      cat ${OUTPUT_PATH}/${TOK[6]} | ${SED} -n -e '/==========================/,$p' | tail -n+2 | ${AWK} '{print $3}'
      sleep 3
   done
   echo "--- End ---"
   rm tmp_bw_testfile
}

# Collect bandwidth and latency stats for a single NUMA node using a ramp of CPUs used for the test
# arg0/$1 = NUMA Node to test
function bandwidth_ramp() {
  get_first_cpu_in_socket
  local MEM_NUMA_NODE=$1
  local is_dram_node=false
  for _n in "${DRAM_NODES[@]}"; do
    if [[ "${_n}" -eq ${MEM_NUMA_NODE} ]]; then
      is_dram_node=true
      break
    fi
  done
  if ${is_dram_node}
  then
    # Testing DRAM
    ratiostr="100:0"
  else
    # Testing CXL
    ratiostr="0:100"
  fi

  # Output CSV file headings
  local OutputCSVHeadings="Socket,Node,DRAM:CXL Ratio,NUMA Node Tested,Num of Cores,IO Pattern,Access Pattern,Latency(ns),Bandwidth(MB/s)"

  detect_llc_size_kb "${FIRST_CPU_ON_SOCKET}"
  compute_buf_sz_kb "${CORES_PER_SOCKET}" "${MEM_NUMA_NODE}"

  echo "=== Collecting Memory Node ${MEM_NUMA_NODE} bandwidth using Socket ${socket} ==="
  for (( c=0; c<=${CORES_PER_SOCKET}-1; c=c+${IncCPU} ))
  do
    TO_CPU=`expr ${FIRST_CPU_ON_SOCKET} + ${c}`
    # Build the input file
    for rdwr in R
    do
      # Random bandwidth option is supported only for R, W2, W5 and W6 traffic types
      for access in seq rand
      do
        echo "${FIRST_CPU_ON_SOCKET}-${TO_CPU} ${rdwr} ${access} ${BUF_SZ_KB} dram ${MEM_NUMA_NODE}" > mlc_loaded_latency.input
        #numactl --membind=0 mlc/mlc --peak_injection_bandwidth -k1-${c}
        ${MLC} -i${FIRST_CPU_ON_SOCKET} --loaded_latency -gmlc_injection.delay -omlc_loaded_latency.input ${OPT_X}
        # Save the results to a CSV file
        # Print headings to the CSV file on first access
        if [[ ${c} -eq 0 ]]
        then
          echo "${OutputCSVHeadings}" > "${OUTPUT_PATH}/bw_ramp.results.node_${MEM_NUMA_NODE}.${rdwr}.${access}.${ratiostr}.socket_${socket}.csv"
        fi
        # Extract the Latency and Bandwidth results from the log file
        LatencyResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $2}')
        BandwidthResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $3}')
        echo "${socket},DRAM:CXL,\"${ratiostr}\",${MEM_NUMA_NODE},${c},${rdwr},${access},${LatencyResult},${BandwidthResult}" >> "${OUTPUT_PATH}/bw_ramp.results.node_${MEM_NUMA_NODE}.${rdwr}.${access}.${ratiostr}.socket_${socket}.csv"
      done
    done
  done
}

# Collect DRAM + CXL Interleaved workloads
# arg0/$1 = DRAM NUMA Node
# arg1/$2 = CXL NUMA Node
function bandwidth_ramp_interleave() {
  get_first_cpu_in_socket
  local DRAM_NUMA_NODE=$1
  local CXL_NUMA_NODE=$2
  local ratiostr="0:0"

  # Output CSV file headings
  local OutputCSVHeadings="Socket,Node,DRAM:CXL Ratio,Num of Cores,IO Pattern,Access Pattern,Latency(ns),Bandwidth(MB/s)"

  detect_llc_size_kb "${FIRST_CPU_ON_SOCKET}"
  # A single per-thread buffer is split across both nodes by ratio (10/25/50%),
  # so either node could end up holding a large share of it depending on the
  # ratio under test - size against both nodes' capacity, not just one, to
  # keep the buffer size (and thus the methodology) identical across every
  # ratio/traffic-type combination tested against this DRAM/CXL pair.
  compute_buf_sz_kb "${CORES_PER_SOCKET}" "${DRAM_NUMA_NODE}" "${CXL_NUMA_NODE}"

  echo "=== Collecting DRAM + CXL interleaved stats using Socket ${socket} with Memory Nodes DRAM:${DRAM_NUMA_NODE}, CXL:${CXL_NUMA_NODE} ==="
  for (( c=0; c<=${CORES_PER_SOCKET}-1; c=c+${IncCPU} ))
  do
    TO_CPU=`expr ${FIRST_CPU_ON_SOCKET} + ${c}`
    # Build the input file
    # File format:
    # CPU RdWr Access Buf_Sz Node0 Node 1 Ratio
    # 0-2 W21 seq 40000 dram 0 dram 1 25
    #
    # W21 : 100% reads (similar to –R)
    # W23 : 3 reads and 1 write (similar to –W3)
    # W27 : 2 reads and 1 non-temporal write (similar to –W7)
    for rdwr in W21 W23 W27 
    do
      # MLC's dual-address-stream (interleave) per-thread-config path only supports
      # random access for traffic types R, W2, W5, and W6 ("Random bandwidth option
      # is supported only for R, W2, W5 and W6 traffic types!"). W21/W23/W27 are the
      # only codes valid in this dual-stream path and none of them are in that set,
      # so random access can never succeed here - only seq is attempted.
      for access in seq
      do
        for ratio in 10 25 50
        do 
          # Ratio 50 is only supported by W21
          if [[ ("${rdwr}" == "W23" || "${rdwr}" == "W27") && ${ratio} -eq 50 ]]
          then
            continue
          fi

          # Print headings to the CSV file on first access
          if [[ ${c} -eq 0 ]]
          then
            echo "${OutputCSVHeadings}" > "${OUTPUT_PATH}/bw_ramp_interleave.results.node_${DRAM_NUMA_NODE}.node_${CXL_NUMA_NODE}.${rdwr}.${access}.${ratio}.socket_${socket}.csv"
          fi

          # Generate the input file for MLC
          echo "${FIRST_CPU_ON_SOCKET}-${TO_CPU} ${rdwr} ${access} ${BUF_SZ_KB} dram ${DRAM_NUMA_NODE} dram ${CXL_NUMA_NODE} ${ratio}" > mlc_loaded_latency.input

          # Run MLC
          ${MLC} -i${FIRST_CPU_ON_SOCKET} --loaded_latency -gmlc_injection.delay -omlc_loaded_latency.input ${OPT_X}

          # Extract the Latency and Bandwidth results
          LatencyResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $2}')
          BandwidthResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $3}')
          ratiostr="$(( 100 - ratio )):${ratio}"
          echo "${socket},DRAM:CXL,\"${ratiostr}\",${c},${rdwr},${access},${LatencyResult},${BandwidthResult}" >> "${OUTPUT_PATH}/bw_ramp_interleave.results.node_${DRAM_NUMA_NODE}.node_${CXL_NUMA_NODE}.${rdwr}.${access}.${ratio}.socket_${socket}.csv"
        done 
      done
    done
  done
}

# Remove all temporary files created for this test
function cleanup() {
  rm -f mlc_injection.delay mlc_loaded_latency.input tmp_bw_testfile
}


#################################################################################################
# Main
#################################################################################################

# --compare is a standalone mode: diff two prior mlc.sh output directories
# (or their summary_report.json files directly) and write a comparison
# report. It needs neither root nor the mlc binary, so it's handled here,
# before argument parsing and the root check below.
if [[ "${1:-}" == "--compare" ]]; then
  shift
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 --compare <run_A_dir_or_json> <run_B_dir_or_json> [-o <output.md>] [-t <threshold_pct>]"
    exit 1
  fi
  exec python3 "${SCRIPT_DIR}/utils/gen_compare.py" "$@"
fi

# Process the command line arguments
process_args $@

# Verify this script is executed as the root user
# (checked after argument parsing so --help/-h/-? and validation errors
# don't require root just to be displayed - root is only needed once we
# actually start running privileged commands below)
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Verify the mandatory and optional tools and utilities are installed
verify_cmds

# Add the current working directory to $PATH
export PATH=.:${PATH}

# Initialize the data collection directory
init_outputs

# Save STDOUT and STDERR logs to the data collection directory
log_stdout_stderr "${OUTPUT_PATH}"

# Display the header information
display_start_info "$*"

check_cpus
get_cpu_socket_count
get_cores_per_socket_count
get_first_vcpu_per_socket
check_hyperthreading_enabled
validate_config

# Create the MLC Loaded Latency input file if needed
# The default is to have zero (0) delay between operations. 
if [[ ! -f mlc_injection.delay ]]
then
  echo "Creating 'mlc_injection.delay'"
  echo 0 > mlc_injection.delay
fi

# Execute tests
# TODO: Log the date/time when each test starts
# TODO: Support a quiet mode that only displays the test and result, and excludes the "Thread id CXX, traffic pattern P, ..."
if [[ ${#DRAM_NODES[@]} -gt 1 ]] || [[ ${#CXL_NODES[@]} -gt 1 ]] || [[ ${#SOCKETS[@]} -gt 1 ]]; then
  echo "=== Sweep plan ==="
  echo "Sockets    (${#SOCKETS[@]}): ${SOCKETS[*]}"
  echo "DRAM nodes (${#DRAM_NODES[@]}): ${DRAM_NODES[*]}"
  echo "CXL nodes  (${#CXL_NODES[@]}): ${CXL_NODES[*]}"
  echo "Interleave pairs per socket: $(( ${#DRAM_NODES[@]} * ${#CXL_NODES[@]} ))"
  echo "Interleave pairs total (all sockets): $(( ${#DRAM_NODES[@]} * ${#CXL_NODES[@]} * ${#SOCKETS[@]} ))"
fi

create_huge_pages

# latency_matrix
# Run the full test sequence once per socket in the list.
for socket in "${SOCKETS[@]}"; do
  # Recompute CPU_RANGE for this socket (used by bandwidth())
  get_cpu_range_per_socket

  # Test idle_latency for every CXL and DRAM node provided
  for node in "${CXL_NODES[@]}"; do
    idle_latency "${node}"
  done

  for node in "${DRAM_NODES[@]}"; do
    idle_latency "${node}"
  done

  # Test bandwidth for every CXL and DRAM node provided
  for node in "${CXL_NODES[@]}"; do
    bandwidth "${node}"
  done

  for node in "${DRAM_NODES[@]}"; do
    bandwidth "${node}"
  done

  # Test bandwidth ramp up for every CXL and DRAM node provided
  for node in "${CXL_NODES[@]}"; do
    bandwidth_ramp "${node}"
  done

  for node in "${DRAM_NODES[@]}"; do
    bandwidth_ramp "${node}"
  done

  # If the user provided both DRAM and CXL nodes, test interleaving for every DRAM x CXL pair
  if [[ ${#CXL_NODES[@]} -gt 0 ]] && [[ ${#DRAM_NODES[@]} -gt 0 ]]; then
    for d in "${DRAM_NODES[@]}"; do
      for c in "${CXL_NODES[@]}"; do
        bandwidth_ramp_interleave "${d}" "${c}"
      done
    done
  fi
done

restore_huge_page_count

# Generate the Markdown summary report (pure bash, no Python dependency).
# Non-fatal - a report-generation problem should never abort a completed run.
bash "${SCRIPT_DIR}/utils/gen_report.sh" "${OUTPUT_PATH}" || echo "WARNING: report generation failed"

restore_output_ownership

echo ""
echo "To generate charts from the CSV results, run:"
echo "  ${SCRIPT_DIR}/utils/.venv/bin/python ${SCRIPT_DIR}/utils/gen_plot.py -d \"${OUTPUT_PATH}\""

# TODO: Zip the output directory

# Display the end header information
display_end_info

# Cleanup
cleanup
