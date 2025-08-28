# Intel Memory Latency Checker (MLC)

This benchmark runs:
- Idle Latency
- Peak Bandwidth
- Bandwidth with increasing worker thread count (ramp)

## Usage

```
# ./mlc.sh -?
 
Usage: ./mlc.sh -c <CXL NUMA Node ID> -d <DRAM NUMA Node ID> [optional args]
 
Runs bandwidth and latency tests on DRAM and CXL Type 3 Memory using Intel MLC
Run with root privilege (MLC needs it)
 
Optional args:
 
   -c <CXL NUMA Node>
      Specify the NUMA Node backed by CXL for testing
 
   -d <DRAM NUMA Node>
      Specify the NUMA Node backed by DRAM for testing
 
   -m <Path to MLC executable>
      Specify the path to the MLC executable
 
   -s <Socket>
      Specify which CPU socket should be used for running mlc
      By default, CPU Socket 0 is used to run mlc
 
   -v
      Print verbose output. Use -v, -vv, and -vvv to increase verbosity.
```

### Examples

**Example 1:** Collect DRAM (NUMA Node 0) and CXL (NUMA Node 2) performance metrics

```bash
$ sudo ./mlc.sh -d 0 -c 2 -m ./mlc
```

**Example 2:** Collect metrics for DRAM (NUMA Node 0) only 

```bash
$ sudo ./mlc.sh -d 0 -m ./mlc
```

**Example 3:** Collect metrics for CXL (NUMA Node 2) only 

```bash
$ sudo ./mlc.sh -c 2 -m ./mlc
```

## Processing the results

Each test run generates a new directory in the format of "<script name>.<hostname>.<date-time>". Inside this directory are individual result files.
The `mlc.sh.log` is a capture of STDOUT and STDERR.

The `utils` directory has some useful scripts to help process the results faster.

```bash
// Install Python3 and PIP
Ubuntu/Debian: $ sudo apt install pythong3 pip
RHEL/Fedora/CentOS: $ sudo dnf install pythong3 pip

// Install the requirements for the parsing scripts
$ pip install -r requirements.txt

// Change to a data directory
$ cd <data directory>

// Generate the Excel Document
// usage: gen_excel.py [-h] Directory ExcelFile
// Inside a data directory, run:
$ ../utils/gen_excel.py . mlc.results.xlsx

// Generate the bandwidth and latency charts
// usage: gen_plot.py [-h] -d DIRECTORY -r {w21,w23,w27} -t {seq,rand}
// Inside a results directory, run:
$ ../utils/gen_plot.py -d . -r w21 -t seq
$ ../utils/gen_plot.py -d . -r w21 -t rand

$ ../utils/gen_plot.py -d . -r w23 -t seq
$ ../utils/gen_plot.py -d . -r w21 -t rand

$ ../utils/gen_plot.py -d . -r w27 -t seq
$ ../utils/gen_plot.py -d . -r w27 -t seq
```

## Troubleshooting

If you encounter the following error:

```
alloc_mem_onnode(): unable to mbind: : Invalid argument
Buffer allocation failed!
```

Verify the DRAM and CXL memory NUMA node memory is ONLINE

```
# lsmem -o+ZONES,NODE
RANGE                                  SIZE   STATE REMOVABLE   BLOCK          ZONES NODE
0x0000000000000000-0x000000007fffffff    2G  online       yes       0           None    0
0x0000000100000000-0x000000107fffffff   62G  online       yes    2-32         Normal    0
0x0000001080000000-0x000000307fffffff  128G  online       yes   33-96         Normal    1
0x0000003080000000-0x000000407fffffff   64G  online       yes  97-128         Normal    3
0x0000004080000000-0x000000607fffffff  128G offline           129-192 Normal/Movable    2
0x0000006080000000-0x000000707fffffff   64G offline           193-224 Normal/Movable    4


Memory block size:         2G
Total online memory:     256G
Total offline memory:    192G
```

To resolve this, online the memory blocks

```
$ cd /sys/bus/node/devices/node2
$ for m in `find . -name "memory*[0-9]"`
do
  sudo echo online > $m/state
done

# lsmem
lsmem -o+ZONES,NODE
RANGE                                  SIZE   STATE REMOVABLE   BLOCK          ZONES NODE
0x0000000000000000-0x000000007fffffff    2G  online       yes       0           None    0
0x0000000100000000-0x000000107fffffff   62G  online       yes    2-32         Normal    0
0x0000001080000000-0x000000307fffffff  128G  online       yes   33-96         Normal    1
0x0000003080000000-0x000000407fffffff   64G  online       yes  97-128         Normal    3
0x0000004080000000-0x000000607fffffff  128G  online       yes 129-192         Normal    2
0x0000006080000000-0x000000707fffffff   64G offline           193-224 Normal/Movable    4

Memory block size:         2G
Total online memory:     384G
Total offline memory:     64G
```
