#!/usr/bin/env bash

# Sets up routes on the host machine (macOS) to pod CIDRs handled by each
# Kubernetes node. This is only necessary if CNI is based on default plugins (i.e. Cilium is not used)
# This script must be run when at least one VM is running, so that the bridge interface exists.
# Routes will be removed by macOS when the bridge interface is deleted (i.e. when no VM is running).

set -xe

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

add_route() {
  net=$1
  via=$2
  case $(uname -s) in
    Darwin) route -n add -net "$net" "$via";;
    Linux) ip route add "$net" via "$via";;
  esac
}

for vmid in $(seq 1 6); do
  add_route 10.${vmid}.0.0/16 192.168.1.$((10 + $vmid))
done
