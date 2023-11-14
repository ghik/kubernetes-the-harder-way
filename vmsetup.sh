#!/usr/bin/env bash

# This script formats VM images (main disk drive and CIDATA drive).

set -xe
dir=$(dirname "$0")

source "$dir/helpers.sh"
source "$dir/variables.sh"

# Parse the argument
vmid=$1
vmname=$(id_to_name "$vmid")
vmdir="$dir/$vmname"

# Strip the number off VM name, leaving only VM "type", i.e. gateway/control/worker
vmtype=${vmname%%[0-9]*}

# Make sure VM directory exists
mkdir -p "$vmdir"

# Prepare the VM disk image
qemu-img create -F qcow2 -b ../jammy-server-cloudimg-${arch}.img -f qcow2 "$vmdir/disk.img" 20G

# Prepare `cloud-init` config files
cat << EOF > "$vmdir/meta-data"
instance-id: $vmname
local-hostname: $vmname
EOF

if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
  echo "No SSH public key found for current user. Generate it with ssh-keygen." >&2
  exit 1
fi

# Evaluate `user-data` "bash template" for this VM type and save the result
eval "cat << EOF
$(<"$dir/cloud-init/user-data.$vmtype")
EOF
" > "$vmdir/user-data"

# Evaluate `network-config` "bash template" for this VM type and save the result
eval "cat << EOF
$(<"$dir/cloud-init/network-config.$vmtype")
EOF
" > "$vmdir/network-config"

# Build the `cloud-init` ISO
mkisofs -output "$vmdir/cidata.iso" -volid cidata -joliet -rock "$vmdir"/{user-data,meta-data,network-config}
