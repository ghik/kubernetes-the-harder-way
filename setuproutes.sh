#!/usr/bin/env bash

set -xe

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

for vmid in $(seq 1 6); do
  route -n add -net 10.${vmid}.0.0/16 192.168.1.$((10 + $vmid))
done
