#!/bin/bash

cd results

if [ $BENCHMARK = 'stream' ]; then 
	numactl $STREAM_CPU_NODE_BIND .././stream_c.exe $STREAM_NUMA_NODES $STREAM_NUM_LOOPS $STREAM_ARRAY_SIZE $STREAM_OFFSET $STREAM_MALLOC $STREAM_AUTO_ARRAY_SIZE 

elif [$BENCHMARK = 'scaling' ]; then
	.././run-stream-scaling.sh $SCALING_TEST $SCALING_CXL_NODE $SCALING_DRAM_NODE $SCALING_NUM_TIMES $SCALING_ARRAY_SIZE

else
	echo "Need to set BENCHMARK to stream or scaling"
fi

