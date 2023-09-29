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

# Launch a tmux session (with initial window named `qemu`) and immediately detach from it
tmux new-session -s "$sname" -n qemu -d

# Split the first window into 7 panes and launch a VM in each one
for vmid in $(seq 0 6); do
  tmux send-keys -t "$sname" "cd $dir" C-m
  tmux send-keys -t "$sname" "vmid=$vmid; vmname=$vmname" C-m
  tmux send-keys -t "$sname" './vmlaunch.sh $vmid' C-m
  if [[ $vmid != 6 ]]; then
    tmux split-window -t "$sname" -v
  fi
  tmux select-layout -t "$sname" tiled
done
