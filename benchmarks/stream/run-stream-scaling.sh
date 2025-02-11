#!/usr/bin/env bash

SCRIPT_DIR_NAME=$( dirname $( readlink -f $0 ))

function print_usage()
{
    echo "Usage:  $0 "
    echo -e "$(basename $0): Usage"
    echo "    $(basename $0) "
    echo "      -t dram|cxl      : test type"
    echo "                       : dram:       Use only DRAM Memory"
    echo "                       : cxl:        Use only CXL Memory"
    echo "      -c <numa-node>   : CXL Node Number - REQUIRED"
    echo "      -d <dram-node>   : DRAM Node Number - REQUIRED"
    echo "      -n <ntimes>      : Amount of repetitions (default to 100)"
    echo "      -a <size>        : Array size to allocate (default to 430_080_000)"
    exit 0
}

# Installing packages on Debian-based and Fedora systems if said packages do not exist
function check_dependencies()
{
    echo "[INFO]: Checking that all dependencies are in order"

    if command -v yum &> /dev/null; then
        if ! yum list installed numactl-devel; then
            echo "Detected Fedora. Installing numa.h with yum."
            sudo yum install -y numactl-devel
        fi
    elif command -v dpkg &>/dev/null; then
        if ! dpkg -l | grep -q "libnuma-dev"; then
            echo "Detected Debian-based system. Installing numa.h with apt."
            sudo apt-get update
            sudo apt-get install -y libnuma-dev
        fi
    else
        echo "Only Debian-based and Fedora systems are supported at the moment"
        exit 1
    fi
}

CPU_MODE=

function check_and_set_cpu_freq_scaling()
{
    CPU_MODE=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | uniq)

    if [ "${CPU_MODE}" != "performance" ]; then
        echo "[INFO]: Setting the CPU frequency scaling governor to performance mode"

        echo "performance" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    fi
}

function reset_cpu_freq_scaling()
{
    echo "[INFO]: Resetting the CPU frequency scaling governor to what it was before the benchmark"

    if [ "${CPU_MODE}" != "performance" ]; then
        echo "[INFO]: Setting CPU cores back to ${CPU_MODE} mode"
        echo "${CPU_MODE}" | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    fi
}

USE_CXL=
function validate_test_type()
{
    # Validate input arguments
    if [ -z "${TEST_TYPES}" ];
    then
        echo "[ERROR] Test type -t is required"
        print_usage
        exit 1
    fi

    IFS=',' read -ra TYPE <<< "$TEST_TYPES"
    for i in "${TYPE[@]}"; do
        case "$i" in
        dram)
            DRAM_TEST=1
            ;;
        cxl)
            CXL_TEST=1
            USE_CXL=1
            ;;
        *)
            echo "[ERROR] Unknown test type encountered"
            print_usage
            exit 1
            ;;
        esac
    done
}


# function to check the nodes being passed
function check_dram_nodes()
{
    # DRAM NODE
    echo "[INFO] Validate DRAM node ${DRAM_NODE_NUMBER}"

    # Check if the node exists
    if ! numactl -H | grep -q "node ${DRAM_NODE_NUMBER} "; then
        echo "[ERROR] Node ${DRAM_NODE_NUMBER} does not exist"
        exit 1
    fi

    # Check if there are any CPUs associated with the DRAM node
    cpu_list=$(numactl -H | grep "node ${DRAM_NODE_NUMBER} cpus:" | awk '{print $4}')
    if [ -z "${cpu_list}" ]; then
        echo "[ERROR] No CPUs found for node ${DRAM_NODE_NUMBER}"
        exit 1
    fi
}

function check_cxl_nodes()
{
    # CXL NODE
    echo "[INFO] Validate CXL node ${CXL_NODE_NUMBER}"

    # Check if the node exists
    if ! numactl -H | grep -q "node ${CXL_NODE_NUMBER} "; then
        echo "[ERROR] Node ${CXL_NODE_NUMBER} does not exist."
        exit 1
    fi

    # Check if there are any CPUs associated with the CXL node
    cpu_list=$(numactl -H | grep "node ${CXL_NODE_NUMBER} cpus:" | awk '{print $4}')
    if [ -n "${cpu_list}" ]; then
        echo "[ERROR] Node ${CXL_NODE_NUMBER} has CPUs associated with it."
        exit 1
    fi
}

function validate_numa_nodes()
{
    # Check if both -r and -c options were provided
    if [ -z ${DRAM_NODE_NUMBER} ] ; then
        echo "-d (DRAM_NODE_NUMBER) option is required"
        print_usage
        exit 1
    else
        check_dram_nodes
    fi
    if [ ! -z ${USE_CXL} ];
    then
        if [ -z ${CXL_NODE_NUMBER} ] ;
        then
            echo "-c (CXL_NODE_NUMBER) option is required to test with cxl, tier, interleave or mm modes"
            print_usage
            exit 1
        else
            check_cxl_nodes
        fi
    fi
}

function clear_file_caches()
{
    echo "[INFO]: Clearing file caches"
    sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"
}

function run_benchmark()
{
    echo "[INFO]: Starting stream benchmark run"

    local output_dir=stream-${OUTPUT_PREFIX}

    mkdir -p ${output_dir}

    output_log=${output_dir}/log.log

    core_count=$(($(lscpu -p=SOCKET | grep -o '0' | wc -l) / $(lscpu | grep "Socket(s):" | awk '{print $2}')))

    threads=2
    while true ; do
        if [ ${threads} -gt ${core_count} ] ; then
            if [ ${thread_count} -eq ${core_count} ] ; then
                break
            else
                thread_count=${core_count}
            fi
        else
            thread_count=${threads}
        fi

        export OMP_NUM_THREADS=${thread_count}
        echo "[INFO]: Starting stream run of ${OMP_NUM_THREADS} threads"
        ${NUMACTL} ${SCRIPT_DIR_NAME}/stream_c.exe --ntimes ${NTIMES} --array-size ${ARRAY_SIZE} --malloc > ${output_dir}/stream_${thread_count}.log 
        echo "[INFO]: Completed stream run of ${thread_count} threads"
        threads=$(( threads * 2 ))
    done

    return 0
}

if [ "$#" -eq "0" ];
then
    print_usage
    exit 0
fi

NTIMES=100
ARRAY_SIZE=430080000

while getopts "t:c:d:n:a:m?h" opt; do
    case $opt in
    t)
        TEST_TYPES=${OPTARG}
        ;;
    c)
        CXL_NODE_NUMBER=${OPTARG}
        ;;
    d)
        DRAM_NODE_NUMBER=${OPTARG}
        ;;
    n)
        NTIMES=${OPTARG}
        ;;
    a)
        ARRAY_SIZE=${OPTARG}
        ;;
    ?|h)
        print_usage
        ;;
    esac
done

validate_test_type
validate_numa_nodes

if [ ! -z ${DRAM_TEST} ]; then
    NUMACTL="numactl --cpunodebind=${DRAM_NODE_NUMBER} --membind=${DRAM_NODE_NUMBER} "
    OUTPUT_PREFIX=dram
fi

if [ ! -z ${CXL_TEST} ]; then
    NUMACTL="numactl --cpunodebind=${DRAM_NODE_NUMBER} --membind=${CXL_NODE_NUMBER} "
    OUTPUT_PREFIX=cxl
fi

if [ ! -f "${SCRIPT_DIR_NAME}/stream_c.exe" ]; then
    pushd ${SCRIPT_DIR_NAME}
    make stream_c.exe
    popd
fi

check_dependencies
check_and_set_cpu_freq_scaling
clear_file_caches

PROFILE_PREFIX=stream_${OUTPUT_PREFIX}

if [ "$?" -eq "0" ]; then
    run_benchmark
    if [ "$?" -ne "0" ]; then
        invalid_run=1
    fi
else
    invalid_run=1
fi

reset_cpu_freq_scaling

exit ${invalid_run}
