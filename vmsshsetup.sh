#!/usr/bin/env bash

# This script ensures that we can connect to a VM (identified by ID) with SSH.
# This includes waiting for the VM to be ready, and ensuring that VM's keys are saved into known_hosts.

set -xe
dir=$(dirname "$0")

# Grab the helpers
source "$dir/helpers.sh"

# Parse the argument (VM ID)
vmid=$1
vmname=$(id_to_name "$vmid")

# Wait until the VM is ready to accept SSH connections
until nc -zw 10 "$vmname" 22; do sleep 1; done

# Remove any stale entries for this VM from known_hosts
if [[ -f ~/.ssh/known_hosts ]]; then
  sedi "/^$vmname/d" ~/.ssh/known_hosts
fi

# Add new entries for this VM to known_hosts
ssh-keyscan "$vmname" 2> /dev/null >> ~/.ssh/known_hosts

# Wait until the system boots up and starts accepting unprivileged SSH connections
until ssh "ubuntu@$vmname" exit; do sleep 1; done
