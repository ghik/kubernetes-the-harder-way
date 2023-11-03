#!/usr/bin/env bash
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
  vmid=$1
  vmname=$(id_to_name "$vmid")
  tmux send-keys -t "$sname" "ssh ubuntu@$vmname" C-m
}

# Launch a new session with initial window named "ssh-gateway"
tmux new-session -s "$sname" -n ssh-gateway -d
# Connect to `gateway` VM
vm_ssh 0

# Create a window for SSH connections to `control` VMs and connects to them
tmux new-window -t "$sname" -n ssh-controls
for vmid in $(seq 1 3); do
  vm_ssh "$vmid"
  if [[ $vmid != 3 ]]; then
    tmux split-window -t "$sname" -v
  fi
  tmux select-layout -t "$sname" even-vertical
done

# Create a window for SSH connections to `worker` VMs and connects to them
tmux new-window -t "$sname" -n ssh-workers
for vmid in $(seq 4 6); do
  vm_ssh "$vmid"
  if [[ $vmid != 6 ]]; then
    tmux split-window -t "$sname" -v
  fi
  tmux select-layout -t "$sname" even-vertical
done

tmux new-window -t "$sname" -n ssh-nodes
for vmid in $(seq 1 6); do
  vm_ssh "$vmid"
  if [[ $vmid != 6 ]]; then
    tmux split-window -t "$sname" -v
  fi
  tmux select-layout -t "$sname" tiled
done

# Finally, attach the session back to the current terminal and activate the second window
tmux attach -t "$sname:ssh-controls"
