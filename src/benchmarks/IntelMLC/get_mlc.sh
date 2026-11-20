#!/bin/bash

wget --no-check-certificate https://downloadmirror.intel.com/866182/mlc_v3.12.tgz
mkdir -p mlc_v3.12
tar xf mlc_v3.12.tgz -C mlc_v3.12
rm mlc_v3.12.tgz
