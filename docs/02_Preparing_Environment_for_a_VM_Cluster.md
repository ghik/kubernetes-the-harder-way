\[ [macOS/ARM64](../../macos/docs/02_Preparing_Environment_for_a_VM_Cluster.md) | **Linux/AMD64** \]

Previous: [Learning How to Run VMs with QEMU](01_Learning_How_to_Run_VMs_with_QEMU.md)

# Preparing Environment for a VM Cluster

Ok, we are decently proficient with QEMU and `cloud-init` now. It's time to start building an actual cluster for
our Kubernetes deployment.

In this chapter, we will focus on preparing everything that needs to be done on the host machine before we
can launch the cluster. This includes:
* automating preparation of VM image files
* configuring shared network for the VMs

From now on, we'll put as much as we can into scripts.
This way we can easily do iterative improvements and experiments to our VM setup.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Prerequisites](#prerequisites)
- [Topology overview](#topology-overview)
- [Image preparation](#image-preparation)
  - [VM setup script](#vm-setup-script)
    - [Impromptu bash "templating" for `cloud-init` files](#impromptu-bash-templating-for-cloud-init-files)
    - [Running](#running)
  - [Testing the VM](#testing-the-vm)
- [Shared network setup](#shared-network-setup)
  - [TAP interfaces](#tap-interfaces)
  - [Virtual bridge](#virtual-bridge)
  - [Connecting TAP interfaces to the bridge](#connecting-tap-interfaces-to-the-bridge)
  - [Enabling IP forwarding on the host machine](#enabling-ip-forwarding-on-the-host-machine)
  - [Setting up NAT](#setting-up-nat)
  - [Using `dnsmasq`](#using-dnsmasq)
    - [Making sure `dnsmasq` starts after network](#making-sure-dnsmasq-starts-after-network)
  - [DHCP server configuration](#dhcp-server-configuration)
  - [DNS server configuration](#dns-server-configuration)
  - [Testing the network setup](#testing-the-network-setup)
- [Remote SSH access](#remote-ssh-access)
  - [Automating establishment of VM's authenticity](#automating-establishment-of-vms-authenticity)
- [Installing APT packages](#installing-apt-packages)
- [Summary](#summary)
- [Resources](#resources)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Make sure you have all the necessary [packages](00_Introduction.md#software) installed.
Since the [previous chapter](01_Learning_How_to_Run_VMs_with_QEMU.md) is purely educational,
completing it is not a strict prerequisite for this chapter.

## Topology overview

Let's remind us how we want our cluster to look like. As already laid out in the [introduction](00_Introduction.md#deployment-overview),
we want 7 machines in total:

* load balancer VM for the Kubernetes API - let's call it `gateway`
* three control plane VMs - let's call them `control0`, `control1`, and `control2`
* three worker nodes - let's call them `worker0`, `worker1`, and `worker2`

These names will be primarily used as VM hostnames.

Additionally, let's assign the VMs an abstract numeric ID. This ID will come in handy in scripts when we
want to differentiate between the VMs

* `gateway` has ID 0
* `control` nodes have IDs 1 through 3
* `worker` nodes have IDs 4 through 6

## Image preparation

Before we start doing anything, let's have a clean directory for all of our work, e.g.

```bash
mkdir kubenet && cd kubenet
```

> [!IMPORTANT]
> Make sure this is a _clean_ directory, i.e. do not reuse scripts and files from the guide's repository.
> They serve only as a reference and represent the final outcome of completing **all** the chapters.
> They are also used in the [express variant](09_TLDR_Version_of_the_Guide.md) of this guide.

Now let's create a helper function to convert a VM ID into VM name, and put it into
the `helpers.sh` file that can be later included into other scripts:

```bash
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

Let's make a `vmsetup.sh` script that will do everything necessary to launch a single VM.
It will be responsible for creating a directory for a VM, creating a QCOW2 image backed by Ubuntu cloud image, 
writing out `cloud-init` config files, and putting them into a `cidata.iso` image. 
The script will take machine ID as an argument.

First, let's make sure we have the cloud image file in working directory. If you downloaded during the 
[previous part](01_Learning_How_to_Run_VMs_with_QEMU.md) of this tutorial, move or copy it into current directory. 
If not, download it with:

```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

Now for the actual script:

```bash
#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

# Grab the helpers
source "$dir/helpers.sh"

# Parse the argument
vmid=$1
vmname=$(id_to_name $vmid)
vmdir="$dir/$vmname"

# Strip the number off VM name, leaving only VM "type", i.e. gateway/control/worker
vmtype=${vmname%%[0-9]*}

# Make sure VM directory exists
mkdir -p "$vmdir"

# Prepare the VM disk image
qemu-img create -F qcow2 -b ../noble-server-cloudimg-amd64.img -f qcow2 "$vmdir/disk.img" 20G

# Prepare `cloud-init` config files
cat << EOF > "$vmdir/meta-data"
instance-id: $vmname
local-hostname: $vmname
EOF

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
```

> [!NOTE]
> * `set -e` makes sure that the script fails immediately if any command returns a non-zero exit status
> * `set -x` causes every command to be logged on standard output, making it easier for us to see what's going on
> * `dir=$(dirname "$0")` saves the script's parent directory to a variable - we use it to make the script
>    independent of working directory

#### Impromptu bash "templating" for `cloud-init` files

You might be perplexed by this ungodly incantation:

```bash
eval "cat << EOF
$(<"$dir/cloud-init/user-data.$vmtype")
EOF
" > "$vmdir/user-data"
```

(and a similar one for `network-config`)

It assumes that we have three "bash template" files in the `cloud-init` directory 
(`user-data.gateway`, `user-data.control`, `user-data.worker`). For our purposes, a "bash template" is
a text file that may contain references to shell variables and other shell substitutions (e.g. commands).
The incantation above "evaluates" one of these templates and saves it as VM's ready `user-data`.

For now, these template files will be just stubs, setting only the password for current user:

```bash
mkdir -p cloud-init
for vmtype in gateway control worker
do cat << EOF > "cloud-init/user-data.$vmtype"
#cloud-config
password: ubuntu
EOF
done
```

In a similar manner, we also set up template files for `network-config`. We will use them later, while leaving them
empty for now:

```bash
touch cloud-init/network-config.{gateway,control,worker}
```

The templating part will come in handy later. We will modify and extend these files multiple times
throughout this guide.

#### Running

Let's give the script proper permissions, and run it (for the `gateway` VM):

```bash
chmod u+x vmsetup.sh
./vmsetup.sh 0
```

> [!NOTE]
> Throughout this chapter, we'll be testing our setup using only the `gateway` VM.
> We'll launch the entire VM cluster in the next chapter.

### Testing the VM

If the setup script succeeds, we can do a test-run of the `gateway` VM:

```bash
sudo qemu-system-x86_64 \
    -nographic \
    -machine q35,accel=kvm \
    -cpu host \
    -smp 2 \
    -m 2G \
    -bios /usr/share/qemu/OVMF.fd \
    -nic user \
    -hda gateway/disk.img \
    -drive file=gateway/cidata.iso,driver=raw,if=virtio
```

The machine should run, and you should be able to log in, 
like we've done in the [previous chapter](01_Learning_How_to_Run_VMs_with_QEMU.md#running-a-cloud-image).

## Shared network setup

Let's clarify the requirements for the shared network for the VMs. We want them to:

* live in the same local (layer 2) network
* have stable and predictable IP addresses
* be addressable using hostnames
* be directly accessible from the host machine (but not necessarily from outside world)
* have internet access
* require as little direct network configuration as possible

So far, the entire network setup for our VMs consisted of this QEMU option:

```
-nic user
```

This provided the VM with internet access, but had poor performance, and the VM was not addressable from the host
machine. This type of network also cannot be shared between multiple VMs.

### TAP interfaces

We need to do something more advanced. Instead of `user`, we'll use the `tap` backend:

```
-nic tap
```

This creates a [TAP](https://en.wikipedia.org/wiki/TUN/TAP) interface in the host system - a special kind of network 
interface which can be read and written by an userspace program. In this case, that program is QEMU, and it "connects" 
the TAP interface to an interface inside the VM. This effectively creates a point-to-point, layer 2 connection
between the host system and the VM.

> [!NOTE]
> Creating TAP interfaces typically requires root privileges, 
> so we must run QEMU with `sudo` when using the `tap` backend.

However, creating a TAP interface alone does not give the VM layer 3 connectivity and internet access. That requires
some more plumbing in the host system. By default, `qemu` invokes predefined scripts for additional setup and teardown
of TAP interfaces. These can be found in `/etc/qemu-ifup` and `/etc/qemu-ifdown`. The default implementation of
`qemu-ifup` is to search for a virtual bridge interface in the host system corresponding to default route. The TAP
interface is then connected to that bridge.

We want to take full control of this process. Fortunately, `qemu` allows us to pass custom scripts for TAP interface
setup and teardown. 

### Virtual bridge

Our intention is to connect all the VMs and the host machine with a private local network. In order to achieve
that, we must first create a _virtual bridge_. The raw commands to do that are:

```bash
sudo ip link add kubr0 type bridge
sudo ip link set kubr0 up
```

We choose **192.168.3.0/24** as the CIDR for the network, where 192.168.1.1 is the host machine address.
Let's make this a reality:

```bash
sudo ip addr add 192.168.3.1/24 dev kubr0
```

You can inspect the effects of these commands with `ip addr show kubr0`. You should see something like this:

```
3: kubr0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN group default qlen 1000
    link/ether f6:a5:e7:4d:09:9a brd ff:ff:ff:ff:ff:ff
    inet 192.168.3.1/24 scope global kubr0
       valid_lft forever preferred_lft forever
```

> [!NOTE]
> Do not worry about the state of bridge being `DOWN` - it will change to `UP` when at least one VM successfully
> connects to it.

Unfortunately, network configuration using raw `ip` command will not survive a system restart. In order to make it
persistent, we can create a relevant configuration in the Ubuntu `netplan` utility:

```bash
cat <<EOF | sudo tee /etc/netplan/99-kubenet.yaml
network:
  version: 2
  bridges:
    kubr0:
      addresses: [192.168.3.1/24]
EOF

sudo chmod 600 /etc/netplan/99-kubenet.yaml
sudo netplan apply
```

### Connecting TAP interfaces to the bridge

The bridge is ready, and now we need to make sure that QEMU connects TAP interfaces to that bridge. For that, we
create a simple script, `tapup.sh`:

```bash
#!/usr/bin/env sh

ifname="$1"
ip link set "$ifname" master kubr0
ip link set "$ifname" up
```

QEMU can be instructed to use this script with:

```
-nic tap,script=tapup.sh,downscript=no
```

> [!IMPORTANT]
> Don't forget to give `tapup.sh` executable permissions

### Enabling IP forwarding on the host machine

VMs need to communicate with the external world. In order for that to work, our host machine must act like a router
and allow traffic forwarding. To enable this, run:

```bash
sudo sysctl net.ipv4.ip_forward=1
```

In order to make this persistent between system restarts:

```bash
cat <<EOF | sudo tee /etc/sysctl.d/50-ip-forward.conf
net.ipv4.ip_forward = 1
EOF
sudo sysctl -p /etc/sysctl.d/50-ip-forward.conf
```

### Setting up NAT

The network setup is still not enough to allow internet access to our VMs.

Packets leaving the 192.168.1.0/24 network must have their source addresses translated in order for the returning
packets to be routable from the external world. On Linux, this is typically done by setting up NAT in `iptables`:

```bash
sudo iptables -t nat -A POSTROUTING ! -o kubr0 -s 192.168.1.0/24 -j MASQUERADE
```

The condition `! -o kubr0 -s 192.168.1.0/24` ensures that NAT is performed for packets originating from
192.168.1.0/24 and destined for outgoing interface other than `kubr0`.

> [!NOTE]
> The `! -o kubr0` condition will be necessary for a reason very specific to our future Kubernetes deployment, 
> in which addresses from the private pod CIDR may need to be routable between VMs. The
> [relevant chapter](06_Spinning_up_Worker_Nodes.md#routing-pod-traffic-via-the-host-machine) 
> contains the details.

Setting up NAT this way is very rudimentary. Let's make it more automated and bulletproof with a special 
`systemd` one-shot service. For that, first create a system script to set up `iptables` a little more properly:

```bash
cat <<EOF | sudo tee /usr/local/bin/kubenet-nat.sh
#!/usr/bin/env sh

# Remove any previously added rules to keep the script idempotent
if iptables -t nat -L KUBENET_NAT > /dev/null 2>&1; then
  iptables -t nat -D POSTROUTING -j KUBENET_NAT
  iptables -t nat -F KUBENET_NAT
  iptables -t nat -X KUBENET_NAT
fi

iptables -t nat -N KUBENET_NAT
iptables -t nat -A POSTROUTING -j KUBENET_NAT
iptables -t nat -A KUBENET_NAT ! -o kubr0 -s 192.168.1.0/24 -j MASQUERADE
EOF
sudo chmod +x /usr/local/bin/kubenet-nat.sh
```

Then, create a `systemd` _unit file_, which makes sure that this script is invoked on every system boot:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubenet-nat.service
[Unit]
Description=Kubenet VM network NAT rules
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kubenet-nat.sh

[Install]
WantedBy=multi-user.target
EOF
```

Enable and run it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable kubenet-nat
sudo systemctl start kubenet-nat
```

> [!NOTE]
> We'll talk a bit more about `systemd` in 
> [another chapter](05_Installing_Kubernetes_Control_Plane.md#quick-overview-of-systemd).

This has the following advantages:
* it is persistent between system restarts
* it is _idempotent_ (can be invoked multiple times with the same end result)
* it is more readable and maintainable thanks to usage of dedicated `KUBENET_NAT` chain

> [!IMPORTANT]
> This `iptables` setup was tested on a system that has no other rules and allows all traffic by default.
> You may need to create additional rules, especially in the `filter` table, if your system configuration is stricter 
> and more complex. You also need to make sure that `iptables` rules set up by different tools don't interfere.

### Using `dnsmasq`

A running VM needs a DHCP server in its local network, as well as a DNS server.
We will use [`dnsmasq`](https://en.wikipedia.org/wiki/Dnsmasq) for that. If you followed
[prerequisites](#prerequisites), you should have it installed already. It will serve both as a DHCP and
as a DNS server.

First, we need to make sure that it does not interfere with other servers on the same machine (e.g. `systemd-resolve`)
The easiest way to do this is to make sure it only binds to the virtual bridge. This can be done with the 
following configuration options:

```
interface=kubr0
bind-interfaces
```

Add them to `dnsmasq` configuration file, which typically sits at `/etc/dnsmasq.conf`. 

Then, restart it with:

```bash
sudo systemctl restart dnsmasq
```

#### Making sure `dnsmasq` starts after network

Unfortunately, there's one more hurdle to overcome: if you reboot your system, `dnsmasq` may fail to start properly,
because (in the default configuration) the system will attempt to start it before the `kubr0` interface is created.

Fixing this will require some plumbing that involves interaction between two "system initialization" solutions that
coexist on Ubuntu: the venerable System V Init system, and [`systemd`](https://systemd.io), its more modern successor.
There's no reason to delve into details (we'll talk a bit more about `systemd` in 
[another chapter](05_Installing_Kubernetes_Control_Plane.md#quick-overview-of-systemd)), let's just quickly lay out
the situation, so that we have a rough understanding of what's going on:

* `dnsmasq` uses classic SysV-init start/stop scripts in `/etc/init.d/`, it does not define a `systemd` unit file
* For compatibility, `systemd` integrates with SysV-init - that's why we can use `systemctl` to start/stop `dnsmasq`
* SysV-init scripts for `dnsmasq` are not aware of the dependency on the `kubr0` interface
* In order to express this dependency, we need to define a proper `systemd` unit file and disable the SysV-Init scripts

Here's how to do that:

```bash
cat <<EOF | sudo tee /etc/systemd/system/dnsmasq.service
[Unit]
Description=DNSmasq DNS and DHCP server
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
ExecStart=/etc/init.d/dnsmasq start
ExecStop=/etc/init.d/dnsmasq stop

[Install]
WantedBy=multi-user.target
EOF
```

Now, reconfigure SysV-init and `systemd`:

```bash
sudo update-rc.d dnsmasq disable
sudo systemctl daemon-reload
sudo systemctl enable dnsmasq
```

### DHCP server configuration

Let's assign predictable MAC addresses to our VMs. This is as simple as adding another property
to the `-nic` QEMU option. Assuming that `vmid` shell variable contains VM ID, it would look like this:

```
-nic tap,...,mac=52:52:52:00:00:0$vmid
```

In other words, our machines will get MACs in the range `52:52:52:00:00:00` to `52:52:52:00:00:06`.

> [!NOTE]
> If you want this to be more bulletproof (prepared for more than 10 VMs), you can use something like 
> `$(printf "%02x\n" $vmid)` as the last byte of the MAC address.

Now it's time to configure `dnsmasq`'s DHCP server:
* define a DHCP address range
* associate fixed IPs with VM MACs - in order for them to look nice, we choose the range
  from `192.168.1.10` to `192.168.1.16` (i.e. `192.168.1.$((10 + $vmid))` in shell script syntax)
* make the server _authoritative_

This is the resulting configuration:

```
dhcp-range=192.168.1.2,192.168.1.20,12h
dhcp-host=52:52:52:00:00:00,192.168.1.10
dhcp-host=52:52:52:00:00:01,192.168.1.11
dhcp-host=52:52:52:00:00:02,192.168.1.12
dhcp-host=52:52:52:00:00:03,192.168.1.13
dhcp-host=52:52:52:00:00:04,192.168.1.14
dhcp-host=52:52:52:00:00:05,192.168.1.15
dhcp-host=52:52:52:00:00:06,192.168.1.16
dhcp-authoritative
```

Add this to the contents of `/etc/dnsmasq.conf`.

### DNS server configuration

Let's give some hostnames to our VMs. The `vmsetup.sh` script already makes sure that VMs know their hostnames
via `meta-data`. Now we need to make sure that the host machine and VMs can refer to each other using these hostnames. 
In other words, we need to configure a DNS server.

To assign domain names to IPs, we can simply use `/etc/hosts` on the host machine. `dnsmasq` DNS server
will pick it up:

```
192.168.1.1   vmhost
192.168.1.10  gateway
192.168.1.11  control0
192.168.1.12  control1
192.168.1.13  control2
192.168.1.14  worker0
192.168.1.15  worker1
192.168.1.16  worker2
192.168.1.21  kubernetes
```

> [!NOTE]
> We have also assigned a domain name `vmhost` to the host machine itself.

> [!NOTE]
> The mysterious `kubernetes` domain name is assigned to a virtual IP that will serve the Kubernetes API
> via the load balancer VM (`gateway`). We are including it for the sake of completeness. We will set it up properly
> in [another chapter](05_Installing_Kubernetes_Control_Plane.md#kubernetes-api-load-balancer), so do not bother about
> it now. You may note how it is outside the configured DHCP IP range to reduce the risk of IP conflicts.

Finally, let's put all the VMs into a _domain_. Add these lines into `dnsmasq` configuration:

```
domain=kubenet
expand-hosts
```

This tells the DHCP server to include a DHCP option 15 (domain name) into DHCP responses. Without it,
DNS queries for unqualified hosts (e.g. `nslookup worker0`) performed by VMs would not work.
Additionally, `expand-hosts` option allows the DNS server to append domain name to simple names
listed in `/etc/hosts`.

Restart `dnsmasq` to apply changes:

```bash
sudo systemctl restart dnsmasq
```

### Testing the network setup

Let's run the `gateway` VM to test what we just configured.

Make sure to reformat its image, to clear any network configuration that may have been persisted in a previous run:

```bash
./vmsetup.sh 0
```

Then run it:

```bash
sudo qemu-system-x86_64 \
    -nographic \
    -machine q35,accel=kvm \
    -cpu host \
    -smp 2 \
    -m 2G \
    -bios /usr/share/qemu/OVMF.fd \
    -nic tap,script=tapup.sh,downscript=no,mac=52:52:52:00:00:00 \
    -hda gateway/disk.img \
    -drive file=gateway/cidata.iso,driver=raw,if=virtio
```

Run `ip addr` on the VM to see if it got the right IP:

```
ubuntu@gateway:~$ ip addr
...
2: enp0s2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 52:52:52:00:00:00 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.10/24 metric 100 brd 192.168.1.255 scope global dynamic enp0s2
       valid_lft 42983sec preferred_lft 42983sec
    inet6 fe80::5052:52ff:fe00:0/64 scope link
       valid_lft forever preferred_lft forever
```

Run `ip route` to see if the VM got the right default gateway:

```
ubuntu@gateway:~$ ip route
default via 192.168.1.1 dev enp0s2 proto dhcp src 192.168.1.10 metric 100
192.168.1.0/24 dev enp0s2 proto kernel scope link src 192.168.1.10 metric 100
192.168.1.1 dev enp0s2 proto dhcp scope link src 192.168.1.10 metric 100
```

Finally, let's validate the DNS configuration with `resolvectl status`:

```
ubuntu@gateway:~$ resolvectl status
Global
       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: stub

Link 2 (enp0s2)
    Current Scopes: DNS
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 192.168.1.1
       DNS Servers: 192.168.1.1
        DNS Domain: kubenet
```

You can also test DNS resolution with `resolvectl query` (or other like `nslookup`, `dig`, etc.)

```
ubuntu@gateway:~$ resolvectl query worker0
worker0: 192.168.1.14                          -- link: enp0s2
         (worker0.kubenet)
```

## Remote SSH access

The network is set up, the VMs have stable IP addresses and domain names.
Now we would like to be able to access them from the host machine via SSH.

A VM that was set up from a cloud image already has an SSH server up and running.
However, by default it is configured to reject login-based attempts. We must authenticate using a public key,
which must be preconfigured on the VM.

Make sure you have an SSH key prepared on the host machine (`~/.ssh/id_rsa.pub`).
If not, run:

```
ssh-keygen
```

This will generate a keypair: a private key (`~/.ssh/id_rsa`) and a public key (`~/.ssh/id_rsa.pub`).
We must now authorize this public key inside the VM by adding it to VM's `~/.ssh/authorized_keys` file.

If you're already running the VM, you can do this manually: just append the contents of your
`~/.ssh/id_rsa.pub` file to the VM's `~/.ssh/authorized_keys` file (create it if it doesn't exist).

We'll also automate it with `cloud-init`. Edit all the `user-data` template files in `cloud-init` directory
and replace the `password: ubuntu` line with the following entry:

```
ssh_authorized_keys:
  - $(<~/.ssh/id_rsa.pub)
```

> [!NOTE]
> This is where we're starting to make use of templating capabilities of these files.
> Also, it may be annoying that we have to copy this entry into 3 separate files.
> The amount of repetition is however small enough that getting rid of it would not be worth 
> the cost in additional complexity (the templating already makes things complex).

> [!IMPORTANT]
> Remember that any changes in `cloud-init` configs require resetting the VM state (reformatting its disk image)
> or changing the `instance-id` in order to take effect.

### Automating establishment of VM's authenticity

Run your VM and try connecting with SSH. You'll be asked if you trust this VM:

```
$ ssh ubuntu@gateway
The authenticity of host 'gateway (192.168.1.10)' can't be established.
ED25519 key fingerprint is SHA256:1ee+avZjtffo7DbiKq3xds1AqK6So0ezcBLYwd09iUw.
This key is not known by any other names
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

You can say `yes` and VM's key will be added to `.ssh/known_hosts` on the host machine, and from on now
you'll be able to log in without any hassle. Unfortunately, if you reset your VM and run it again, you'll
see something less pleasant:

```
$ ssh ubuntu@gateway
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
It is also possible that a host key has just been changed.
The fingerprint for the ED25519 key sent by the remote host is
SHA256:rG8nVZF97bvhXD0ck5FOh6PC06bm4FpDdTmz0tEZyYo.
Please contact your system administrator.
Add correct host key in /Users/rjghik/.ssh/known_hosts to get rid of this message.
Offending ECDSA key in /Users/rjghik/.ssh/known_hosts:12
Host key for gateway has changed and you have requested strict checking.
Host key verification failed.
```

In order to get rid of that, you'll need to remove stale entries for this machine from
your `~/.ssh/known_hosts` file.

Let's automate all this with a script, `vmsshsetup.sh`:

```bash
#!/usr/bin/env bash

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
  sed -i "/^$vmname/d" ~/.ssh/known_hosts
fi

# Add new entries for this VM to known_hosts
ssh-keyscan "$vmname" 2> /dev/null >> ~/.ssh/known_hosts

# Wait until the system boots up and starts accepting unprivileged SSH connections
until ssh "ubuntu@$vmname" exit; do sleep 1; done
```

Let's break it down:

1. Just like `vmsetup.sh`, `vmsshsetup.sh` takes VM ID as an argument.
2. The script waits until the VM is able to accept SSH connections.
   This is useful when running `vmsshsetup.sh` immediately after launching the VM.
3. The script removes stale entries for this VM from the `known_hosts` file.
4. Using `ssh-keyscan`, the script grabs VM's SSH keys and makes them trusted by adding them
   to the `known_hosts` file
5. Even though the VM is already listening on SSH port, unprivileged SSH connections may be rejected until the VM
   boot process is finished. We run a probing SSH connection in a loop to make sure that the VM is _actually_ ready.

Don't forget to give the script executable permissions and run it for the `gateway` VM 
with `./vmsshsetup 0` (make sure the VM is running).

Et voilà! You can now SSH into your VM without any trouble.

## Installing APT packages

Throughout this guide, we will need to install a few APT packages on the VMs 
(although not for the Kubernetes itself). We would like these packages to be installed automatically upon VM's first
boot so that we don't have to do it manually after each VM reset.

Fortunately, this is very easy with `cloud-init`. Simply edit the `cloud-init/user-data.<vmtype>` template file and
add the `packages` key listing all the desired packages. For example, in order to make sure `curl` is installed:

```yaml
packages:
  - curl
```

If you feel like it, you can also instruct `cloud-init` to automatically upgrade the system to newest package versions,
and even allow it to reboot the machine if necessary (e.g. whe the kernel is updated):

```yaml
package_update: true
package_upgrade: true
package_reboot_if_required: false
```

## Summary

In this chapter, we have:
* created a script that prepares each VM's image and `cloud-init` configuration
* prepared proper network environment for the cluster on the host machine, including a DHCP and DNS server using `dnsmasq`
* automated everything necessary to connect to our VMs with SSH
* learned how to make sure that desired APT packages are installed on VMs

## Resources

1. [`dnsmasq` manpage](https://manpages.debian.org/bookworm/dnsmasq-base/dnsmasq.8.en.html)

Next: [Launching the VM Cluster](03_Launching_the_VM_Cluster.md)
