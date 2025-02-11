#!/bin/bash

# Define parameters for the benchmark runs
VECTOR_SIZES=(384 768 1024 2048 3072 4096)
NUM_VECTORS=(1000000 5000000 10000000 25000000 50000000 100000000)

# Define output directories
LOG_DIR="/var/tmp/qdrant_benchmark/logs"
CSV_DIR="/var/tmp/qdrant_benchmark/results"
mkdir -p $LOG_DIR $CSV_DIR

# CSV output files
QPS_CSV="${CSV_DIR}/qps_results.csv"
LATENCY_CSV="${CSV_DIR}/latency_results.csv"
MEMORY_CSV="${CSV_DIR}/memory_results.csv"

# Initialize CSV headers
echo "Vector Size,1M,5M,10M,25M,50M,100M" > $QPS_CSV
echo "Vector Size,1M,5M,10M,25M,50M,100M" > $LATENCY_CSV
echo "Vector Size,1M,5M,10M,25M,50M,100M" > $MEMORY_CSV

# Loop through each vector size and number of vectors
for vector_size in "${VECTOR_SIZES[@]}"; do
    QPS_ROW="$vector_size"
    LATENCY_ROW="$vector_size"
    MEMORY_ROW="$vector_size"
    
    for num_vectors in "${NUM_VECTORS[@]}"; do
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        LOG_FILE="${LOG_DIR}/benchmark_${vector_size}_${num_vectors}_${TIMESTAMP}.log"

	# Display the start time of the test in the desired format
        START_TIME=$(date +"%Y-%m-%d %H:%M:%S")
	echo "[START_TIME] Starting benchmark for vector size: $vector_size and vectors: $num_vectors"

        # Run the benchmark and save output to the log file
        python3 ./qdrant_benchmark.py --vector-size $vector_size --initial-vectors $num_vectors > $LOG_FILE 2>&1
        
        # Extract the relevant information from the log file
        QPS=$(grep -oP 'Average query time: \K[\d\.]+' $LOG_FILE)
        LATENCY=$(grep -oP 'Final average query time: \K[\d\.]+' $LOG_FILE)
        MEMORY_USAGE=$(grep -oP '"Memory": "\K[\d\.]+GiB' $LOG_FILE | tail -1)
        
        # Add extracted data to the corresponding rows
        QPS_ROW="$QPS_ROW,$QPS"
        LATENCY_ROW="$LATENCY_ROW,$LATENCY"
        MEMORY_ROW="$MEMORY_ROW,$MEMORY_USAGE"
        
        # Display the end time of the test in the desired format
        END_TIME=$(date +"%Y-%m-%d %H:%M:%S")
	echo "[END_TIME] Completed benchmark for vector size: $vector_size and vectors: $num_vectors"
    done
    
    # Append rows to the CSV files
    echo "$QPS_ROW" >> $QPS_CSV
    echo "$LATENCY_ROW" >> $LATENCY_CSV
    echo "$MEMORY_ROW" >> $MEMORY_CSV
done

echo "All benchmarks completed. Results saved to $CSV_DIR."

