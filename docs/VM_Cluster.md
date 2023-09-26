# Setting up a cluster of VMs

Ok, we are already decently proficient with QEMU and `cloud-init`. It's time to start building an actual cluster for
our Kubernetes deployment. Things that we'll focus on in this chapter include:

* setting up proper environment for all our machines to live in (network, etc.)
* automating VM setup and launching with shell scripts

The scripting part is especially important because it will enable iterative improvements and experiments. 
At any moment, we'll be able to tear down everything we've launched, make some changes to the cluster setup and 
launch everything from scratch.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Topology overview](#topology-overview)
- [Preparing the environment](#preparing-the-environment)
  - [Setting up the workplace](#setting-up-the-workplace)
  - [VM setup script](#vm-setup-script)
  - [Testing the VM](#testing-the-vm)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Topology overview

Let's remind us how we want our cluster to look like. As already laid out in the [introduction](Introduction.md#deployment-overview),
we want 7 machines in total:

* load balancer VM for the Kubernetes API, let's call it `gateway`
* three control plane VMs, let's call them `control0`, `control1`, and `control2`
* three worker nodes, let's call them `worker0`, `worker1`, and `worker2`

These names will be primarily used as VM hostnames.

Additionally, let's assign the VMs an abstract numeric ID. This ID will come in handy in scripts when we
want to differentiate between the VMs

* `gateway` has ID 0
* `control` nodes have IDs 1 through 3
* `worker` nodes have IDs 4 through 6

## Preparing the environment

In this subchapter we'll take care of automating everything that needs to be done before VMs can be launched.
This includes preparation of image files and other necessary data, and proper network setup on the host machine.

### Setting up the workplace

Before we start doing anything, let's have a clean directory for all of our work, e.g.

```bash
mkdir kubevms && cd kubevms
```

Now let's create some helper shell functions to convert between VM names and IDs and put them into
a helpers file `helpers.sh` that can be later included into each script:

```bash
name_to_id() {
  case $1 in
    gateway) echo 0;;
    control[0-2]) echo $((1 + ${1#control}));;
    worker[0-2]) echo $((4 + ${1#worker}));;
    *) echo "Bad machine name: $1" >&2; return 1
  esac
}

id_to_name() {
  id=$1
  if [[ ! $id =~ ^-?[0-9]+$ ]]; then echo "bad machine ID: $id" >&2; return 1
  elif [[ $id -eq 0 ]]; then echo gateway
  elif [[ $id -le 3 ]]; then echo control$(($id - 1))
  elif [[ $id -le 6 ]]; then echo worker$(($id - 4))
  else echo "bad machine ID: $id" >&2; return 1
  fi
}
```

### VM setup script

Let's make a `vmsetup.sh` script that will do everything necessary to launch a single VM. The initial version of this script
will create a directory for a VM, create a QCOW2 image backed by Ubuntu cloud image, write `cloud-init` config files
and format the `cidata.iso` image. The script will take machine ID as an argument.

First, let's make sure we have the cloud image file in working directory. If you downloaded during the [previous part](../QEMU.md)
of this tutorial, move or copy it into current directory. If not, download it with:

```bash
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img
```

Now for the actual script:

```bash
#!/usr/bin/env bash

# Log every command and fail immediately if any command returns non-zero return code
set -xe
# Save the script's parent directory. We'll use it throughout this script in order to avoid
# relying on working directory. This way the script is safe to run from any directory.
dir="$(dirname $0)"

# Grab our helpers
source "$dir"/helpers.sh

# Parse the argument
vmid=$1
vmname=$(id_to_name $vmid)
vmdir="$dir/$vmname"

# Make sure VM directory exists
mkdir -p "$vmdir"

# Prepare the VM disk image
qemu-img create -F qcow2 -b ../jammy-server-cloudimg-arm64.img -f qcow2 "$vmdir"/disk.img 20G

# Prepare `cloud-init` config files
cat << EOF > "$vmdir"/user-data
#cloud-config
password: ubuntu
EOF

cat << EOF > "$vmdir"/meta-data
instance-id: $vmname
EOF

# Build the `cloud-init` ISO
mkisofs -output "$vmdir"/cidata.iso -volid cidata -joliet -rock "$vmdir"/{user-data,meta-data}
```

Let's give it proper permissions and run it for the `gateway` VM:

```bash
chmod u+x vmsetup.sh
./vmsetup.sh 0
```

### Testing the VM

If the setup script succeeds, we can do a test-run of the VM. Before we do that, let's copy the UEFI firmware
into current directory, for convenience:

```bash
QEMU_VERSION=$(qemu-system-aarch64 --version | head -n 1 | sed "s/^QEMU emulator version //")
cp /opt/homebrew/Cellar/qemu/${QEMU_VERSION}/share/qemu/edk2-aarch64-code.fd OVMF.fd
```

Let's launch the VM:

```bash
sudo qemu-system-aarch64 \
    -nographic \
    -machine virt,accel=hvf,highmem=on \
    -cpu host \
    -smp 2 \
    -m 2G \
    -bios OVMF.fd \
    -nic vmnet-shared \
    -hda gateway/disk.img \
    -drive file=gateway/cidata.iso,driver=raw,if=virtio
```

The machine should run and you should be able to log in, like we've done in the [previous chapter](QEMU.md#running-a-cloud-image).
