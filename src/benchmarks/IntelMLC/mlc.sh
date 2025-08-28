#!/usr/bin/env bash 

# Add the current working directory to $PATH
pushd $PWD &> /dev/null

# This script will run a series of Intel(R) MLC peak bandwidth tests
# using DRAM and CXL memory expansion.

#################################################################################################
# Global Variables
#################################################################################################

VERSION="0.2.0"             # version string

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
socket=                       # -s argument to specify the CPU socket to run MLC, default OPT_DRAM_NUMA_NODE
OPT_VERBOSITY=0               # default, -v, -vv, -vvv option to increase verbose output
OPT_LOADED_LATENCY=false      # default, -l to override and perform loaded latency testing
OPT_X=""                      # default, -X to override and use all cpu threads on all cores
OPT_Z="-Z"                    # default, -Z to override and AVX-512 64-byte load/store instructions
OPT_CXL_NUMA_NODE=-1          # default, -c to override and use the user specified NUMA Node backed by CXL
OPT_DRAM_NUMA_NODE=-1         # default, -d to override and use the user specified NUMA Node backed by DRAM

# MLC Options
SAMPLE_TIME=30                # default, -t argument to MLC
BUF_SZ=40000                  # MLC Buffer Size

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
   echo "Usage: $0 -c <CXL NUMA Node ID> -d <DRAM NUMA Node ID> [optional args]"
   echo " "
   echo "Runs bandwidth and latency tests on DRAM and CXL Type 3 Memory using Intel MLC"
   echo "Run with root privilege (MLC needs it)"
   echo " "
   echo "Optional args:"
   echo " "
   echo "   -c <CXL NUMA Node>"
   echo "      Required. Specify the NUMA Node backed by CXL for testing"
   echo " "
   echo "   -d <DRAM NUMA Node>"
   echo "      Required. Specify the NUMA Node backed by DRAM for testing"
   echo " "
   echo "   -m <Path to MLC executable>"
   echo "      Specify the path to the MLC executable"
   echo " "
   echo "   -s <Socket>"
   echo "      Specify which CPU socket should be used for running mlc"
   echo "      By default, CPU Socket 0 is used to run mlc"
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
   exit 0
}

# Process command arguments and options
function process_args() {

   # Process the command arguments and options
   while getopts "h?c:d:m:s:vXZ:" opt; do
      case "$opt" in
      h|\?)
        display_usage "$0"
        ;;
      c) # Set the CXL NUMA Node ID to test
        OPT_CXL_NUMA_NODE=$OPTARG
        # Validate input is a numeric value
        if ! [[ $OPT_CXL_NUMA_NODE =~ ^[0-9]+$ ]]
        then
          echo "Error: Invalid value for '-c'. Requires an integer value."
          exit 1
        fi
        ;;
      d) # Set the DRAM NUMA Node ID to test
        OPT_DRAM_NUMA_NODE=$OPTARG
        # Validate input is a numeric value
        if ! [[ $OPT_DRAM_NUMA_NODE =~ ^[0-9]+$ ]]; then
          echo "Error: Invalid value for '-d'. Requires an integer value."
          exit 1
        fi
        ;;
      m) # Set the location of the mlc binary 
        MLC=$OPTARG
        ;;
      s) # Specify which CPU socket to execute MLC on
        socket=$OPTARG
        # Validate input is a numeric value
        if ! [[ $socket =~ ^[0-9]+$ ]]; then
          echo "Error: Invalid value for '-s'. Requires an integer value."
          exit 1
        fi
        verify_cpu_socket
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
   if [[ $OPT_CXL_NUMA_NODE -eq -1 ]] && [[ $OPT_DRAM_NUMA_NODE -eq -1 ]]; then
     echo "Error! You must provide either the '-c' or '-d' arguments with values"
     exit 1
   fi

   if [ -z "$socket" ]; then
     socket=$OPT_DRAM_NUMA_NODE
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
  if [[ ${OPT_CXL_NUMA_NODE} -ge 0 ]] && [[ "${NUM_CXL_DEVICES}" -lt 1 ]]
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
   ${MLC} --idle_latency -c"${FIRST_CPU_ON_SOCKET}" -j$1 ${OPT_X} > "$OUTPUT_PATH/idle_latency_seq_numa_node_$1.txt"
   ${GREP} "Each iteration took" $OUTPUT_PATH/idle_latency_seq_numa_node_$1.txt

   echo -n "Idle random latency: "
   ${MLC} --idle_latency -c"${FIRST_CPU_ON_SOCKET}" -l256 -j"$1" -r ${OPT_X} > "$OUTPUT_PATH/idle_latency_rand_numa_node_$1.txt"
   ${GREP} "Each iteration took" $OUTPUT_PATH/idle_latency_rand_numa_node_$1.txt
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
   BW_ARRAY=(
      #CPUs         Traffic type   seq or rand  buffer size   dram           dram node     output filename
      "${CPU_RANGE} R              seq          $BUF_SZ       dram           $1            bw_node$1_seq_READ.txt"
      "${CPU_RANGE} R              rand         $BUF_SZ       dram           $1            bw_node$1_rnd_READ.txt"
      "${CPU_RANGE} W6             seq          $BUF_SZ       dram           $1            bw_node$1_seq_WRITE_NT.txt"
      "${CPU_RANGE} W6             rand         $BUF_SZ       dram           $1            bw_node$1_rnd_WRITE_NT.txt"
      "${CPU_RANGE} W7             seq          $BUF_SZ       dram           $1            bw_node$1_seq_2READ_1WRITE_NT.txt"
      "${CPU_RANGE} W7             rand         $BUF_SZ       dram           $1            bw_node$1_rnd_2READ_1WRITE_NT.txt"
      "${CPU_RANGE} W5             seq          $BUF_SZ       dram           $1            bw_node$1_seq_1READ_1WRITE.txt"
      "${CPU_RANGE} W5             rand         $BUF_SZ       dram           $1            bw_node$1_rnd_1READ_1WRITE.txt"
      "${CPU_RANGE} W2             seq          $BUF_SZ       dram           $1            bw_node$1_seq_2READ_1WRITE.txt"
      "${CPU_RANGE} W2             rand         $BUF_SZ       dram           $1            bw_node$1_rnd_2READ_1WRITE.txt"
   )
  
   # Run a test for each entry in the BW_ARRAY
   for LN in "${BW_ARRAY[@]}"; do
      TOK=( $LN )
      echo ${TOK[0]} ${TOK[1]} ${TOK[2]} ${TOK[3]} ${TOK[4]} ${TOK[5]} > tmp_bw_testfile
      echo -n "Memory bandwidth for ${TOK[6]} (MiB/sec): "
      if [ ${OPT_Z} == 1 ]; then
        if [ ${TOK[1]} == "W7" ]; then
          Z="-Z"
        else
          Z=""
        fi
      fi
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
  if [[ ${OPT_DRAM_NUMA_NODE} -eq ${MEM_NUMA_NODE} ]]
  then
    # Testing DRAM
    ratiostr="100:0"
  else
    # Testing CXL
    ratiostr="0:100"
  fi

  # Output CSV file headings
  local OutputCSVHeadings="Node,DRAM:CXL Ratio,NUMA Node Tested,Num of Cores,IO Pattern,Access Pattern,Latency(ns),Bandwidth(MB/s)"
  
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
        echo "${FIRST_CPU_ON_SOCKET}-${TO_CPU} ${rdwr} ${access} ${BUF_SZ} dram ${MEM_NUMA_NODE}" > mlc_loaded_latency.input
        #numactl --membind=0 mlc/mlc --peak_injection_bandwidth -k1-${c}
        ${MLC} -i${FIRST_CPU_ON_SOCKET} --loaded_latency -gmlc_injection.delay -omlc_loaded_latency.input ${OPT_X}
        # Save the results to a CSV file
        # Print headings to the CSV file on first access
        if [[ ${c} -eq 0 ]]
        then
          echo "${OutputCSVHeadings}" > "${OUTPUT_PATH}/bw_ramp.results.node_${MEM_NUMA_NODE}.${rdwr}.${access}.${ratiostr}.csv"
        fi
        # Extract the Latency and Bandwidth results from the log file
        LatencyResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $2}')
        BandwidthResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $3}')
        echo "DRAM:CXL,\"${ratiostr}\",${MEM_NUMA_NODE},${c},${rdwr},${access},${LatencyResult},${BandwidthResult}" >> "${OUTPUT_PATH}/bw_ramp.results.node_${MEM_NUMA_NODE}.${rdwr}.${access}.${ratiostr}.csv"
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
  local OutputCSVHeadings="Node,DRAM:CXL Ratio,Num of Cores,IO Pattern,Access Pattern,Latency(ns),Bandwidth(MB/s)"

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
      # Random bandwidth option is supported only for R, W2, W5 and W6 traffic types
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
            echo "${OutputCSVHeadings}" > "${OUTPUT_PATH}/bw_ramp_interleave.results.node_${DRAM_NUMA_NODE}.node_${CXL_NUMA_NODE}.${rdwr}.${access}.${ratio}.csv"
          fi

          # Generate the input file for MLC
          echo "${FIRST_CPU_ON_SOCKET}-${TO_CPU} ${rdwr} ${access} ${BUF_SZ} dram ${DRAM_NUMA_NODE} dram ${CXL_NUMA_NODE} ${ratio}" > mlc_loaded_latency.input

          # Run MLC
          ${MLC} -i${FIRST_CPU_ON_SOCKET} --loaded_latency -gmlc_injection.delay -omlc_loaded_latency.input

          # Extract the Latency and Bandwidth results
          LatencyResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $2}')
          BandwidthResult=$(tail -n 4 "${LOG_FILE}" | ${GREP} '00000' | awk '{print $3}')
          ratiostr="$(( 100 - ratio )):${ratio}"
          echo "DRAM:CXL,\"${ratiostr}\",${c},${rdwr},${access},${LatencyResult},${BandwidthResult}" >> "${OUTPUT_PATH}/bw_ramp_interleave.results.node_${DRAM_NUMA_NODE}.node_${CXL_NUMA_NODE}.${rdwr}.${access}.${ratio}.csv"
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

# Verify this script is executed as the root user
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Process the command line arguments
process_args $@

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
get_cpu_range_per_socket
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
create_huge_pages

# latency_matrix
# Test idle_latency if -c or -d were provided
if [[ $OPT_CXL_NUMA_NODE -ge 0 ]]; then
  idle_latency "${OPT_CXL_NUMA_NODE}"
fi

if [[ $OPT_DRAM_NUMA_NODE -ge 0 ]]; then
  idle_latency "${OPT_DRAM_NUMA_NODE}"
fi

# Test bandwidth if -c or -d were provided
if [[ $OPT_CXL_NUMA_NODE -ge 0 ]]; then
  bandwidth "${OPT_CXL_NUMA_NODE}"
fi

if [[ $OPT_DRAM_NUMA_NODE -ge 0 ]]; then
  bandwidth "${OPT_DRAM_NUMA_NODE}"
fi

# Test bandwidth ramp up if -c or -d were provided
if [[ $OPT_CXL_NUMA_NODE -ge 0 ]]; then
  bandwidth_ramp "${OPT_CXL_NUMA_NODE}"
fi

if [[ $OPT_DRAM_NUMA_NODE -ge 0 ]]; then
  bandwidth_ramp "${OPT_DRAM_NUMA_NODE}"
fi

# If the user provided a DRAM and CXL node, test interleaving
if [[ $OPT_CXL_NUMA_NODE -ge 0 ]] && [[ $OPT_DRAM_NUMA_NODE -ge 0 ]]; then
  bandwidth_ramp_interleave "${OPT_DRAM_NUMA_NODE}" "${OPT_CXL_NUMA_NODE}"
fi

restore_huge_page_count

# TODO: Generate charts using the CSV files

# TODO: Zip the output directory

# Display the end header information
display_end_info

# Cleanup
cleanup
