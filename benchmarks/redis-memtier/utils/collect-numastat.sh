#!/bin/bash

trap ctrl_c INT

STOP_NUMASTAT=0
function ctrl_c()
{
    echo {INFO] Stopping numastat -m collection
    STOP_NUMASTAT=1
}

function start_numastat()
{
    echo [INFO] Start monitoring numastat -m
    local output_file=${1}
    # Get headers
    local num_nodes=$( lscpu | grep "NUMA node(s)" | cut -d':' -f 2 | tr -d ' ' )
    header="Time"
    for i in `seq 1 ${num_nodes}`;
    do
       local j=$(( i - 1 ))
       header+=",Node${j}"
    done
    echo $header > ${output_file}
    while  [ "${STOP_NUMASTAT}" -ne "1" ] ;
    do
        local line=$( numastat -m | grep ^MemUsed | tr -s ' ' )
        IFS=' ' read -a arr <<< "$line"
        local current_out=$( date +%s )
        for i in `seq 1 ${num_nodes}` ;
        do
            current_out+=","${arr[${i}]}
        done
        echo $current_out >> ${output_file}
        sleep 10
    done
    echo [INFO] Stopped monitoring numastat -m
}

start_numastat ${1}
