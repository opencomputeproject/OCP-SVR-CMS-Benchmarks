#!/bin/bash
if [[ -f ./setup_env.sh ]]; then
	source ./setup_env.sh
fi

CPUSETS_CPU_NODE=""
CPUSETS_CPU=""
CPUSETS_MEM=""
MEMPOLICY=""
CONTAINER="memcached-numa"
RESULTS="results.txt"
THREADS=""
NOTE="Default settings"
MEMMAX=""
MAXSWAP=""

function display_help {
	echo "Usage: $0 [options]"
	echo "Options:"
	echo "  -h             : Display this help message."
	echo "  -p             : Set in-container numactl mempolicy"
	echo "  -c  <integer>  : CPU NUMA node to bind to"
	echo "  -m  <int,...>  : Memory NUMA nodes to allow"
	echo "  -w  <string>   : Container name. Default: memcached-numa"
	echo "  -d  <integer>  : Set the data size"
	echo "  -q  <integer>  : Set the number of threads"
	echo "  -o  <string>   : Output file to concatenate results to"
	echo "  -n  <string>   : Optional note placed in second field of result"
	echo "  -a  <0,1,2>    : Enable autonuma mode <1,2>"
	echo "  -z  <0,1>      : Enable autonuma-demotion"
	echo "  -t  <integer>  : Tier up <int>MB of data into Node 0"
	echo "  -x  <int>g     : max memory usage"
	echo "  -s  <int>g     : max memory+swap usage"
	echo "  -r  <string>   : memcached args"
	exit 0
}

while getopts "hc:p:i:d:q:m:w:o:n:a:z:t:s:x:" opt; do
	case ${opt} in
		h)
			display_help
			;;
		p)
			MEMPOLICY="$OPTARG"
			;;
		q)
			THREADS="-P $OPTARG"
			;;
		c)
			if [[ $OPTARG =~ ^[0-9]+$ ]]; then
				CPUSETS_CPU_NODE=$OPTARG
				CPUSETS_CPU="--cpuset-cpus="$(lscpu -p=CPU,NODE | awk -F, '$2 == '$OPTARG' && $1 != "#" {print $1}' | paste -sd ",")
			else
				echo "Error: -c option requires an integer argument."
				exit 1
			fi
			;;
		m)
			if [[ $OPTARG =~ ^[0-9]+(,[0-9]+)*$ ]]; then
				CPUSETS_MEM="--cpuset-mems="$OPTARG
			else
				echo "Error: -m option requires integer arguments separated by commas."
				exit 1
			fi
			;;
		w)
			CONTAINER=$OPTARG
			;;
		o)
			RESULTS=$OPTARG
			;;
		n)
			NOTE=$OPTARG
			;;
		a)
			if [[ $OPTARG =~ ^[0-2]$ ]]; then
				AUTONUMA_RESTORE=`cat /proc/sys/kernel/numa_balancing`
				echo $OPTARG > /proc/sys/kernel/numa_balancing
			else
				echo "Error: -a requires a 0,1,or 2."
				exit 1
			fi
			;;
		z)
			if [[ $OPTARG =~ ^[0-1]$ ]]; then
				AUTONUMA_DEMOTE_RESTORE=`cat /sys/kernel/mm/numa/demotion_enabled`
				echo $OPTARG > /sys/kernel/mm/numa/demotion_enabled
			else
				echo "Error: -z requires a 0 or 1."
				exit 1
			fi
			;;
		t)
			if [[ $OPTARG =~ ^[0-9]+$ ]]; then
				start_tiering $OPTARG
				TIERING_ENABLED="true"
			else
				echo "Error: -c option requires an integer argument."
				exit 1
			fi
			;;
		s)
			MAXSWAP="--memory-swap=$OPTARG"
			;;
		x)
			MAXMEM="--memory=$OPTARG"
			;;
		z)
			SKIPLAUNCH=""
			;;
		\?)
			echo "Invalid Option: -$OPTARG"
			exit 1
			;;
		:)
			echo "Option -$OPTARG requires an argument."
			exit 1
			;;
	esac
done

rm -rf results
mkdir -p results

docker run --name memcached-docker -d --privileged $MAXMEM $MAXSWAP $CPUSETS_CPU $CPUSETS_MEM -p 11211:11211 -u 11211 -it $CONTAINER numactl $MEMPOLICY memcached -m 262144
sleep 1

start_time=$(date +%s%N)
numactl --cpunodebind 1 ./libmemcached-1.0.18/clients/memaslap -s 127.0.0.1:11211 -T 16 -c 256 -t 180s -X 131072 > results/raw_results.txt
end_time=$(date +%s%N)
time_taken=$(echo "scale=9; ($end_time - $start_time)/1000000000" | bc)

docker container stop memcached-docker
docker container rm memcached-docker

echo "memcached,\"$NOTE\",$time_taken" >> $RESULTS
cat results/raw_results.txt | grep "Run time" >> $RESULTS

if [[ -v TIERING_ENABLED ]]; then
	stop_tiering
fi

if [[ -v AUTONUMA_DEMOTE_RESTORE ]]; then
	echo $AUTONUMA_DEMOTE_RESTORE > /sys/kernel/mm/numa/demotion_enabled
fi

if [[ -v AUTONUMA_RESTORE ]]; then
	echo $AUTONUMA_RESTORE > /proc/sys/kernel/numa_balancing
fi

echo "completed test"
sleep 1
