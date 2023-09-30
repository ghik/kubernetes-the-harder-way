#!/usr/bin/env bash
set -xe
dir=$(dirname "$0")

for vmid in $(seq 0 6); do
  "$dir/vmsetup.sh" $vmid
done

