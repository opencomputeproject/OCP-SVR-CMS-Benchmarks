# Overview

## Setup

The run script will automatically pull down the default graph analytics image.

If you need an interleave-image, see "Creating interleave images".

## Running the test

To run a simple test, simply run ./run.sh

The default test does not do memory or cpu binding, and sets --driver-memory=64g and --executor-memory=64g (which is enough to prevent OOM issues).

Some options can be overidden

```
Usage: ./run.sh [options]
Options:
  -h             : Display this help message.
  -p             : Test requires privilege (interleave container)
  -c  <integer>  : CPU NUMA node to bind to
  -m  <int,...>  : Memory NUMA nodes to allow
  -w  <string>   : Container name. Default: cloudsuite3/graph-analytics
  -d  <integer>  : Set the driver memory. Default:64g
  -e  <integer>  : Set the executor memory. Default:64g
  -o  <string>   : Output file to concatenate results to
  -n  <string>   : Optional note placed in second field of result
  -a  <0,1,2>    : Set auto-numa balancing to 0, 1 or 2
  -z  <0,1>      : set auto-numa demotion to 0 or 1.
  -t  <integer>  : set the hot data tier to N MBs
```

## Sample Test plan

Included is a sample test plan for a CXL device on NUMA Node 2.
```
#!/bin/bash

# Run the workload with no special settings
./run.sh -n "Default Settings"

# Bind the workload to NUMA 0
./run.sh -c 0 -m 0 -n "cpu=0 mem=0"

# Interleave the workload between Node 0 and Node 2
./run.sh -c 0 -m 0,2 -n "cpu=0 mem=0,2 --interleave=0,2" -p -w graph-interleave

# Primarily use NODE 2, but allow non-movable allocations to NODE 0
./run.sh -c 0 -m 0,2 -n "cpu=0 mem=0,2 --preferred=2" -p -w graph-prefer2
```

# NUMACtl Images 

## Creating interleave images

Docker does not allow enabling interleave from outside the container, so software in the container must be changed to invoke numactl --interleave.  These are directions to modify the comatiner image and save a local copy of the modified container image.

Note that these directions assume your interleave settings will be "--interleave=0,2" (NUMA nodes 0 and 2).  You should change this to match your desired settings.

In one terminal:
1. docker run -it --entrypoint="/bin/bash" cloudsuite3/graph-analytics
2. you'll now be in a copy of the docker container at the bash prompt
3. apt update
4. apt install vim numactl
5. vim /benchmarks/run\_benchmark.sh
6. change "exec ${SPARK\_HOME}" to "exec numactl --interleave=0,2 ${SPARK\_HOME}"
7. save and close the document.  do not exit the container yet.

In another terminal:
1. docker container list
2. get the container ID for the in-memory-analytics container (e.g. c7b06ce106a0)
3. docker container commit c7b06ce106a0 graph-interleave

## Create Preferred Node images

Mode CXL memory is onlined as ZONE\_MOVABLE, as a result attempting to run this container 100% out of CXL will probably fail because the kernel will require some ZONE\_NORMAL memory.

To *prefer* node 2 for workload data, follow the interleave image direction, but use --preferred=2 instead of --interleave=0,2.  Then save this image as graph-prefer2.

## Running interleave image

Interleave containers require privilege to run.  To do this, use the -i command to mark the test an interleave test and use -w to replace the container name

Example:

./run -p -c 0 -m 0,2 -w graph-interleave

# Tiering

the -t option has been added so that tiering system commands can be tested
add a setup\_env.sh that exports TIER\_CMD1 and friends or modify the script to your needs
