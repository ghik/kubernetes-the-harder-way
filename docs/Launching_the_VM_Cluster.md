# Launching the VM Cluster

The network is configured, and we have all the VM images and configs prepared.
It's time to automate the launch itself.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Prerequisites](#prerequisites)
- [Granting resources](#granting-resources)
- [VM launching script](#vm-launching-script)
- [`tmux` crash course](#tmux-crash-course)
  - [Basic `tmux` controls](#basic-tmux-controls)
  - [Commands and shortcuts](#commands-and-shortcuts)
  - [Working with panes](#working-with-panes)
  - [Configuration and customization](#configuration-and-customization)
  - [Detaching and attaching](#detaching-and-attaching)
  - [Scriptability](#scriptability)
- [Using `tmux` to launch and connect to the cluster](#using-tmux-to-launch-and-connect-to-the-cluster)
  - [A script to launch them all](#a-script-to-launch-them-all)
  - [Connecting with SSH](#connecting-with-ssh)
- [Summary](#summary)
- [Resources](#resources)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Make sure you have the following packages installed:

```bash
brew install wget qemu cdrtools dnsmasq flock tmux
```

## Granting resources

So far we have been using 2 virtual CPUs and 2GB of RAM when launching a VM for testing. Let's properly decide
the amount of resources every VM gets, based on its purpose:
* the `gateway` and `control` VM don't do heavy work, so we give them 2 vCPUs and 2GB of RAM
* `worker` nodes need more muscle - let's give them 4 vCPUs and 4GB of RAM

This amounts to a total of 20GB of RAM for all the VMs. If you have some more to spare, you can increase
the amount of RAM granted to workers.

## VM launching script

Let's automate launching the VM with a `vmlaunch.sh` script. 
Just like the previous scripts, it takes VM ID as an argument.

```bash
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
```

Give it appropriate permissions and test it on the `gateway` VM. Don't forget the `sudo`:

```
chmod u+x vmlaunch.sh
sudo ./vmlaunch.sh 0
```

## `tmux` crash course

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

### Basic `tmux` controls

Independent runs of `tmux` are called _sessions_. Sessions can have multiple _windows_ - they behave a bit like tabs.
Finally, a window can have multiple _panes_ - simultaneously visible split-screen shells.

Let's try it out. Start a new session with:

```bash
tmux new -s sesname
```

This creates a session named `sesname` and attaches it to current terminal. You should see something like this:

<img width="532" alt="image" src="https://github.com/ghik/kubenet/assets/1022675/e5fd84cf-9f66-43dc-adbd-0e6c2949f2a7">

A session initially has a single window with a single pane running a new shell.

### Commands and shortcuts

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

### Working with panes

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

### Configuration and customization

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

### Detaching and attaching

A running `tmux` session can be detached from current terminal and brought into background. The shortcut is `Ctrl`+`b`,`d`.
You can then reattach it to any other terminal using the command:

```
tmux attach -t sesname
```

(`sesname` is our session name)

### Scriptability

As mentioned earlier, `tmux` can be controlled from outside. You can send commands to it from any terminal in your system.
This works even if a `tmux` session is detached, and it allows us to fully automate interactions. For example, we can write
a script that creates a session with 3 windows, splits each into 4 separate panes, and applies a particular layout to them.

Here's an example of a command sent to a running `tmux` session from outside:

```
tmux split-window -v -t sesname
```

## Using `tmux` to launch and connect to the cluster

We now know enough about `tmux` to use it for our goal: launch all the VMs and connect to them with SSH.

We'll launch 2 tmux sessions:
* One to run all the VMs, one machine per pane, in a single window. It will run detached and with elevated
  privileges.
* One for SSH connections to all the VMs. It will have a separate window for each machine type:
  * a window for an SSH connection to the `gateway` VM
  * a window for SSH connections to `control` VMs (3 panes)
  * a window for SSH connections to `worker` VMs (3 panes)

The reason why we're splitting SSH connections into 3 separate windows is because we're going to do different
things with these three types of VMs. Therefore, we would usually send commands simultaneously to all VMs in
each of these groups. We can achieve that with pane synchronization separately in each window.

> [!NOTE]
> We must launch two separate sessions because:
> * launching VMs requires elevated privileges while SSH must be invoked by the current user
> * the VMs (QEMU) should rarely require interaction, so the QEMU session may run in detached mode
>   while the SSH session can be launched independently

Using `tmux`'s scriptability, we'll automate all of the above with shell scripts.

### A script to launch them all

`vmlaunchall.sh` is the script that launches all the VMs in a `tmux` session:

```bash
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
```

Save it with executable permissions. Then make sure all the VMs are prepared for launch:

```bash
for vmid in $(seq 0 6); do ./vmsetup.sh $vmid; done
```

And the moment of truth has come 🚀:

```bash
sudo ./vmlaunchall.sh kubenet-qemu
```

The script leaves the `tmux` session detached by default. If you would like to observe your VMs starting up,
reattach with:

```bash
sudo tmux attach -t kubenet-qemu
```

Ultimately, you should see something like this:

Detach with `Ctrl`+`b`,`d`.

You can kill the session with:

```bash
sudo tmux kill-session -t kubenet-qemu
```

### Connecting with SSH

The second script, `vmsshall.sh`, automates setting up SSH connections to all the VMs:

```bash
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

# A function that prepares a pane for connecting to a VM with SSH, and connects to it.
# Takes VM ID as an argument.
vm_ssh() {
  vmid=$1
  vmname=$(id_to_name "$vmid")
  tmux send-keys -t "$sname" "cd $dir" C-m
  tmux send-keys -t "$sname" "vmid=$vmid; vmname=$vmname" C-m
  tmux send-keys -t "$sname" './vmsshsetup.sh $vmid' C-m
  tmux send-keys -t "$sname" 'ssh ubuntu@$vmname' C-m
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
done
tmux select-layout -t "$sname" even-vertical

# Create a window for SSH connections to `worker` VMs and connects to them
tmux new-window -t "$sname" -n ssh-workers
for vmid in $(seq 4 6); do
  vm_ssh "$vmid"
  if [[ $vmid != 6 ]]; then
    tmux split-window -t "$sname" -v
  fi
done
tmux select-layout -t "$sname" even-vertical

# Finally, attach the session back to the current terminal and activate the second window
tmux attach -t "$sname:ssh-controls"
```

Save it with executable permissions and try it out:

```bash
./vmsshall.sh kubenet-ssh
```

This should bring up a `tmux` session with all the SSH connections already established.

And this is it! After much learning and scripting, the VM cluster is finally running 🎉

## Summary

In this chapter, we have:
* automated launching a single VM with a script
* learned how to use `tmux`
* automated launching the entire cluster in a `tmux` session
* automated connecting to VMs with SSH in a multi-window `tmux` session

## Resources

1. [Getting started with `tmux`](https://linuxize.com/post/getting-started-with-tmux/)
2. [Tmux Cheat Sheet & Quick Reference](https://tmuxcheatsheet.com/)
