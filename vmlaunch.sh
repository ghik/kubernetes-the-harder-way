#!/usr/bin/env bash

# This script launches a single VM, identified by its numeric ID.

set -xe
dir=$(dirname "$0")

# Grab the helpers
source "$dir/helpers.sh"

# Parse the argument (VM ID)
vmid=$1
vmname=$(id_to_name "$vmid")
vmdir="$dir/$vmname"

# Assign resources
case "$vmname" in
  gateway|control*)
    vcpus=2
    memory=2G
    ;;
  worker*)
    vcpus=4
    memory=4G
    ;;
esac

# Compute the MAC address
mac="52:52:52:00:00:0$vmid"

case $(uname -m) in
  arm64|aarch64) qemu_arch=aarch64;;
  x86_64|amd64) qemu_arch=x86_64;;
esac

case $(uname -s) in
  Darwin)
    efi="/opt/homebrew/share/qemu/edk2-${qemu_arch}-code.fd"
    machine="virt,accel=hvf,highmem=on"
    nic="vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0"
    ;;
  Linux)
    efi="/usr/share/qemu/OVMF.fd"
    machine="q35,accel=kvm"
    nic="tap,script=$dir/tapup.sh"
    ;;
esac

# Launch the VM
qemu-system-${qemu_arch} \
    -nographic \
    -machine $machine \
    -cpu host \
    -smp $vcpus \
    -m $memory \
    -bios "$efi" \
    -nic "$nic,mac=$mac" \
    -hda "$vmdir/disk.img" \
    -drive file="$vmdir/cidata.iso",driver=raw,if=virtio
