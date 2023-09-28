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

- [Prerequisites](#prerequisites)
- [Topology overview](#topology-overview)
- [Preparing the environment](#preparing-the-environment)
  - [Setting up the workplace](#setting-up-the-workplace)
  - [VM setup script](#vm-setup-script)
  - [Testing the VM](#testing-the-vm)
  - [Setting up network environment](#setting-up-network-environment)
    - [`dnsmasq`](#dnsmasq)
    - [Choosing an IP range](#choosing-an-ip-range)
    - [DHCP server configuration](#dhcp-server-configuration)
    - [DNS server configuration](#dns-server-configuration)
    - [Testing the network setup](#testing-the-network-setup)
  - [Remote SSH access](#remote-ssh-access)
    - [Automating establishment of VM's authenticity](#automating-establishment-of-vms-authenticity)
- [Launching the cluster](#launching-the-cluster)
  - [Granting resources](#granting-resources)
  - [VM launching script](#vm-launching-script)
  - [TMUX](#tmux)
    - [Basic `tmux` controls](#basic-tmux-controls)
    - [Commands and shortcuts](#commands-and-shortcuts)
    - [Working with panes](#working-with-panes)
    - [Configuration and customization](#configuration-and-customization)
    - [Detaching and attaching](#detaching-and-attaching)
    - [Scriptability](#scriptability)
  - [Launching a cluster of VMs in `tmux`](#launching-a-cluster-of-vms-in-tmux)
    - [A script to launch everything](#a-script-to-launch-everything)
    - [Liftoff](#liftoff)
- [Summary](#summary)
- [Resources](#resources)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Make sure you have the following packages installed:

```bash
brew install wget qemu cdrtools dnsmasq flock
```

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

Now let's create a helper function to convert a VM ID into VM name. Let's put it into
a helpers file `helpers.sh` that can be later included into each script:

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
set -xe
dir="$(dirname $0)"

# Grab our helpers
source "$dir/helpers.sh"

# Parse the argument
vmid=$1
vmname=$(id_to_name $vmid)
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
  - $(cat ~/.ssh/id_rsa.pub)
EOF

cat << EOF > "$vmdir/meta-data"
instance-id: $vmname
local-hostname: $vmname
EOF

# Build the `cloud-init` ISO
mkisofs -output "$vmdir/cidata.iso" -volid cidata -joliet -rock "$vmdir"/{user-data,meta-data}
```

> [!NOTE]
> * `set -e` makes sure that the script fails immediately if any command returns a non-zero exit status
> * `set -x` causes every command to be logged on standard output, making it easier for us to see what's going on
> * `dir="$(dirname $0)"` saves the script's parent directory to a variable - we use it to make the script
>    independent of working directory

Let's give it proper permissions and run it for the `gateway` VM:

```bash
chmod u+x vmsetup.sh
./vmsetup.sh 0
```

For the next couple of sections we'll be using this VM to test everything we add to our setup
(we'll launch a full cluster a bit later).

> [!NOTE]
> Take note of the part that writes `user-data` and `meta-data` files. We will add more configuration
> to these files, so this fragment will be extended multiple times as we progress through this guide.

### Testing the VM

If the setup script succeeds, we can do a test-run of the VM. Before we do that, let's copy the UEFI firmware
into current directory, for convenience:

```bash
qemu_version=$(qemu-system-aarch64 --version | head -n 1 | sed "s/^QEMU emulator version //")
cp "/opt/homebrew/Cellar/qemu/$qemu_version/share/qemu/edk2-aarch64-code.fd" OVMF.fd
```

Let's launch the `gateway` VM:

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

### Setting up network environment

Let's lay out some requirements regarding the network for our VMs. We want all our VMs to:

* live in the same local network
* have stable and predictable IP addresses
* be addressable by their hostnames
* be directly accessible from the host machine (but not necessarily from outside world)
* require as little direct network configuration as possible

#### `dnsmasq`

A running VM needs a DHCP server and a DNS server in its network. Fortunately, Mac OS takes care of that:
when running a VM with `vmnet` based network, it automatically starts its own, built-in implementations
of DHCP & DNS servers. But unfortunately, these servers are not very customizable. While they allow some 
rudimentary configuration, they lack many features that we are going to need, like DHCP options.

That's why we'll use [`dnsmasq`](https://en.wikipedia.org/wiki/Dnsmasq) instead. If you followed
[prerequisites](#prerequisites), you should have it installed already. It will serve us both as a DHCP and
as a DNS server.

Unfortunately, this won't be completely painless. We have to make sure `dnsmasq` does not interfere with
built-in DHCP & DNS servers. Since there is no reliable way to permanently disable them (or I haven't found
one), we're going to resort to a trick. We'll take advantage of the fact that Mac OS starts its built-in servers
**only when a VM is running** and shuts them down when they're no longer needed. 

The trick is to start `dnsmasq` when the built-in servers aren't running. This way `dnsmasq` will bind on
ports 53 (DNS) and 67 (DHCP) and prevent built-in servers from starting, effectively overriding them.

Unfortunately, this solution is fragile because you need to be very careful about when you start/restart `dnsmasq`
and start virtual machines.

> [!WARNING]
> **Make sure `dnsmasq` is running and bound on DNS & DHCP ports when starting a VM**

Also, remember that in the default configuration, `dnsmasq` does not have DHCP server enabled so it won't prevent
the built-in one from starting (we're going to configure it in just a moment).

#### Choosing an IP range

So far, the entire network setup for our VMs consisted of this QEMU option:

```
-nic vmnet-shared
```

and we let everything else to be handled automatically by Mac OS (DHCP, DNS).

Let's gain some more control. First, we set the network address range and mask.
We can do this by adding the following properties to `-nic` option:

```
-nic vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0
```

The host machine will always get the first address from the pool while the rest will get assigned to our VMs.
However, we would like IPs of the VMs to be more predictable, preferably statically
assigned. That's why we configured a very small address range (20 IPs). We can achieve fixed IPs in two ways:
* turning off DHCP client on VMs and configuring them with static IP (via `cloud-init` configs)
* giving VMs static MAC addresses and configuring fixed MAC->IP mapping on the DHCP server.

We'll choose the second option, as it avoids configuring anything directly on VMs.

#### DHCP server configuration

First, let's assign predictable MAC addresses to our VMs. This is as simple as adding another property 
to the `-nic` QEMU option. Assuming that `vmid` shell variable contains VM ID, it would look like this:

```
-nic vmnet-shared,...,mac=52:52:52:00:00:0$vmid
```

In other words, our machines will get MACs in the range `52:52:52:00:00:00` to `52:52:52:00:00:06`.

> [!NOTE]
> This is OK as long as `$vmid` is always a single-digit ID. If you want this to be more bulletproof
> (prepared for more than 10 VMs), you can use something like `$(printf "%02x\n" $vmid)` as the last
> byte of the MAC address.

Now it's time to configure `dnsmasq`'s DHCP server:
* configure a DHCP address range (the same as in QEMU option)
* assign fixed IPs to VM MAC addresses - in order for them to look nice, we choose the range
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

You need to add it into `dnsmasq` configuration file which sits at `/opt/homebrew/etc/dnsmasq.conf`.
Restart it afterwards with:

```
sudo brew services restart dnsmasq
```

#### DNS server configuration

Let's give hostnames to our VMs. In order to do that, first we need to include this line
into `meta-data` config file for `cloud-init`:

```yaml
local-hostname: $vmname
```

> [!INFO]
> Reminder: `meta-data` is filled by the `vmsetup.sh` script, so you need to modify it accordingly

This configures local hostname on every VM. Now we need to make sure that the host machine and VMs 
can refer to each other using hostnames. In other words, we need to configure the DNS server.

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
```

> [!NOTE]
> We have also assigned a domain name (`vmhost`) to the host machine itself.

Finally, let's put all the VMs into a _domain_. Add these lines into `dnsmasq` configuration:

```
domain=kubevms
expand-hosts
```

This tells the DHCP server to include a DHCP option 15 (domain name) into DHCP responses. Without it,
DNS queries for unqualified hosts (e.g. `nslookup worker0`) performed by VMs would not work.
Additionally, `expand-hosts` option allows the DNS server to append domain name to simple names
listed in `/etc/hosts`.

Don't forget to restart `dnsmasq` after modifying its configuration:

```
sudo brew services restart dnsmasq
```

#### Testing the network setup

Let's run the VM to see if all that network setup works:

```
sudo qemu-system-aarch64 \
    -nographic \
    -machine virt,accel=hvf,highmem=on \
    -cpu host \
    -smp 2 \
    -m 2G \
    -bios OVMF.fd \
    -nic vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0,mac=52:52:52:00:00:00 \
    -hda gateway/disk.img \
    -drive file=gateway/cidata.iso,driver=raw,if=virtio
```

Run `ip addr show enp0s1` on the VM to see if it got the right IP:

```
ubuntu@gateway:~$ ip addr show enp0s1
2: enp0s1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP group default qlen 1000
    link/ether 52:52:52:00:00:00 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.10/24 metric 100 brd 192.168.1.255 scope global dynamic enp0s1
       valid_lft 23542sec preferred_lft 23542sec
    inet6 fd33:42e1:ab3f:c1b5:5052:52ff:fe00:0/64 scope global dynamic mngtmpaddr noprefixroute
       valid_lft 2591949sec preferred_lft 604749sec
    inet6 fe80::5052:52ff:fe00:0/64 scope link
       valid_lft forever preferred_lft forever
```

Run `ip route show` to see if the VM got the right default gateway:

```
ubuntu@gateway:~$ ip route show
default via 192.168.1.1 dev enp0s1 proto dhcp src 192.168.1.10 metric 100
192.168.1.0/24 dev enp0s1 proto kernel scope link src 192.168.1.10 metric 100
192.168.1.1 dev enp0s1 proto dhcp scope link src 192.168.1.10 metric 100
```

Finally, let's validate the DNS configuration with `resolvectl status`:

```
ubuntu@gateway:~$ resolvectl status
Global
       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: stub

Link 2 (enp0s1)
    Current Scopes: DNS
         Protocols: +DefaultRoute +LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
Current DNS Server: 192.168.1.1
       DNS Servers: 192.168.1.1 fe80::5ce9:1eff:fe18:5b64%65535
        DNS Domain: kubevms
```

You can also test DNS resolution with `resolvectl query` (or other like `nslookup`, `dig`, etc.)

```
ubuntu@gateway:~$ resolvectl query worker0
worker0: 192.168.1.14                          -- link: enp0s1
         (worker0.kubevms)
```

### Remote SSH access

The network is set up, VMs have nice, stable IP addresses and domain names.
Now we would like to be able to log into them remotely via SSH.

A VM running from cloud image already has an SSH server up and running. 
However, it is configured to reject login-based attempts. We must authenticate using a public key,
which must be preconfigured on the VM.

On your host machine, if you don't already have an SSH key (see if you have an `~/.ssh/id_rsa.pub` 
or a similar file ending with `.pub`), you can generate it using:

```
ssh-keygen
```

This will generate a keypair: a private key (`~/.ssh/id_rsa`) and a public key (`~/.ssh/id_rsa.pub`).
We must now authorize the public key inside the VM by adding it to VM's `~/.ssh/authorized_keys` file.

If you're already running the VM, you can do this manually: just append the contents of your 
`~/.ssh/id_rsa.pub` file to the VM's `~/.ssh/authorized_keys` file (create it if it doesn't exist).

We'll also automate it with `cloud-init`. Add the following entry to `user-data` (in `vmsetup.sh` script):

```yaml
ssh_authorized_keys:
  - $(cat ~/.ssh/id_rsa.pub)
```

> [!WARNING]
> Remember that any changes in `cloud-init` configs require resetting the VM state (reformatting its disk image)
> or changing the `instance-id` in order to take effect.

#### Automating establishment of VM's authenticity

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
see something less pleasant upon SSH connection attempt:

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
##!/usr/bin/env bash
set -xe
dir="$(dirname $0)"

# Grab the helpers
source "$dir/helpers.sh"

# Parse the argument (VM ID)
vmid=$1
vmname=$(id_to_name $vmid)

# Wait until the VM is ready to accept SSH connections
until nc -zG120 $vmname 22; do sleep 1; done

# Acquire an exclusive lock for modifying ~/.ssh/known_hosts
exec 3>~/.ssh/known_hosts.lock && flock 3

# Remove any stale entries for this VM from known_hosts
sed -i.bak "/^$vmname/d" ~/.ssh/known_hosts
rm -f ~/.ssh/known_hosts.bak

# Add new entries for this VM to known_hosts
ssh-keyscan $vmname 2> /dev/null >> ~/.ssh/known_hosts

# Release the lock by closing the file descriptor
exec 3>&-
```

> [!WARNING]
> There are [differences](https://unix.stackexchange.com/questions/13711/differences-between-sed-on-mac-osx-and-other-standard-sed)
> between `sed` implementations for various Unix platforms. The `sed` invocation from this script is for Mac OS and may not
> work on Linux.

Let's break it down:

1. Just like `vmsetup.sh`, `vmsshsetup.sh` takes VM ID as an argument.
2. The script waits until the VM is able to accept SSH connections.
   This is useful if you want to run this script immediately before of after launching the VM.
3. Before making any changes to `known_hosts` file, the script acquires a lock - this way the script
   is safe to run concurrently (which it will).
5. The script removes entries from any previous runs of this VM from the `known_hosts` file.
6. Using `ssh-keyscan`, the script grabs VM's SSH keys and makes them trusted by adding them
   to the `known_hosts` file
7. Lock is released. It would be released anyway after the script finishes, but it's much more clear
   and safe to do this explicitly.

Don't forget to give the script executable permissions and run it with `./vmsshsetup 0` (make sure the VM is running).

Et voilà! You can now SSH into your VM without any trouble.

## Launching the cluster

Let's get to finally launching the whole cluster of VMs.

### Granting resources

So far we have been using 2 virtual CPUs and 2GB of RAM when launching a VM for testing. Let's decide properly how much
resources every VM gets, based on its purpose:

* the `gateway` and `control` VM don't do heavy work so we give them 2 vCPUs and 2GB of RAM
* `worker` nodes need more muscle - let's give them 4 vCPUs and 8GB of RAM

This amounts to a total of 32GB of RAM for all the VMs. If you don't have this much free RAM of your host machine, you can
reduce the amount of RAM given to worker nodes.

### VM launching script

Let's automate launching the VM with a `vmlaunch.sh` script. 
Just like the previous scripts, it takes VM ID as an argument.

```bash
#!/usr/bin/env bash
set -xe
dir="$(dirname $0)"

# Grab the helpers
source "$dir/helpers.sh"

# Parse the argument (VM ID)
vmid=$1
vmname=$(id_to_name $vmid)
vmdir="$dir/$vmname"

# Assign resources
case "$vmname" in
  gateway|control*)
    vcpus=2
    memory=2G
    ;;
  worker*)
    vcpus=4
    memory=8G
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
    -nic vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0,mac=$mac \
    -hda "$vmdir/disk.img" \
    -drive file="$vmdir/cidata.iso",driver=raw,if=virtio
```

Give it appropriate permissions and test it on the `gateway` VM. Don't forget the `sudo`:

```
chmod u+x vmlaunch.sh
sudo ./vmlaunch.sh 0
```

### TMUX

We're about to launch multiple VMs at once, using purely command line tools. In order to make this more
manageable, we'll learn to use [`tmux`](https://github.com/tmux/tmux/wiki).

> tmux is a terminal multiplexer. It lets you switch easily between several programs in one terminal,
> detach them (they keep running in the background) and reattach them to a different terminal.

More specifically, `tmux` will give us the fillowing powers:
* to launch a bunch of shell processes inside a single terminal-based application (inside a _session_)
* to detach a running session from current terminal (make it run fully in background) and reattach it later in any other terminal
* to execute something simultaneously in multiple shells (i.e. on multiple VMs)

This subchapter is intented for people that have never worked with `tmux` (or very little). If you're not one of these
people, feel free to skip it.

#### Basic `tmux` controls

Independent runs of `tmux` are called _sessions_. Sessions can have multiple _windows_ - they behave a bit like tabs.
Finally, a window can have multiple _panes_ - simultaneously visible split-screen shells.

Let's try it out. Start a new session with:

```bash
tmux new -s sesname
```

This creates a session named `sesname` and attaches it to current terminal. You should see something like this:

<img width="532" alt="image" src="https://github.com/ghik/kubenet/assets/1022675/e5fd84cf-9f66-43dc-adbd-0e6c2949f2a7">

A session initially has a single window with a single pane running a new shell.

#### Commands and shortcuts

`tmux` can be contolled with a multitude of commands and configuration options it offers (much like, for example, `vim`).
These commands can be issued internally (from within a session) or externally (from any terminal).

In order to execute a command from within a session, hit `Ctrl`+`b`, then
type a colon (`:`) followed by the command itself. For example, `Ctrl`+`b`, `:new-window` creates a new window.
You can see the new window listed in the status bar:

<img width="532" alt="image" src="https://github.com/ghik/kubenet/assets/1022675/e5e3582b-e6fa-4645-a39c-38dc08e14726">

The asterisk `*` indicates that we automatically switched to the newly created window. One of many ways to switch
between windows is to use `:next-window` and `:previous-window` commands.

Typing commands just to navigate between windows and panes would be very tedious. Not surprisingly, many commands
have a built-in keyboard shortcut. For example, `:next-window` and `:previous-window` command have corresponding
`Ctrl`+`b`,`n` and `Ctrl`+`b`,`p` shortcuts. You can also use `Ctrl`+`b`,<number> to select windows by numbers.

> [!NOTE]
> `Ctrl`+`b` is called the _prefix_ and it precedes every keyboard shortcut.

There are several online resources you can use to explore the vastness of `tmux` capabilities.
For example, [here's a cheatsheet](https://tmuxcheatsheet.com/) with the most essential shortcuts.

#### Working with panes

Let's also see some panes in action. Hit `Ctrl`+`b`,`%` to split the current pane vertically into two panes laid out
side by side.

<img width="532" alt="image" src="https://github.com/ghik/kubenet/assets/1022675/adc7ddd1-1012-4c38-a8e9-e38148138b7e">

Do it multiple times to create more panes. You can then move and resize panes, using plethora of commands and
shortcuts offered by `tmux`. However, chances are you'll be happy with one of common layouts offered by `tmux`.
Hit `Ctrl`+`B`,`spacebar` multiple times to switch between layouts (e.g. all vertical, all horizontal, mixed, etc.).
This is the easiest way to evenly split available space between panes.

Switching between panes can also be done in multiple ways. For example, if you hit `Ctrl`+`b`,`q`, pane numbers will 
be temporarily highlighted. While they are highlighted, hit the desired pane number in order to switch to it.

A very useful shortcut to focus on a particular pane is `Ctrl`+`b`,`z` (zoom), which causes the current pane to 
temporarily enter "fullscreen". The same shortcut is used to toggle the zoom off.

Finally, the command that makes `tmux` stand for its name is `:setw synchronize-panes`. It causes all keystrokes to
be sent to **all panes** in the current window, simultaneously. The same command toggles the synchronization off. 
When panes are synchronized, current panel highlight color changes from green to red:

<img width="532" alt="image" src="https://github.com/ghik/kubenet/assets/1022675/380c3cd1-6f27-4244-81f4-b368c01f3379">

This will be very useful for us - we will be able to configure multiple VMs at once using this feature.

#### Configuration and customization

Not surprisingly, `tmux` can be heavily customized. You can create new commands, change shortcuts, assign new shortcuts, etc.
In order to do this for your current user, create the `~/.tmux.conf` file. It works in the same spirit as "rc" files used by many
essential Unix tools (e.g. `.bashrc`, `.vimrc`, etc.).

For this tutorial, I found it useful to have the following entries in my `~/.tmux.conf`:

```
set -g mouse on
bind C-s setw synchronize-panes
```

The first one makes it possible to switch panes with mouse clicks (just like you switch active windows in a graphical UI).
The second one assigns a keyboard shortcut (`Ctrl`+`b`, `Ctrl`+`s`) to `:setw synchronize-panes` command, which - unfortunately -
does not have a built-in shortcut.

#### Detaching and attaching

A running `tmux` session can be detached from current terminal and brought into background. The shortcut is `Ctrl`+`b`,`d`.
You can then reattach it to any other terminal using the command:

```
tmux attach -t sesname
```

(`sesname` is our session name)

#### Scriptability

As mentioned earlier, `tmux` can be controlled from outside. You can send commands to it from any terminal in your system.
This works even if a `tmux` session is detached, and it allows us to fully automate interactions. For example, we can write
a script that creates a session with 3 windows, splits each into 4 separate panes, and applies a particular layout to them.

Here's an example of a command sent to a running `tmux` session from outside:

```
tmux split-window -v -t sesname
```

### Launching a cluster of VMs in `tmux`

We now know enough about `tmux` to use it for our goal: launch all the VMs and connect to them with SSH.

We'll launch a tmux session and create 4 separate windows:
* a window for launching the VMs with `vmlaunch.sh` (7 panes)
* a window for an SSH connection to the `gateway` VM
* a window for SSH connections to `control` VMs (3 panes)
* a window for SSH connections to `worker` VMs (3 panes)

The reason why we're splitting SSH connections into 3 separate windows is because we're going to do different
things with these three types of VMs. Therefore, we would like to send commands simultaneously to all VMs in
each of these groups. We can achieve that with pane synchronization separately in each window.

#### A script to launch everything

Using `tmux`'s scriptability, we'll automate all of the above with a script, `vmlaunchall.sh`.
Without further ado, here it is:

```bash
#!/usr/bin/env bash
set -xe
dir=$(dirname $0)

# Grab the helpers
source "$dir/helpers.sh"

# The script takes tmux session name as an argument
sname=$1
if [[ -z $sname ]]; then
  echo "usage: $(basename $0) <tmux-session-name>"
  exit 1
fi

# Launch a tmux session (with initial window named `qemu`) and immediately detach from it
tmux new-session -s $sname -n qemu -d

# Split the first window into 7 panes and assign a shell variable `vmid` in each of them
for vmid in $(seq 0 6); do
  tmux send-keys -t "$sname" "vmid=$vmid" C-m
  if [[ $vmid != 6 ]]; then
    tmux split-window -t "$sname" -v
  fi
  tmux select-layout -t "$sname" tiled
done

# Synchronize panes and navigate to script's directory
tmux set-window-option -t "$sname" synchronize-panes on
tmux send-keys -t "$sname" "cd $dir" C-m

# Launch the VMs.
# Note the single quotes. The intention is to use the `vmid` variable that was assigned in each pane.
tmux send-keys -t "$sname" 'sudo ./vmlaunch.sh $vmid' C-m

# A function that prepares a pane for connecting to a VM with SSH, and connects to it.
# Takes VM ID as an argument.
vm_ssh() {
  vmid=$1
  vmname=$(id_to_name $vmid)
  tmux send-keys -t "$sname" "cd $dir" C-m
  tmux send-keys -t "$sname" "vmid=$vmid; vmname=$vmname" C-m
  tmux send-keys -t "$sname" './vmsshsetup.sh $vmid' C-m
  tmux send-keys -t "$sname" 'ssh ubuntu@$vmname' C-m
}

# Create a window for SSH connection to `gateway` and connects to it
tmux new-window -t "$sname" -n ssh-gateway
vm_ssh 0

# Create a window for SSH connections to `control` VMs and connects to them
tmux new-window -t "$sname" -n ssh-controls
for vmid in $(seq 1 3); do
  vm_ssh $vmid
  if [[ $vmid != 3 ]]; then
    tmux split-window -t "$sname" -v
  fi
done
tmux select-layout -t "$sname" even-vertical

# Create a window for SSH connections to `worker` VMs and connects to them
tmux new-window -t "$sname" -n ssh-workers
for vmid in $(seq 4 6); do
  vm_ssh $vmid
  if [[ $vmid != 6 ]]; then
    tmux split-window -t "$sname" -v
  fi
done
tmux select-layout -t "$sname" even-vertical

# Finally, attach the session back to the current terminal and activate the VM launching window
tmux attach -t "${sname}:qemu"
```

Save the script with executable permissions.

#### Liftoff

Make sure all the VMs are prepared for launch:

```bash
for vmid in $(seq 0 6); do ./vmsetup.sh $vmid; done
```

And the moment of thuth has come 🚀:

```bash
./vmlaunchall.sh kubevms
```

The script is set up in a way that, upon launching, you are brought to the first window
(the one with VMs being launched) where panes are synchronized. You are then expected to type in password
(prompt coming from `sudo ./vmlaunch.sh` in each pane).

> [!WARNING]
> Do not run `vmlaunchall.sh` with `sudo`. If you do, SSH connections will be attempted by the `root` user
> and they won't work because we have done all the preparations in current user's `~/.ssh/*` files.

After all the VMs have successfully launched, you should see something like this:

<img width="1721" alt="image" src="https://github.com/ghik/kubenet/assets/1022675/d2f817e5-b5ae-487f-9c1c-5649c00ebc28">

If you switch to other windows, you should see already logged-in SSH shells to your VMs.

And this is it! After much learning and scripting, the cluster is finally running 🎉

## Summary

In this chapter, we have:
* created a script that prepares each VM's image and `cloud-init` configuration
* prepared proper network environment for the cluster on the host machine, including a DHCP and DNS server using `dnsmasq`
* automated everything necessary to connect to our VMs with SSH
* automated launching a single VM with a script
* learned how to use `tmux`
* automated launching the entire cluster in a `tmux` session along with SSH shells to every VM

## Resources

1. [`dnsmasq` manpage](https://manpages.debian.org/bookworm/dnsmasq-base/dnsmasq.8.en.html)
2. [Getting started with `tmux`](https://linuxize.com/post/getting-started-with-tmux/)
3. [Tmux Cheat Sheet & Quick Reference](https://tmuxcheatsheet.com/)
