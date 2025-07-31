# How to
 
Ensure that you have the necessary prerequisites installed, see root of this directory for instructions. 

make a log directory for the benchmark

```bash
mkdir -p results
```
## ENV file

Copy EDITMEenv to your .env file for docker-compose. You must set 
 - HOST_RESULTS_DIR: where the output from the benchmark is stored
 - CXL_NUMA_NODE and/or DRAM_NUMA_NODE: to the device(s) you wish to test

Optional fields are
 - SOCKET:          Container defaults to numanode 0, set this variable to change the CPU socket/CPU NUMA
 - *_VERBOSITY:     Uncomment LOW/MID/HIGH to add more log data from the run
 - LOADED_LATENCY:  Passes loaded latency testing flag to MLC, disabled by default
 - SINGLE_THREADED: Default is to run on all cores, enable to run single threaded
 - ENABLE_512_AVX:  Default is to run with AVX_512, uncomment to disable

## Everything else (Dockerfile, docker-compose.yml, *.sh)

Look but don't `touch`, editing these files will invalidate the testing. We may eventually push the container to dockerhub or something similar but for now you're building it local. 

## Building and running 

When building you can either use the docker-compose command

```bash
docker-compose build
```
or just docker build

```bash
docker build -t OCP-CMS-intel-mlc-benchmark:latest .
```

Before running the benchmark, make sure the .env file exists and is configured for your testrun, then run with `sudo` docker-compose

```bash
cp EDITME.env .env
vim .env #And make your changes
sudo docker-compose up -d
```
or without docker-compose

```bash
sudo docker run -d --privileged --volume <path-to-your-host-result-dir>:/opt/mlc/results --env-file ./.env --name intel-mlc OCP-CMS-intel-mlc-benchmark
```
