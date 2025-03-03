#!/bin/bash
# set -x
#
# This script uses docker to start 1 redis end 1 memtier container instances in a 1:1 relationship
# The containers run on a dedicated virtual network to simplify hostname referencing
# Each redis-server container will run on a dedicated host port, starting at 6279 and increasing
# by one for each new instance.
# Each memtier container will run redis-memtier benchmarks against a single redis
# database instance.
# The goal of this script is to show multi-instance performance as we start
# more DB instances.

SCRIPTDIR=$( dirname $( readlink -f $0 ))
source ${SCRIPTDIR}/../../lib/common     # Provides common functions
source ${SCRIPTDIR}/../../lib/msgfmt     # Provides pretty print messages to STDOUT

#################################################################################################
# Variables
#################################################################################################

# ==== Docker Variables ====

# Docker network name
DOCKER_NETWORK_NAME=myredis-network
DOCKER_INSTANCES=1                  # Number of docker instances to start: Override by -i

# === Redis Server Variables ===
REDIS_START_PORT=6379
REDIS_MAX_MEMORY=128
REDIS_REPLACEMENT_POLICY="volatile-lru"
REDIS_SERVER_NAME=redis_docker
#REDIS_DOCKER_IMAGE=docker.io/library/redis:latest
REDIS_DOCKER_IMAGE=redis


# === Redis-Memtier Variables ===
REDIS_MEMTIER_DOCKER_IMAGE=
MEMTIER_CLIENT_NAME=redis_memtier_docker
MEMTIER_DOCKER_IMAGE=redislabs/memtier_benchmark

# === Run options ===
WARM_DB_RUN_TIME=300
TEST_RUN_TIME=300

#SIZE_ARRAY=(1024 4096 8192 16384 32769 65536  131072 262144 524288 1048676 2097152 4194304 )
NAME_ARRAY=("1k" "4k" "8k" "16k" "32k" "64k" "128k" "256k" "512k" "1M" "2M" "4M")
# NAME_ARRAY=("1k" )

#################################################################################################
# Functions
#################################################################################################

# THis function will be called if a user sends a SIGINT (Ctrl-C)
function ctrl_c()
{
  info_msg "Received CTRL+C - aborting"
  stop_containers
  remove_containers
  delete_network
  display_end_info
  exit 1
}

# Handle Ctrl-C User Input
trap ctrl_c SIGINT

function init()
{
    # Create the output directory
    init_outputs
}

# Verify the required commands and utilities exist on the system
# We use either the defaults or user specified paths
# args: none
# return: 0=success, 1=error
function verify_cmds()
{
    local err_state=false

    # for CMD in numactl lscpu lspci grep cut sed awk docker dstat; do
    for CMD in numactl lscpu lspci grep cut sed awk docker; do
        CMD_PATH=($(command -v ${CMD}))
        if [ ! -x "${CMD_PATH}" ]; then
            error_msg "${CMD} command not found! Please install the ${CMD} package."
            err_state=true
        fi
    done

    if ${err_state}; then
        return 1
    else
        return 0
    fi
}

# Displays the script help information
function print_usage()
{
    echo -e "${SCRIPT_NAME}: Usage"
    echo "    ${SCRIPT_NAME} OPTIONS"
    echo " [Experiment options]"
    echo "      -e dram|cxl|numainterleave|numapreferred|   : [Required] Memory environment"
    echo "         kerneltpp"
    echo "      -o <prefix>                                 : Prefix of the output directory: Default 'test'"

    echo " [Run options]"
    echo "      -w <warm up time>                           : Number of seconds to warm the database: Default ${WARM_DB_RUN_TIME}."
    echo "      -r <run time>                               : Number of seconds to 'run' the benchmark: Default ${TEST_RUN_TIME}"
    echo "      -s <max_memory>                             : MaxMemory in GB for each Redis Server: Default ${REDIS_MAX_MEMORY}gb"
    echo "      -p allkeys-lru|allkeys-lru|allkeys-random|  : Redis MaxMemory Replacement Policy: Default ${REDIS_REPLACEMENT_POLICY}"
    echo "         volatile-lru|volatile-lfu|volatile-random"

    echo " [Machine confiuration options]"
    echo "      -C <numa_node>                              : [Required] CPU NUMA Node to run the Redis Server"
    echo "      -M <numa_node,..>                           : [Required] Memory NUMA Node(s) to run the Redis Server"
    echo "      -S <numa_node>                              : [Required] CPU NUMA Node to run the Memtier workers"

    echo "      -h                                          : Print this message"
    echo " "
    echo "Example 1: Runs a single Redis container on NUMA 0 and a single Memtier container on NUMA Node1, "
    echo "  warms the database, runs the benchmark with default ${REDIS_MAX_MEMORY}gb and ${REDIS_REPLACEMENT_POLICY}"
    echo "  and the defaule warmup time ${WARM_DB_RUN_TIME}s, and default run time ${TEST_RUN_TIME}s."
    echo " "
    echo "    $ ./${SCRIPT_NAME} -e dram -o test -i 1 -C 0 -M 0 -S 1"
    echo " "
    echo "Example 2: Created the Redis and Memtier containers, runs the Redis container on NUMA Node 0, using"
    echo "  CXL memory on NUMA Node 2, the Memtier container on NUMA Node 1, with replacement "
    echo "  policy allkeys-lru and maxmemory of 256gb, warm up time opf 600s and run time of 300s"
    echo " "
    echo "    $ ./${SCRIPT_NAME} -e cxl -o cxl -C 0 -M 2 -S 1 -p allkeys-lfu -s 256 -w 600 -r 300"
    echo " "
}


# From the MEM_ENVIRONMENT (-M) argument, determine what numactl options to use
# args: none
# return: none
function set_numactl_options()
{
    case "$MEM_ENVIRONMENT" in
        dram|cxl|mm|kerneltpp)
            NUMACTL_OPTION="--cpunodebind ${REDIS_CPU_NUMA_NODE} --membind ${REDIS_MEM_NUMA_NODE}"
            ;;
        numapreferred)
            NUMACTL_OPTION="--cpunodebind ${REDIS_CPU_NUMA_NODE} --preferred ${REDIS_MEM_NUMA_NODE}"
            ;;
        numainterleave)
            NUMACTL_OPTION="--cpunodebind ${REDIS_CPU_NUMA_NODE} --interleave ${REDIS_MEM_NUMA_NODE}"
            ;;
    esac
}

# Create the docker network
# args: none
# return: 0=success, 1=error
# extract and set the value of DOCKER_NETWORK_NAME
function create_network()
{
    if ! docker network ls | grep ${DOCKER_NETWORK_NAME} &> /dev/null; then
        info_msg "Creating a new Docker network called '${DOCKER_NETWORK_NAME}'."
        if docker network create ${DOCKER_NETWORK_NAME} > /dev/null 2>&1; then
            info_msg "Network '${DOCKER_NETWORK_NAME}' created successfully"
        else
            error_msg "Error creating network '${DOCKER_NETWORK_NAME}'"
            return 1
        fi
    else
        info_msg "Network '${DOCKER_NETWORK_NAME}' already exists"
    fi
    return 0
}

# Delete the docker network
function delete_network()
{
    info_msg "Remove Network '${DOCKER_NETWORK_NAME}'"
    if docker network rm ${DOCKER_NETWORK_NAME} > /dev/null 2>&1; then
        info_msg "Removed Network '${DOCKER_NETWORK_NAME}'"
    else
        error_msg "Failed to removed Network '${DOCKER_NETWORK_NAME}'"
    fi
}

function start_servers()
{
    info_msg "Start redis server instance"

    numactl ${NUMACTL_OPTION}                                       \
      docker run -d --rm --network ${DOCKER_NETWORK_NAME}           \
                 -p 6379:${REDIS_START_PORT}                        \
                 --name  ${REDIS_SERVER_NAME}                       \
                 ${REDIS_DOCKER_IMAGE}                              \
                   redis-server                                     \
                     --maxmemory ${REDIS_MAX_MEMORY}gb              \
                     --maxmemory-policy ${REDIS_REPLACEMENT_POLICY} \
                     --save ""

    local retcode=$?
    info_msg "Wait 5 seconds for all the instances to spin up"
    sleep 5

    if [ ${retcode} -ne 0 ]; then
        error_msg "Failed to start redis-server"
    else
        info_msg "Done starting server instance"
    fi
    return ${retcode}
}

function stop_servers()
{
    info_msg "Stopping server instance"

    docker stop ${REDIS_SERVER_NAME} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        error_msg "Failed to stop the redis-server"
        return 1
    else
        sleep 5
        info_msg "Done stopping server instance"
    fi
    # The memtier container is set up to exit on completion,
    # Leaving the stop code here in case we decide to use a
    # async exit model.
    # docker stop ${MEMTIER_CLIENT_NAME} > /dev/null 2>&1

    return 0
}

function set_output_path()
{
    info_msg "Set the output path"
    if [ -z ${OUTPUT_PREFIX} ];
    then
        OUTPUT_PREFIX="test_"
    else
        # Set the OUTPUT_PREFIX for files
        OUTPUT_PREFIX+="_"
    fi
    # Set the OUTPUT_PATH
    OUTPUT_PATH="./${OUTPUT_PREFIX}${SCRIPT_NAME}.`hostname`.`date +"%m%d-%H%M"`"
    #mkdir -p ${OUTPUT_PATH}
    info_msg "Done: Set the output path"
}

function warmup_database()
{
    if [ ${WARM_DB_RUN_TIME} -eq 0 ]; then
        warn_msg "Warmup tine (-w) was not specified for this run. Results may not be reproducible if the database was not warmed up before this run"
        return 0
    fi

    local data_size=${1}
    local data_size_in_digits=$( convert_to_number ${data_size} )
    info_msg "Start database warmup for data size '${data_size}"
    REDIS_PORT=${REDIS_START_PORT}

    numactl --cpunodebind ${MEMTIER_NUMA_NODE}           \
      docker run --rm  --network ${DOCKER_NETWORK_NAME}  \
                 --name ${MEMTIER_CLIENT_NAME}           \
                 ${MEMTIER_DOCKER_IMAGE}                 \
        memtier_benchmark                                \
            --test-time=${WARM_DB_RUN_TIME}              \
            --select-db=0                                \
            -n allkeys                                   \
            --key-maximum=30000000                       \
            --data-size=${data_size_in_digits}           \
            --key-pattern=R:R                            \
            --ratio=1:0                                  \
            --pipeline=64                                \
            --random-data                                \
            --distinct-client-seed                       \
            --randomize                                  \
            --expiry-range=10-100                        \
            --print-percentiles "50,95,99,99.9"          \
            --port  ${REDIS_PORT}                        \
            --server ${REDIS_SERVER_NAME} > ${OUTPUT_PATH}/${data_size}_warmup.log

    local retcode=$?
    if [ ${retcode} -ne 0 ]; then
        error_msg "Failed database warmup for data size '${data_size}'"
    else
        info_msg "Done database warmup for data size '${data_size}'"
    fi
    return ${retcode}
}

function run_benchmark()
{
    local data_size=${1}
    local data_size_in_digits=$( convert_to_number ${data_size} )
    info_msg "Start benchmark run"
    REDIS_PORT=${REDIS_START_PORT}

    numactl --cpunodebind ${MEMTIER_NUMA_NODE}         \
      docker run --rm --network ${DOCKER_NETWORK_NAME} \
                 --name ${MEMTIER_CLIENT_NAME}         \
                 ${MEMTIER_DOCKER_IMAGE}               \
                  memtier_benchmark                    \
                   --test-time=${TEST_RUN_TIME}        \
                   --select-db=0                       \
                   -n allkeys                          \
                   --key-maximum=30000000              \
                   --data-size=${data_size_in_digits}  \
                   --key-pattern=R:R                   \
                   --ratio=1:10                        \
                   --wait-ratio=10:1                   \
                   --pipeline=64                       \
                   --random-data                       \
                   --distinct-client-seed              \
                   --randomize                         \
                   --expiry-range=10-100               \
                   --print-percentiles "50,95,99,99.9" \
                   --port  ${REDIS_PORT}               \
                   --server ${REDIS_SERVER_NAME} > ${OUTPUT_PATH}/${data_size}_bench.log


    local retcode=$?
    if [ ${retcode} -ne 0 ]; then
        error_msg "Failed benchmark run for data size '${data_size}'"
    else
        info_msg "Done benchmark run for data size '${data_size}'"
    fi
    return ${retcode}
}

#################################################################################################
# Main
#################################################################################################

# Display the help information if no arguments were provided
if [ "$#" -eq "0" ];
then
    print_usage
    exit 1
fi

# Detect Terminal Type and setup message formats
auto_detect_terminal_colors

# Process the command line arguments
while getopts 'C:e:?hi:M:o:p:r:s:S:w:' opt; do
    case "$opt" in
        ## Experiment Options
        e)
            MEM_ENVIRONMENT=${OPTARG}
            ;;
        i)
            DOCKER_INSTANCES=${OPTARG}
            ;;
        o)
            OUTPUT_PREFIX=${OPTARG}
            ;;
        ##  Run Options
        r)
            TEST_RUN_TIME=${OPTARG}
            ;;
        w)
            WARM_DB_RUN_TIME=${OPTARG}
            ;;
        s)
            REDIS_MAX_MEMORY=${OPTARG}
            ;;
        p)
            REDIS_REPLACEMENT_POLICY=${OPTARG}
            ;;
        ## Machine Configuration Options
        C)
            REDIS_CPU_NUMA_NODE=${OPTARG}
            ;;
        M)
            REDIS_MEM_NUMA_NODE=${OPTARG}
            ;;
        S)
            MEMTIER_NUMA_NODE=${OPTARG}
            ;;
        h|\?|*)
            print_usage
            exit
            ;;
    esac
done

if [[ ("$MEM_ENVIRONMENT" != "numapreferred" && "$MEM_ENVIRONMENT" != "numainterleave" && "$MEM_ENVIRONMENT" != "dram" && "$MEM_ENVIRONMENT" != "cxl" && "$MEM_ENVIRONMENT" != "kerneltpp") ]];
then
    error_msg "Unknown memory environment '${MEM_ENVIRONMENT}'"
    print_usage
    exit 1
else
    # Validate the user provided two or more NUMA nodes in the (-M) option for numactl options
    if [[ "$MEM_ENVIRONMENT" == "numainterleave" ]]
    then
        # Count the number of values separated by commas
        IFS=',' read -ra NUMA_NODES <<< "$REDIS_MEM_NUMA_NODE"
        NUM_NODE_COUNT=${#NUMA_NODES[@]}

        # Check if the variable has two or more values separated by commas
        if [[ $NUM_NODE_COUNT -lt 2 ]]; then
            error_msg "Two or more NUMA node must be specified with (-M) with the '${MEM_ENVIRONMENT}' (-e) option"
            print_usage
            exit 1
        fi
    elif [[ "$MEM_ENVIRONMENT" == "numapreferred" ]]
    then
        # Check if the value is a single integer
        if ! [[ "$REDIS_MEM_NUMA_NODE" =~ ^[0-9]+$ ]]; then
	    error_msg "A single NUMA node must be specified with (-M) when using the '${MEM_ENVIRONMENT}' (-e) option"
            print_usage
            exit 1
        fi
    fi
fi

if [[ ( -z ${REDIS_CPU_NUMA_NODE} || -z ${REDIS_MEM_NUMA_NODE}) ]];
then

    echo ${REDIS_CPU_NUMA_NODE},  ${REDIS_MEM_NUMA_NODE}
    error_msg "-C and -M must be specified"
    print_usage
    exit 1
fi

if [ -z ${MEMTIER_NUMA_NODE} ];
then
    error_msg "-S must be specified"
    print_usage
    exit 1
fi

if [[ ${TEST_RUN_TIME} -eq 0 &&  ${WARM_DB_RUN_TIME} -eq 0 ]];
then
    error_msg "-w and -r are set to 0; Benchmark will not be run"
    print_usage
    exit 1
fi

if [ ${TEST_RUN_TIME} -eq 0 ];
then
    warn_msg "Test time (-r) was not specified for this run. No benchmark results will be generated."
fi


# Check if the user provided a prefix/test name, and use it
set_output_path

# Verify the mandatory commands and utilities are installed. Exit on error.
if ! verify_cmds
then
    exit
fi

# Initialize the environment
init

# Save STDOUT and STDERR logs to the data collection directory
log_stdout_stderr "${OUTPUT_PATH}"

# Display the header information
display_start_info "$*"

length=${#NAME_ARRAY[@]}

create_network
if [ $? -ne 0 ]; then
    error_msg "An error occurred in function create_network.  Exiting"
    exit 1
fi

set_numactl_options

for i in $(seq 0 $((length - 1))); do
    info_msg "Start run for Data Size ${NAME_ARRAY[${i}]}"

    start_servers
    warmup_database ${NAME_ARRAY[${i}]}
    run_benchmark ${NAME_ARRAY[${i}]}
    stop_servers

    info_msg "End run for ${NAME_ARRAY[${i}]}"
done
delete_network

display_end_info