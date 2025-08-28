# STREAM

This modified version of the STREAM benchmarking tool measures the memory bandwidth of numa nodes. The original source code can be found [here](https://www.cs.virginia.edu/stream/FTP/Code/).

The original version of the benchmark has been modified to allow for dynamic allocation of memory using either malloc() or the numa_alloc_onnode() functions to direct the placement of the memory blob.

# Setup

The `numactl` command and `numa.h` header are required for this benchmark to run. The Debian verison of the package that provides both is [`libnuma-dev`](https://manpages.debian.org/buster/libnuma-dev/numa.3.en.html).

# Usage

## Compiling

- Debug, sanitizers, no optimization: `make debug_stream_c.exe`
- Optimization level 3: `make stream_c.exe`

## Running

### Command information

```bash
$ ./stream_c.exe --help
STREAM Benchmark
     --ntimes, -t <integer-value>                             : Number of times to run benchmark: Default 10
     --array-size, -a <integer-value>|<integer-value><K|M|G>  : Size of numa node arrays: Default 1000000
     --offset, -o <integer-value>                             : Change relative alignment of arrays: Default 0
     --numa-nodes, -n <integer>,<integer>|<integer>           : Numa node(s) to allocate memory
     --malloc, -m                                             : Use malloc rather than node alloc 
     --auto-array-size, -s                                    : Array will be socket's L3 cache divided by 2
     --help, -h                                               : Print this message
```

### Memory combinations

Get the indices of your numa nodes via the [`lscpu`](https://www.man7.org/linux/man-pages/man1/lscpu.1.html) command. An example being the following:

```
NUMA:
  NUMA node(s):          3
  NUMA node0 CPU(s):     0-31,64-95
  NUMA node1 CPU(s):     32-63,96-127
  NUMA node2 CPU(s):
```

The nodes with CPUs are DRAM (node0, node1), while the one without any CPUs (node2) is CXL.

#### DRAM Only
Example usage:
```bash
$ numactl --cpunodebind=0 --membind=0 ./stream_c.exe --malloc --auto-array-size
```
or
```bash
$ numactl --cpunodebind=0 --membind=0 ./stream_c.exe --malloc --array-size 400M --ntimes 100
``` 

#### CXL Only
Example usage:
```bash
$ numactl --cpunodebind=0 --membind=2 ./stream_c.exe --malloc --auto-array-size
```

#### DRAM + CXL

In this test, data is moved from DRAM to CXL vice versa.  It provides us with a clear idea of the both the read and write bandwidth that is sustainable to and from CXL.  Memory is allocated on the nodes using numa_alloc_onnode as opposed to malloc.

Example usage:
```
bash
$ numactl --cpunodebind=0 ./stream_c.exe --numa-nodes 0,2 --auto-array-size
```

## Running scaling tests
The convenience script run-stream-scaling.sh is used to generate the scaling performance of the memory subsystem.  The number of threads starts from 2 and increases in powers of 2 until all the cores on the CPU socket are exercised.

```
Usage:  ./run-stream-scaling.sh
run-stream-scaling.sh: Usage
    run-stream-scaling.sh
      -t dram|cxl      : test type
                       : dram:       Use only DRAM Memory
                       : cxl:        Use only CXL Memory
      -c <numa-node>   : CXL Node Number - REQUIRED
      -d <dram-node>   : DRAM Node Number - REQUIRED
      -n <ntimes>      : Amount of repetitions (default to 100)
      -a <size>        : Array size to allocate (default to 430_080_000)
```

The convenience script parse_results.py should be used to separate the results into the individual functions.

```
parse_results.py
STREAM benchmarking results parser

options:
  -h, --help            show this help message and exit
  -i INPUT, --input INPUT
                        The directory of where all the results are
  -o OUTPUT, --output OUTPUT
                        The prefix of the output files: The generated files will be
                        <prefix>_<function>.csv
```