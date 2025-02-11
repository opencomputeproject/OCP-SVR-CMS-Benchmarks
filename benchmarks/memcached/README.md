# Building the container

```
docker pull library/memcached:latest
docker run -u 0 -it memcached bash
apt update
apt install numactl
```

now in another termianl execute

```
docker container ps
docker container commit [container-id] memcached-numa
```

to run this container we'll need to do the following

```
docker run -d --privileged -u 11211 -it memcached-numa [ags]
```

our [args] in this case will be our entire numactl sequence plus the command to launch memcached

```
docker run -d --privileged -u 11211 -it memcached-numa numactl --interleave=0,2 memcached [memcached-args]
```

# Building the benchmark

We are going to use memaslap to test our memcached instance, but we'll need to build it since it's not part of the standard build.

```
wget https://launchpad.net/libmemcached/1.0/1.0.16/+download/libmemcached-1.0.16.tar.gz
tar -xvzf libmemcached-1.0.16.tar.gz
cd libmemcached-1.0.16
```

unfortunately on modern fedora, we need to make a few patches

In clients/memflush.cc, We need to change these NULL pointer checks not to check for a bool
```
(base) [root@sr1 libmemcached-1.0.18]# diff clients/memflushx.cc clients/memflush.cc
42c42
<   if (opt_servers == false)
---
>   if (!opt_servers)
51c51
<     if (opt_servers == false)
---
>     if (!opt_servers)
```

to clients/memaslap.c we need to add
```
/* global structure */
ms_global_t ms_global;

/* global stats information structure */
ms_stats_t ms_stats;

/* global statistic structure */
ms_statistic_t ms_statistic;
```

to clients/ms\_memslap.h we need to change the similar lines to add extern to them
```
/* global structure */
extern ms_global_t ms_global;

/* global stats information structure */
extern ms_stats_t ms_stats;

/* global statistic structure */
extern ms_statistic_t ms_statistic;
```

now you can build memaslap

```
./configure --enable-memaslap
make
```

# Running the Benchmark

```
Usage: ./run.sh [options]
Options:
  -h             : Display this help message.
  -p             : Set in-container numactl mempolicy
  -c  <integer>  : CPU NUMA node to bind to
  -m  <int,...>  : Memory NUMA nodes to allow
  -w  <string>   : Container name. Default: memcached-numa
  -d  <integer>  : Set the data size
  -q  <integer>  : Set the number of threads
  -o  <string>   : Output file to concatenate results to
  -n  <string>   : Optional note placed in second field of result
  -a  <0,1,2>    : Enable autonuma mode <1,2>
  -z  <0,1>      : Enable autonuma-demotion
  -t  <integer>  : Tier up <int>MB of data into Node 0
  -x  <int>g     : max memory usage
  -s  <int>g     : max memory+swap usage
  -r  <string>   : memcached args
```

example test plan:

```
#!/bin/bash

./run.sh -n "Default Settings"
./run.sh -c 0 -m 0 -n "Bind to Node 0"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -n "Interleave 0,2"
./run.sh -c 0 -m 0,2 -p "--preferred=2" -n "Preferred 2"
./run.sh -c 0 -m 0,2 -a 2 -z 1 -n "autonuma=2 demote=1"
./run.sh -c 0 -m 0,2 -p "--preferred=2" -a 2 -z 1 -n "prefer 2 autonuma=2 demote=1"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -a 2 -z 1 -n "interleave autonuma=2 demote=1"
./run.sh -c 0 -m 0,2 -t 87040 -n "tier 50:50"
./run.sh -c 0 -m 0,2 -t 104448 -n "tier 60:40"
./run.sh -c 0 -m 0,2 -t 121856 -n "tier 70:30"
./run.sh -c 0 -m 0,2 -t 139264 -n "tier 80:20"
./run.sh -c 0 -m 0,2 -t 156672 -n "tier 90:10"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -t 87040 -n "intleave tier 50:50"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -t 104448 -n "intleave tier 60:40"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -t 121856 -n "intleave tier 70:30"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -t 139264 -n "intleave tier 80:20"
./run.sh -c 0 -m 0,2 -p "--interleave=0,2" -t 156672 -n "intleave tier 90:10"
./run.sh -c 0 -m 0,2 -x 155G -s 256G -n "swap 15GB"
./run.sh -c 0 -m 0,2 -x 157G -s 256G -n "swap 13GB"
./run.sh -c 0 -m 0,2 -x 159G -s 256G -n "swap 11GB"
./run.sh -c 0 -m 0,2 -x 161G -s 256G -n "swap 9GB"
./run.sh -c 0 -m 0,2 -x 163G -s 256G -n "swap 7GB"
./run.sh -c 0 -m 0,2 -x 165G -s 256G -n "swap 5GB"
./run.sh -c 0 -m 0,2 -x 167G -s 256G -n "swap 3GB"
./run.sh -c 0 -m 0,2 -x 169G -s 256G -n "swap 1GB"
./run.sh -c 0 -m 0,2 -x 170G -s 256G -n "swap 0GB"
./run.sh -c 0 -m 0,2 -x 173G -s 256G -n "swap -3GB"
```
