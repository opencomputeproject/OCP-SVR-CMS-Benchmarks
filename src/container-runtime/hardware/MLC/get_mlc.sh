#!/bin/bash

#TODO: figure out a better way to do this. Every time intel updates MLC this will break.
#      Need some sort of automation/email/something so that it can at least be updated,
#      but moving away from MLC to something else may be better long term.
#      ALSO, intel isn't checking their certs right now either so I've had to toss in
#      the no check flag, which also isn't my favorite.
#wget https://downloadmirror.intel.com/793041/mlc_v3.11.tgz
wget --no-check-certificate https://downloadmirror.intel.com/866182/mlc_v3.12.tgz
mkdir -p mlc_v3.12
tar xf mlc_v3.12.tgz -C mlc_v3.12
rm mlc_v3.12.tgz
