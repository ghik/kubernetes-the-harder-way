#!/usr/bin/env bash
set -xe
dir=$(dirname "$0")

# Grab our helpers
source "$dir/helpers.sh"

# Parse the argument
vmid=$1
vmname=$(id_to_name "$vmid")
vmdir="$dir/$vmname"

# Make sure VM directory exists
mkdir -p "$vmdir"

# Prepare the VM disk image
qemu-img create -F qcow2 -b ../jammy-server-cloudimg-arm64.img -f qcow2 "$vmdir/disk.img" 20G

# Prepare `cloud-init` config files
cat << EOF > "$vmdir/user-data"
#cloud-config
password: ubuntu
chpasswd:
  expire: False
ssh_authorized_keys:
  - $(<~/.ssh/id_rsa.pub)
EOF

cat << EOF > "$vmdir/meta-data"
instance-id: $vmname
local-hostname: $vmname
EOF

# Build the `cloud-init` ISO
mkisofs -output "$vmdir/cidata.iso" -volid cidata -joliet -rock "$vmdir"/{user-data,meta-data}

