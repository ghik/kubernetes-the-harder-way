#!/usr/bin/env bash
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

# Launch the VM
qemu_version=$(qemu-system-aarch64 --version | head -n 1 | sed "s/^QEMU emulator version //")
qemu-system-aarch64 \
    -nographic \
    -machine virt,accel=hvf,highmem=on \
    -cpu host \
    -smp $vcpus \
    -m $memory \
    -bios "/opt/homebrew/Cellar/qemu/$qemu_version/share/qemu/edk2-aarch64-code.fd" \
    -nic vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0,"mac=$mac" \
    -hda "$vmdir/disk.img" \
    -drive file="$vmdir/cidata.iso",driver=raw,if=virtio

