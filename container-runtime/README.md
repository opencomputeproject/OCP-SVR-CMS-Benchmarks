# OCP SRV CMS Container Runtimes (CMS BENCH)

 These containers are a collection of device (hardware) and application level benchmarks designed to be repeatable, standardized, and mostly hands off from a user perspective. 

## Overview

 Benchmarking is hard, benchmarking memory devices and fabrics is new and hard. This effort aims to bound the complexity and variability of benchmarking local and fabric attached CXL devices as much as possible via container runtimes. CMS Bench aims to accomplish this by reducing as much software stack variability as possible by way of docker containers which have common stacks. We hope that by standardizing the runtime as much as possible, the other factors like container runtime engine, OS kernel, computer and device architectures, etc. will be easier to understand and tweak, that is, the primary goal of this effort is repeatability. 

## How-To

 This group recommends that users first run the hardware benchmarks to baseline system performance. These tests are straight forward latency and bandwidth benchmarks. Each directory has a docker-compose.yml file and a .env. The docker-compose.yml will _not_ be modified (nor shall the contents of the runtime container(s) please report bugs in issues). The only valid modifications are available in the .env file present in each benchmark directory. 

 Once the container launches it will collect basic system information, _e.g._ dmidecode, srv_info, proc, cache, meminfo, cxl device info, etc. then launch the benchmark with any overrides from the .env file. At the conclusion of the run it will generate output files in the form of a csv, .html, .pdf, as well as a tarball of the raw benchmark output. 

### Basic system dependencies

 docker compose and a container runtime engine, CXL driver support, active internet connection, 

## Benchmarks

 There are two main classes of benchmarks, hardware focused and software/application focused. The hardware benchmarks exists to ground truth system performance, while the software benchmarks aim to provide user insight on how their present CMS system behaves under test. Run instructions in each directory

### Hardware Benchmarks
1. Intel MLC: Basic memory latency checker
2. STREAM: The STREAM benchmark is a simple synthetic benchmark program that measures sustainable memory bandwidth (in MB/s) and the corresponding computation rate for simple vector kernels. 

### Application Benchmarks
 more to follow, but Redis/memcached/graphs/qdrant/etc.

## Recommended Test Flow
 As mentioned above, it is recommended that you run the hardware benchmarks first, then elect to run application benchmarks. 

## Interpreting the Output
 TBD

