#!/usr/bin/env bash

# This script launches a multi-window, multi-pane tmux session and connects to all the VMs with SSH.

set -xe
dir=$(dirname "$0")

# Grab the helpers
source "$dir/helpers.sh"

# The script takes tmux session name as an argument
sname=$1
if [[ -z $sname ]]; then
  echo "usage: $(basename "$0") <tmux-session-name>"
  exit 1
fi

# Wait for VMs to start up and expose their SSH port. Scan their keys and add them to known_hosts.
for vmid in $(seq 0 6); do
  "$dir/vmsshsetup.sh" $vmid
done

# A function that prepares a pane for connecting to a VM with SSH, and connects to it.
# Takes VM ID as an argument.
vm_ssh() {
  local vmid=$1
  local vmname=$(id_to_name "$vmid")
  tmux send-keys -t "$sname" "ssh ubuntu@$vmname" C-m
}

# Launch a new session with initial window named "ssh-gateway"
tmux new-session -s "$sname" -n ssh-gateway -d
# Connect to `gateway` VM
vm_ssh 0

ssh_window() {
  local window_name=$1
  local first_vmid=$2
  local last_vmid=$3
  local layout=$4

  tmux new-window -t "$sname" -n "$window_name"
  for vmid in $(seq "$first_vmid" "$last_vmid"); do
    vm_ssh "$vmid"
    if [[ "$vmid" != "$last_vmid" ]]; then
      tmux split-window -t "$sname" -v
    fi
    tmux select-layout -t "$sname" "$layout"
  done
}

# Create a window with SSH connections to `control` VMs
ssh_window ssh-controls 1 3 even-vertical

# Create a window with SSH connections to `worker` VMs
ssh_window ssh-workers 4 6 even-vertical

# Create a window with SSH connections to both `control` and `worker` VMs
ssh_window ssh-nodes 1 6 tiled

# Finally, attach the session back to the current terminal and activate the second window
tmux attach -t "$sname:ssh-controls"
