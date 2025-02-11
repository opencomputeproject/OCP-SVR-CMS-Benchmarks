# Qdrant Benchmark Tool

This Qdrant Benchmark Tool is designed to test the performance of the [Qdrant vector search engine](https://qdrant.tech/) by inserting synthetically generated vectors into a collection and measuring search query performance. By using synthetically generated vectors, we test the database itself without needing to find different corpuses, preprocessing the data, and using an embedding model before the data can be inserted into the database. 

This benchmark allows users to configure various parameters such as the number of vectors, vector size, data type, CPU/memory allocation, and indexing options. By comparing different configurations, users can benchmark and analyze Qdrant's behavior under various workloads and hardware/software configurations.

## Features
- Insert large numbers of synthetically generated vectors into a Qdrant collection with configurable batch sizes.
- Measure insertion rates (vectors/second) and search query performance (queries/second).
- Support for different vector data types (`float32`, `uint8`).
- Flexible configuration of CPUs, memory, and storage for Qdrant containers.

## Installation

1. Ensure you have [Docker](https://www.docker.com/) installed on your machine.
2. Clone this repository:
   ```bash
   git clone https://github.com/your-username/qdrant-benchmark.git
   cd qdrant-benchmark
   ```
3. Run the benchmark using the provided script.

## Usage

The Qdrant Benchmark Tool allows you to configure various parameters. Below are the available options:

```bash
$ python3 qdrant_benchmark.py --help
usage: qdrant_benchmark.py [-h] [--cpus CPUS] [--memory MEMORY] [--storage STORAGE] [--port PORT]
                           [--numa-nodes NUMA_NODES] [--cpu-set CPU_SET] [--vector-size VECTOR_SIZE]
                           [--numvectors NUMVECTORS] [--on-disk] [--hnsw-on-disk] [--on-disk-payload]
                           [--batch-size BATCH_SIZE] [--disable-hnsw-indexing-for-loading]
                           [--data-type DATA_TYPE] [--verbose]

Benchmark Qdrant for performance testing by inserting a specified number of vectors.

options:
  -h, --help                            show this help message and exit
  --cpus CPUS                           Number of CPUs to allocate for Qdrant container
  --memory MEMORY                       Amount of memory (GB) for Qdrant container
  --storage STORAGE                     Storage space (GB) for Qdrant container
  --port PORT                           Port to expose for the Qdrant container (default: 6333)
  --numa-nodes NUMA_NODES               NUMA nodes to use (e.g., "0,1")
  --cpu-set CPU_SET                     Specific CPUs or CPU sockets to use (e.g., "0-3,4-7" or "0,1")
  --vector-size VECTOR_SIZE             The dimensionality of each vector (e.g., 384, 768)
  --numvectors NUMVECTORS               Number of vectors to insert (default: 1,000,000)
  --batch-size BATCH_SIZE               Batch size for vector insertion (default: 1000)
  --on-disk                             Enable memory-mapped storage for vectors (on-disk storage)
  --hnsw-on-disk                        Enable on-disk storage for HNSW index
  --on-disk-payload                     Enable on-disk storage for payloads
  --disable-hnsw-indexing-for-loading   Disable HNSW indexing during vector insertion and re-enable afterward
  --data-type DATA_TYPE                 Data type for vectors (choices: FP32, UINT8)
  --verbose                             Increase output verbosity
```

## Guidance

Here are some performance tuning tips for your **Qdrant Benchmark Tool**. These tips focus on optimizing the Qdrant configuration, hardware resources, and usage patterns to achieve better performance during vector insertion and search.

### **Batch Insertion**
   - **Use larger batch sizes**: Inserting vectors in batches reduces overhead and can significantly speed up the insertion process. By default, the tool uses a batch size of 1000, but for large datasets, consider increasing the batch size to something like 5,000 or 10,000.
   - **Experiment with batch sizes** to find the optimal trade-off between memory usage and performance.
   - Example: 
```bash
sudo python3 qdrant_benchmark.py --numvectors 1000000 --batch-size 10000
```

### **Disable HNSW Indexing During Insertion**
   - **Disable HNSW indexing** during large bulk insertions, then re-enable it afterward should improve performance on large datasets. This reduces the indexing overhead while vectors are being inserted.
   - You can use the `--disable-hnsw-indexing-for-loading` argument to automate this.
   - Example: 
```bash
sudo python3 qdrant_benchmark.py --numvectors 1000000 --disable-hnsw-indexing-for-loading
```

### **Use On-Disk Storage for Large Datasets**
   - **Enable on-disk storage** (`--on-disk`) when working with large datasets to avoid exhausting RAM. This prevents out-of-memory (OOM) errors during large insertions or when working with huge vector collections.
   - Use on-disk storage for the HNSW index as well (`--hnsw-on-disk`) for better memory efficiency during searches.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numvectors 50000000 --on-disk --hnsw-on-disk
```

### **Tune HNSW Parameters**
   - **Adjust HNSW parameters** to find a balance between index accuracy, search speed, and memory consumption. The two key parameters for HNSW indexing are:
     - `m`: This controls the number of bi-directional links created for each element in the HNSW graph. Higher values will increase memory usage but may improve accuracy.
     - `ef_construct`: This controls the number of neighbors evaluated during index construction. Higher values increase indexing time and memory usage but can improve search recall.
   - If the search performance is critical and memory usage is not a bottleneck, increase `m` and `ef_construct`.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numvectors 1000000 --vector-size 512 --on-disk --hnsw-on-disk --hnsw-params '{"m": 16, "ef_construct": 200}'
```

### **Increase CPU and Memory Allocation**
   - **Allocate more CPUs and memory** to the Qdrant container to improve insertion and query performance. More CPUs can handle parallel operations better, and more memory can handle larger datasets and higher query loads.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numvectors 1000000 --cpus 8 --memory 16 --storage 50
```

### **Use NUMA Nodes for Better Memory Locality**
   - If your system has multiple **NUMA (Non-Uniform Memory Access)** nodes, you can specify NUMA nodes for better memory locality. This can improve performance for large-scale vector searches and insertions by reducing memory latency.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numa-nodes "0,1" --numvectors 5000000
```

### **Experiment with Data Types**
   - **Optimize data types** for storage and performance. For example, using `uint8` instead of `float32` can reduce memory usage and improve performance if the precision loss is acceptable for your application.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numvectors 1000000 --vector-size 384 --data-type UINT8
```

### **Run Benchmark on a High-Performance SSD**
   - **Use fast SSDs** for storage if you enable on-disk storage (`--on-disk`). SSDs provide significantly faster random read/write performance compared to HDDs, improving both insertion and search performance.
   - Ensure that you allocate enough storage (`--storage`) to handle the dataset size and indexing overhead.

### **Monitor Resource Usage**
   - Use Docker stats or other monitoring tools to monitor **CPU, memory, and disk usage** during benchmark runs. This can help identify bottlenecks and fine-tune configurations.
   - Example using Docker stats:
```bash
docker stats
```

### **Avoid Overcommitting System Resources**
   - Ensure that the **Qdrant container is allocated enough resources** (CPU, memory, storage) to handle the load. Overcommitting resources can lead to system instability, OOM errors, or degraded performance.

### **Use Larger Vector Sizes for Better Benchmark Accuracy**
   - When benchmarking search performance, using larger vector sizes (e.g., 512, 768) better simulates real-world use cases in AI/ML applications. This can also help evaluate how well Qdrant handles complex, high-dimensional vector spaces.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numvectors 100000 --vector-size 768
```

### **Enable Verbose Logging for Debugging**
   - Use the `--verbose` flag to get more detailed logs, which can help you identify performance bottlenecks or issues with data insertion or queries.
   - Example:
```bash
sudo python3 qdrant_benchmark.py --numvectors 100000 --verbose
```

## Examples

### Basic Example

This command runs a benchmark with 20,000 vectors, a vector size of 384, and the default data type (`FP32`). The benchmark runs on a Qdrant container with 4 CPUs, 4GB of memory, and 10GB of storage:

```bash
sudo ./qdrant_benchmark.py --numvectors 20000 --vector-size 384 --cpus 4 --memory 4 --storage 10
```

### Inserting Vectors with a Different Data Type (`UINT8`)

This example inserts 10,000 vectors of type `UINT8` with a vector size of 1024. HNSW indexing is temporarily disabled for faster insertion:

```bash
sudo ./qdrant_benchmark.py --numvectors 10000 --vector-size 1024 --data-type UINT8 --batch-size 500 --disable-hnsw-indexing-for-loading
```

### Using On-Disk Storage for Vectors

This example enables on-disk storage for vectors and the HNSW index. It inserts 50,000 vectors of size 512:

```bash
sudo ./qdrant_benchmark.py --numvectors 50000 --vector-size 512 --on-disk --hnsw-on-disk --cpus 8 --memory 16 --storage 50
```

### Custom CPU and Memory Allocation

Run the benchmark using a Qdrant container with 2 CPUs, 2GB of memory, and 5GB of storage:

```bash
sudo ./qdrant_benchmark.py --numvectors 15000 --vector-size 256 --cpus 2 --memory 2 --storage 5
```

Run the benchmark allowing the Qdrant container to use memory from NUMA Nodes 0 and 2, which could be backed by DRAM or Compute Express Link (CXL) memory using 24 CPUs, 20GB of memory, and 10GB of storage. Insert 20 Million vectors of size 768.

```bash
sudo ./qdrant_benchmark.py --numvectors 20000000 --vector-size 768 --numa-nodes 0,2 --cpus 24 --memory 20 --storage 10
```

### Measure Performance with Custom Query Settings

After inserting vectors, you can measure the query performance with a specific number of queries. For example, to measure performance with 1,000 queries:

```bash
sudo python3 qdrant_benchmark.py --numvectors 20000 --vector-size 512 --data-type FP32 --numqueries 1000
```

## Logs and Output

The benchmark logs provide detailed information about the vector insertion rate, query performance, and memory/CPU usage. Here’s an example log:

```
2024-09-30 23:11:24,947 - INFO - Creating collection 'benchmark_collection' with vector size 384...
2024-09-30 23:11:24,951 - INFO - Collection 'benchmark_collection' created successfully.
2024-09-30 23:11:29,009 - INFO - Inserting 20000 vectors...
2024-09-30 23:11:29,500 - INFO - Average insertion rate: 1428.57 vectors/second
2024-09-30 23:12:00,500 - INFO - Measuring performance with 1000 queries...
2024-09-30 23:12:15,009 - INFO - Average query time: 0.045 seconds (over 1000 queries)
```

## Automation

This benchmark has a Bash shell script `run_benchmarks.sh` that allow you to automate running multiple tests serially. The STDOUT and STDERR are captured to a log file and the results processed to a CSV file for easy comparrison of the results in Excel.

Customize the script, or write your own, to perform the tests you require.

The primary variables for the script are:

1. Define the number of vectors and vector lengths/sizes to test. The script will test each combination.
```bash
# Define parameters for the benchmark runs
VECTOR_SIZES=(384 768 1024 2048 3072 4096)
NUM_VECTORS=(1000000 5000000 10000000 25000000 50000000 100000000)
```

2. Modify the arguments to the main `qdrant_benchmark.py` script as required:

```bash
# Run the benchmark and save output to the log file
python3 ./qdrant_benchmark.py --vector-size $vector_size --initial-vectors $num_vectors > $LOG_FILE 2>&1
```

## License

This benchmark is licensed under the GPL v3.0 of the main project.

## Contributing

Feel free to submit pull requests or open issues to improve the benchmark tool or add new features!