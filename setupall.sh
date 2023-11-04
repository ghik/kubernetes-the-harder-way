#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")
sudo -v

export USE_CILIUM

brew install qemu wget curl cdrtools dnsmasq tmux cfssl kubernetes-cli jq helm

cd "$dir/auth"
./genauth.sh
./genenckey.sh
./setuplocalkubeconfig.sh
cd ..

wget -P "$dir" -q --show-progress --https-only --timestamping \
  https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img

"$dir/vmsetupall.sh"
sudo -E "$dir/setuphost.sh"
sudo "$dir/vmlaunchall.sh" kubenet-qemu

for vmid in $(seq 0 6); do
  "$dir/vmsshsetup.sh" $vmid
done

"$dir/deploysetup.sh"
"$dir/auth/deployauth.sh"
"$dir/deploybinaries.sh"

pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo ./setupcontrol.sh" &
  pids+=($!)
done
wait ${pids[@]}

ssh ubuntu@gateway "sudo ./setupgateway.sh"

pids=()
for i in $(seq 0 2); do
  ssh ubuntu@control$i "sudo USE_CILIUM=$USE_CILIUM ./setupnode.sh" &
  pids+=($!)
done
for i in $(seq 0 2); do
  ssh ubuntu@worker$i "sudo USE_CILIUM=$USE_CILIUM ./setupnode.sh" &
  pids+=($!)
done
wait ${pids[@]}

if [[ -z $USE_CILIUM ]]; then
  sudo "$dir/setuproutes.sh"
fi

"$dir/setupkubeletaccess.sh"
"$dir/addhelmrepos.sh"
"$dir/setupcluster.sh"

echo "Your Kubernetes cluster is now fully functional!"
