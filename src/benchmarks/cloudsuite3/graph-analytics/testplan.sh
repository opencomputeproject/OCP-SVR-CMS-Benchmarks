#!/bin/bash
#
./run.sh -n "Default Settings"
./run.sh -c 0 -m 0 -n "cpu=0 mem=0"
./run.sh -c 0 -m 0,2 -n "cpu=0 mem=0,2 --interleave=0,2" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -n "cpu=0 mem=0,2 --preferred=2" -p -w graph-prefer2
./run.sh -c 0 -m 0,2 -a 1 -z 0 -n "cpu=0 mem=0,2 autonuma=1 demote=0"
./run.sh -c 0 -m 0,2 -a 1 -z 1 -n "cpu=0 mem=0,2 autonuma=1 demote=1"
./run.sh -c 0 -m 0,2 -a 2 -z 0 -n "cpu=0 mem=0,2 autonuma=2 demote=0"
./run.sh -c 0 -m 0,2 -a 2 -z 1 -n "cpu=0 mem=0,2 autonuma=2 demote=1"
./run.sh -c 0 -m 0,2 -a 1 -z 0 -n "cpu=0 mem=0,2 --interleave=0,2 autonuma=1 demote=0" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 1 -z 1 -n "cpu=0 mem=0,2 --interleave=0,2 autonuma=1 demote=1" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 2 -z 0 -n "cpu=0 mem=0,2 --interleave=0,2 autonuma=2 demote=0" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 2 -z 1 -n "cpu=0 mem=0,2 --interleave=0,2 autonuma=2 demote=1" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 16384 -n "cpu=0 mem=0,2 tiering 16GB"
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 24576 -n "cpu=0 mem=0,2 tiering 24GB"
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 32768 -n "cpu=0 mem=0,2 tiering 32GB"
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 40960 -n "cpu=0 mem=0,2 tiering 40GB"
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 16384 -n "cpu=0 mem=0,2 --interleave=0,2 tiering 16GB" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 24576 -n "cpu=0 mem=0,2 --interleave=0,2 tiering 24GB" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 32768 -n "cpu=0 mem=0,2 --interleave=0,2 tiering 32GB" -p -w graph-interleave
./run.sh -c 0 -m 0,2 -a 0 -z 0 -t 40960 -n "cpu=0 mem=0,2 --interleave=0,2 tiering 40GB" -p -w graph-interleave
./run.sh -c 0 -m 0 -s 40g -x 27g -n "cpu=0 mem=0 maxmem=40g swap=0g"
./run.sh -c 0 -m 0 -s 40g -x 26g -n "cpu=0 mem=0 maxmem=38g swap=1g"
./run.sh -c 0 -m 0 -s 40g -x 24g -n "cpu=0 mem=0 maxmem=36g swap=3g"
./run.sh -c 0 -m 0 -s 40g -x 22g -n "cpu=0 mem=0 maxmem=34g swap=5g"
./run.sh -c 0 -m 0 -s 40g -x 20g -n "cpu=0 mem=0 maxmem=32g swap=7g"
./run.sh -c 0 -m 0 -s 40g -x 18g -n "cpu=0 mem=0 maxmem=30g swap=9g"
./run.sh -c 0 -m 0 -s 40g -x 16g -n "cpu=0 mem=0 maxmem=28g swap=11g"
./run.sh -c 0 -m 0 -s 40g -x 13g -n "cpu=0 mem=0 maxmem=26g swap=14g"
