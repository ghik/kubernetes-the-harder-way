#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

for i in $(seq 0 2); do
  scp "$dir/variables.sh" "$dir/setupnode.sh" "$dir/setupcontrol.sh" ubuntu@control$i:~
done

for i in $(seq 0 2); do
  scp "$dir/variables.sh" "$dir/setupnode.sh" ubuntu@worker$i:~
done

scp "$dir/variables.sh" "$dir/setupgateway.sh" ubuntu@gateway:~
