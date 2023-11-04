#!/usr/bin/env bash

# This script calls `vmsetup.sh` for all VMs

set -xe
dir=$(dirname "$0")

for vmid in $(seq 0 6); do
  "$dir/vmsetup.sh" $vmid
done

