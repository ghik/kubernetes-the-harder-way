#!/usr/bin/env zsh

set -xe
dir="$(dirname $0)"

for i in $(seq 0 2); do
  scp "$dir/setupnode.sh" "$dir/setupcontrol.sh" ubuntu@control$i:~
done

for i in $(seq 0 2); do
  scp "$dir/setupnode.sh" ubuntu@worker$i:~
done

scp "$dir/setupgateway.sh" ubuntu@gateway:~
