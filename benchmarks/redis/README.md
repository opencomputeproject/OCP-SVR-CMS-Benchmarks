# Container setup

pull down and run the latest container
```
docker pull redis/redis:latest
docker run -it --entrypoint="/bin/bash" redis
```

in the container
```
apt update
apt install vim numactl redis-server
cd /root/
```

in the root directory add the following files:

entrypoint.sh
```
numactl $1 redis-server /root/redis.conf --port 7551
```

redis.conf
(included in this directory)
this config does three things
- Binds to port 7551
- Sets IP binding to 0.0.0.0 (accepts from anywhere)
- turns protected mode off (otherwise connections will fail)
- turns snapshotting off (for consistency of performance)



In a separate console, commit the container

```
docker container ps
docker conatiner commit [container-id] redis-numa
```

# Running the benchmark

After setting up the docker conatiner, use `./run.sh` to simply run the benchmark and the results will be placed in results.txt (or requested file).

A sample test plan is located in testplan.sh

a parse\_results.py script has been added to clean up the results into an easy to chart csv.

```
Usage: ./run.sh [options]
Options:
  -h             : Display this help message.
  -p             : Set in-container numactl mempolicy
  -c  <integer>  : CPU NUMA node to bind to
  -m  <int,...>  : Memory NUMA nodes to allow
  -w  <string>   : Container name. Default: redis-numa
  -d  <integer>  : Set the data size
  -q  <integer>  : Set the number of threads
  -o  <string>   : Output file to concatenate results to
  -n  <string>   : Optional note placed in second field of result
  -a  <0,1,2>    : Enable autonuma mode <1,2>
  -z  <0,1>      : Enable autonuma-demotion
  -t  <integer>  : Tier up <int>MB of data into Node 0
  -x  <int>g     : max memory usage
  -s  <int>g     : max memory+swap usage
```

# Memory Use

The redis benchmark uses relatively little memory with the default settings.

For 10k payloads, it will use about 1-2gb of data

For 64k payloads, it will use around 14-gb of data

It appears that each additional thread adds some working memory in the 50-300mb range per thread, depending on payload size.


-d 10000 -q 8 --- uses ~2gb
-d 65535 -q 8 --- uses 16-17gb
-d 65535 -q 1 --- uses 14gb
