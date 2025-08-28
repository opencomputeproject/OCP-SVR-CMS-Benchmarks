#!/usr/bin/env python3

import argparse
import subprocess
import time
import numpy as np
from qdrant_client import QdrantClient
from qdrant_client.http import models
import requests
import json
import os
import pprint
import shutil
import logging
from tqdm import tqdm
import signal
import sys
import io
from statistics import mean
import atexit

# Map the data type (--data-type) to Qdrant data type
DATA_TYPE_MAP = {
    'FP32': models.Datatype.FLOAT32,
    #'FP16': models.Datatype.FLOAT16,
    'UINT8': models.Datatype.UINT8,
}

# Define the mapping from (--data-type) to NumPy data types
NP_DATA_TYPE_MAP = {
    'FP32': np.float32,
    #'FP16': np.float16,
    'UINT8': np.uint8
}

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Suppress Qdrant client logs
logging.getLogger("qdrant_client").setLevel(logging.ERROR)
logging.getLogger("httpx").setLevel(logging.ERROR)
from urllib3.connectionpool import log as urlliblog
urlliblog.setLevel(logging.ERROR)

# Global flag to indicate if the script is being interrupted
interrupted = False

# Handle Signals (Ctrl-C)
def signal_handler(sig, frame):
    global qdrant_client
    qdrant_client.close()  # Ensure resources are freed
    global interrupted
    logger.info("Interrupt received, cleaning up...")
    interrupted = True
    sys.exit(0)

# Set up the interrupt handler
signal.signal(signal.SIGINT, signal_handler)

# Ensure resources cleanup
def cleanup():
    # Check if the container exists before attempting to remove it
    container_exists = subprocess.run(["docker", "ps", "-a", "-q", "-f", "name=qdrant"], stdout=subprocess.PIPE).stdout
    if container_exists:
        # Check if the container was killed due to an OOM error
        inspect_output = subprocess.run(["docker", "inspect", "qdrant"], stdout=subprocess.PIPE).stdout
        if b'"OOMKilled": true' in inspect_output:
            logger.error("Qdrant container was killed due to an Out of Memory (OOM) error.")
        else:
            logger.info("Qdrant container stopped successfully.")
            
        logger.info("Cleaning up Docker container...")
        subprocess.run(["docker", "rm", "-f", "qdrant"], check=True)

# Function to check if the script is run as root
def check_root():
    if os.geteuid() != 0:
        logger.error("This script must be run as root.")
        sys.exit(1)

# Start a Qdrant Docker Container using the latest image
def run_qdrant_container(cpus, memory, storage, port, numa_nodes=None, cpu_set=None):
    logger.info(f"Starting Qdrant container with {cpus} CPUs, {memory}GB memory, {storage}GB storage, and port {port}...")
    cmd = [
        'docker', 'run', '-d',
        '--cpus', str(cpus),
        '--memory', f'{memory}g',
        '--mount', f'type=tmpfs,destination=/qdrant/storage,tmpfs-size={storage}g',
        '-p', f'{port}:6333',
        '--name', 'qdrant_benchmark',
    ]

    if numa_nodes:
        cmd.extend(['--cpuset-mems', numa_nodes])
        logger.info(f"Using NUMA nodes: {numa_nodes}")

    if cpu_set:
        cmd.extend(['--cpuset-cpus', cpu_set])
        logger.info(f"Using CPU set: {cpu_set}")

    cmd.append('qdrant/qdrant')

    try:
        subprocess.run(cmd, check=True)
        logger.info("Qdrant container started successfully.")
    except subprocess.CalledProcessError as e:
        logger.error(f"Error starting Qdrant container: {e}")
        raise

# Stop a running QDrant container
def stop_qdrant_container():
    logger.info("Stopping Qdrant container...")
    try:
        subprocess.run(['docker', 'stop', 'qdrant_benchmark'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        logger.info("Qdrant container stopped successfully.")
    except subprocess.CalledProcessError:
        logger.warning("No container to stop.")
    try:
        subprocess.run(['docker', 'rm', 'qdrant_benchmark'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        logger.info("Qdrant container removed successfully.")
    except subprocess.CalledProcessError:
        logger.warning("No container to remove.")

# Wait for the Docker container to start before attempting to access the database
def wait_for_qdrant_service(host='localhost', port=6333, timeout=60):
    logger.info(f"Waiting for Qdrant service to become ready on port {port}...")
    url = f"http://{host}:{port}/collections"
    start_time = time.time()
    while time.time() - start_time < timeout and not interrupted:
        try:
            response = requests.get(url)
            if response.status_code == 200:  # Removed extra parenthesis
                logger.info("Qdrant service is ready.")
                return True
        except requests.ConnectionError:
            pass
        time.sleep(1)
    if interrupted:
        logger.info("Waiting for Qdrant service was interrupted.")
        return False
    logger.error(f"Qdrant service did not become ready within {timeout} seconds.")
    return False

# Create a new QDrant Data Collection
def create_collection(client, collection_name, vector_size, qdrant_data_type, on_disk, hnsw_on_disk, on_disk_payload):
    logger.info(f"Creating collection '{collection_name}' with vector size {vector_size} using datatype {qdrant_data_type}...")
    
    # Check if the collection already exists
    try:
        response = client.get_collection(collection_name=collection_name)
        if response:
            logger.info(f"Collection '{collection_name}' already exists.")
            # Delete the collection if it already exists in the database
            client.delete_collection(collection_name)
            logger.info(f"Existing collection '{collection_name}' deleted.")
    except Exception as e:
        if "Not found" in str(e):
            logger.info(f"Collection '{collection_name}' does not exist.")
        else:
            logger.error(f"Error checking collection: {e}")
            sys.exit(1)

    client.create_collection(
        collection_name=collection_name,
        vectors_config=models.VectorParams(
            size=vector_size, 
            distance=models.Distance.COSINE, 
            on_disk=on_disk,
            datatype=qdrant_data_type
        ),
        hnsw_config=models.HnswConfigDiff(on_disk=hnsw_on_disk),
        on_disk_payload=on_disk_payload,
    )
    logger.info(f"Collection '{collection_name}' created successfully.")

# Disable Qdrant Indexing. This may reduce the time to load all the vectors.
def disable_indexing(client, collection_name):
    """Disable indexing for faster bulk insertion."""
    logger.info(f"Disabling HNSW indexing for collection '{collection_name}'...")
    client.update_collection(
        collection_name=collection_name,
        optimizers_config=models.OptimizersConfigDiff(
            max_segment_size=100000000  # Adjust the segment size if needed to prevent re-indexing
        ),
        hnsw_config=models.HnswConfigDiff(
            m=0  # This disables HNSW indexing temporarily
        )
    )

# Enable Qdrant indexing. Enable once all the vectors are loaded into the database.
def enable_indexing(client, collection_name):
    """Re-enable HNSW indexing after insertion."""
    logger.info(f"Re-enabling HNSW indexing for collection '{collection_name}'...")
    client.update_collection(
        collection_name=collection_name,
        hnsw_config=models.HnswConfigDiff(
            m=16,  # Restore HNSW parameters, adjust this based on your performance needs
            ef_construct=100  # Set appropriate values for your use case
        )
    )

# Insert/Load vectors into the database.
def insert_vectors(client, collection_name, num_vectors, vector_size, data_type, batch_size, disable_indexing_for_loading):
    if num_vectors == 0:
        logger.info(f"No vectors to insert into collection '{collection_name}'.")
        return 0, 0, 0

    # Disable HNSW indexing if the flag is set
    if disable_indexing_for_loading:
        logger.info(f"Disabling HNSW indexing for collection '{collection_name}' during vector insertion...")
        client.update_collection(
            collection_name=collection_name,
            hnsw_config=models.HnswConfigDiff(
                m=0  # Temporarily disable HNSW indexing
            )
        )

    # Generate vectors based on the specified data type
    if data_type == 'float32':
        vectors = np.random.rand(num_vectors, vector_size).astype(np.float32)
    elif data_type == 'uint8':
        vectors = np.random.randint(0, 256, size=(num_vectors, vector_size), dtype=np.uint8)
    else:
        raise ValueError(f"Unsupported data type: {data_type}")

    logger.info(f"Inserting {num_vectors} vectors into collection '{collection_name}' using {data_type} datatype...")
    inserted_count = 0
    insertion_rates = []
    start_time = time.time()

    with tqdm(total=num_vectors, desc="Inserting vectors", unit="vectors") as pbar:
        for i in range(0, num_vectors, batch_size):
            if interrupted:
                logger.info("Vector insertion interrupted.")
                break
            end_index = min(i + batch_size, num_vectors)
            batch_start_time = time.time()

            # Redirect stdout and stderr
            old_stdout, old_stderr = sys.stdout, sys.stderr
            sys.stdout, sys.stderr = io.StringIO(), io.StringIO()

            try:
                client.upload_collection(
                    collection_name=collection_name,
                    vectors=vectors[i:end_index],
                    ids=list(range(i, end_index)),
                    batch_size=batch_size
                )
            finally:
                # Restore stdout and stderr
                sys.stdout, sys.stderr = old_stdout, old_stderr

            batch_end_time = time.time()
            batch_duration = batch_end_time - batch_start_time
            current_batch_size = end_index - i
            insertion_rate = current_batch_size / batch_duration if batch_duration > 0 else 0
            insertion_rates.append(insertion_rate)

            inserted_count += current_batch_size
            pbar.update(current_batch_size)

    total_duration = time.time() - start_time
    average_rate = inserted_count / total_duration if total_duration > 0 else 0

    logger.info(f"Inserted {inserted_count} vectors into collection '{collection_name}'.")
    logger.info(f"Average insertion rate: {average_rate:.2f} vectors/second")
    logger.info(f"Minimum insertion rate: {min(insertion_rates):.2f} vectors/second")
    logger.info(f"Maximum insertion rate: {max(insertion_rates):.2f} vectors/second")

    # Re-enable HNSW indexing if it was disabled for loading
    if disable_indexing_for_loading:
        logger.info(f"Re-enabling HNSW indexing for collection '{collection_name}'...")
        client.update_collection(
            collection_name=collection_name,
            hnsw_config=models.HnswConfigDiff(
                m=16,  # Re-enable with the desired HNSW configuration
                ef_construct=100  # Customize this based on your use case
            )
        )

    return average_rate, min(insertion_rates), max(insertion_rates)


# Run a benchmark test and measure the performance
def measure_performance(client, collection_name, vector_size, data_type, num_queries=1000):
    logger.info(f"Measuring performance with {num_queries} queries...")

    # Check if the provided data type is supported
    if data_type not in NP_DATA_TYPE_MAP:
        raise ValueError(f"Unsupported data type: {data_type}")

    # Map the string data type to a NumPy data type
    np_data_type = NP_DATA_TYPE_MAP[data_type]

    # Generate the query vector using the correct data type
    query_vector = np.random.rand(vector_size).astype(np_data_type)

    start_time = time.time()
    for i in range(num_queries):
        if interrupted:
            logger.info("Performance measurement interrupted.")
            break
        client.search(
            collection_name=collection_name,
            query_vector=query_vector,
            limit=10
        )
    end_time = time.time()
    actual_queries = i + 1
    avg_query_time = (end_time - start_time) / actual_queries
    logger.info(f"Average query time: {avg_query_time:.6f} seconds (over {actual_queries} queries)")
    return avg_query_time

# Get the `docker stats` output to show the memory utilization
def get_docker_stats():
    cmd = ['docker', 'stats', '--no-stream', '--format', '{{json .}}', 'qdrant_benchmark']
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        stats = json.loads(result.stdout)
        return {
            'CPU': stats['CPUPerc'],
            'Memory': stats['MemUsage'],
            'Disk': stats['BlockIO'],
            'Network': stats['NetIO']
        }
    else:
        logger.error("Error getting Docker stats")
        return None

# Obtain the NVidia GPU stats from `nvidia-smi`
def get_gpu_stats():
    if shutil.which('nvidia-smi'):
        cmd = ['nvidia-smi', '--query-gpu=utilization.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            gpu_util, mem_used, mem_total = result.stdout.strip().split(',')
            return f"GPU Utilization: {gpu_util}%, Memory: {mem_used}/{mem_total} MB"
    elif shutil.which('nvtop'):
        cmd = ['nvtop', '-o', 'gpu_util,mem_util', '-f', 'csv']
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    return "GPU stats not available"

# Obtain the true database size using Qdrant metrics
def get_database_size(client, collection_name):
    collection_info = client.get_collection(collection_name)
    if hasattr(collection_info, 'vectors_config'):
        # Old API
        vector_size = collection_info.vectors_config.size
    elif hasattr(collection_info, 'config'):
        # New API
        vector_size = collection_info.config.params.vectors.size
    else:
        logger.error("Unable to determine vector size from collection info")
        return 0
    
    return collection_info.points_count * vector_size * 4  # 4 bytes per float32

# Run `df -h` in the container to show how much data is written to the disk
def get_disk_usage(container_name):
    cmd = ['docker', 'exec', container_name, 'df', '-h']
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout
    else:
        logger.error("Error getting disk usage")
        return None

# Convert/Format a time (in seconds) to days, hours, minutes, seconds
def format_duration(seconds):
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, seconds = divmod(remainder, 60)

    formatted_time = []
    if days > 0:
        formatted_time.append(f"{int(days)} days")
    if hours > 0:
        formatted_time.append(f"{int(hours)} hours")
    if minutes > 0:
        formatted_time.append(f"{int(minutes)} minutes")
    if seconds > 0 or not formatted_time:  # Always show seconds if nothing else is shown
        formatted_time.append(f"{int(seconds)} seconds")
    
    return ", ".join(formatted_time)

# Convert/Format bytes into human readable results
def format_size(bytes_size):
    original_size = bytes_size  # Save the original size for later display
    # Define size units
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_size < 1024:
            return f"{bytes_size:.2f} {unit} ({int(original_size)} bytes)"
        bytes_size /= 1024

# The Main function
def main():
    # Argument Parsing
    parser = argparse.ArgumentParser(description="Benchmark Qdrant for performance testing by inserting a specified number of vectors. The tool helps measure Qdrant performance under different configurations, including CPU, memory, storage, and vector size.")
    parser.add_argument('--cpus', type=int, default=1, help='Number of CPUs')
    parser.add_argument('--memory', type=int, default=4, help='Memory in GB')
    parser.add_argument('--storage', type=int, default=10, help='Storage in GB')
    parser.add_argument('--port', type=int, default=6333, help='Host port for Qdrant')
    parser.add_argument('--numa-nodes', type=str, default=0, help='NUMA nodes to use (e.g., "0,1")')
    parser.add_argument('--cpu-set', type=str, help='Specific CPUs or CPU sockets to use (e.g., "0-3,4-7" or "0,1")')
    parser.add_argument('--vector-size', type=int, default=384, help='Vector size for the collection')
    parser.add_argument('--numvectors', type=int, default=1000000, help='Number of vectors to insert (must be a positive integer)')
    parser.add_argument('--data-type', type=str, default='FP32', choices=['FP32', 'UINT8'], help='Data type for vectors (FP32, UINT8)')
    parser.add_argument('--on-disk', action='store_true', help='Enable memory-mapped storage for vectors')
    parser.add_argument('--hnsw-on-disk', action='store_true', help='Enable on-disk storage for HNSW index')
    parser.add_argument('--on-disk-payload', action='store_true', help='Enable on-disk storage for payloads')
    parser.add_argument('--disable-hnsw-indexing-for-loading', action='store_true', help='Disable HNSW indexing during vector loading and re-enable it afterward')
    parser.add_argument('--batch-size', type=int, default=1000, help='Number of vectors per batch')
    parser.add_argument('--verbose', action='store_true', help='Increase output verbosity')

    args = parser.parse_args()

    # Validate the arguments
    if args.numvectors <= 0:
        logger.error("The number of vectors must be greater than 0.")
        sys.exit(1)

    if args.verbose:
        logger.setLevel(logging.DEBUG)
    else:
        logger.setLevel(logging.INFO)

    # If the user has not specified any of the help arguments, run the main benchmark suite.
    help_flags = ['--help', '-h', '-?']
    if not any(flag in sys.argv for flag in help_flags):
        # Check for root privileges
        check_root()

        # Register the cleanup function to be called at exit
        atexit.register(cleanup)

        # Log the configuration options
        logger.info("Configuration options for this run:")
        logger.info(pprint.pformat(vars(args)))  # Use pprint to nicely format the dictionary


        # Start benchmarking
        try:
            run_qdrant_container(args.cpus, args.memory, args.storage, args.port, args.numa_nodes, args.cpu_set)
            if not wait_for_qdrant_service(port=args.port):
                return

            logger.info("Connecting to Qdrant server...")
            client = QdrantClient("localhost", port=args.port)

            collection_name = "benchmark_collection"
            vector_size = args.vector_size
            qdrant_data_type = DATA_TYPE_MAP[args.data_type]

            create_collection(
                client, 
                collection_name, 
                vector_size, 
                qdrant_data_type,
                args.on_disk, 
                args.hnsw_on_disk, 
                args.on_disk_payload
            )

            logger.info("Initial database size: 0 bytes")
            logger.info("Docker stats before data insertion:")
            logger.info(json.dumps(get_docker_stats(), indent=2))
            logger.info("GPU stats before data insertion:")
            logger.info(get_gpu_stats())

            # Initial data ingestion
            logger.info(f"Inserting {args.numvectors} vectors...")
            insertion_start_time = time.time()
            insert_avg, insert_min, insert_max = insert_vectors(
                client,
                collection_name,
                args.numvectors,
                args.vector_size,
                qdrant_data_type,
                args.batch_size,
                args.disable_hnsw_indexing_for_loading
            )
            if interrupted:
                return
            
            # Calculate and print the total time taken to insert all the vectors
            insertion_end_time = time.time()
            insertion_duration = insertion_end_time - insertion_start_time
            formatted_duration = format_duration(insertion_duration)
            logger.info(f"Successfully inserted {args.numvectors} vectors in {formatted_duration} ({insertion_duration:.2f} seconds).")

            db_size_bytes = get_database_size(client, collection_name)
            logger.info(f"Database size after initial insertion: {format_size(db_size_bytes)}")

            logger.info("Docker stats after initial insertion:")
            logger.info(json.dumps(get_docker_stats(), indent=2))
            logger.info("GPU stats after initial insertion:")
            logger.info(get_gpu_stats())
            logger.info("Disk usage after initial insertion:")
            logger.info(get_disk_usage('qdrant_benchmark'))

            # Record the start time of the benchmark
            benchmark_start_time = time.time()

            # Call measure_performance with the correct data type from the arguments
            avg_query_time = measure_performance(client, collection_name, args.vector_size, args.data_type)

            if interrupted:
                return
            
            logger.info(f"Final average query time: {avg_query_time:.6f} seconds")

            # Calculate and print the total benchmark duration
            benchmark_end_time = time.time()
            benchmark_duration = benchmark_end_time - benchmark_start_time
            formatted_duration = format_duration(benchmark_duration)
            logger.info(f"Total benchmark completed in {formatted_duration} ({benchmark_duration:.2f} seconds).")

            # Report overall insertion rates
            logger.info("Overall Insertion Rate Summary:")
            logger.info(f"Initial insertion - Avg: {insert_avg:.2f}, Min: {insert_min:.2f}, Max: {insert_max:.2f} vectors/second")

        except requests.ConnectionError as e:
            logger.error(f"Failed to connect to Qdrant: {e}")
            sys.exit(1)
        except Exception as e:
            logger.error(f"An error occurred: {str(e)}")
        finally:
            stop_qdrant_container()

if __name__ == "__main__":
    main()
