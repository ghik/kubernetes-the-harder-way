\[ **macOS/ARM64** | [Linux/AMD64](../../linux/docs/09_TLDR_Version_of_the_Guide.md) \]

# TLDR Version of the Guide

This chapter is a "TLDR" version of this guide that contains pure instructions for setting up the Kubernetes
deployment. Explanations and "theoretical introductions" are omitted. Most of the work is contained within
scripts shipped with this repository.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Install necessary software](#install-necessary-software)
- [Clone the repository](#clone-the-repository)
- [Bootstrap security](#bootstrap-security)
- [Prepare VM environment](#prepare-vm-environment)
- [Launch and connect the VMs](#launch-and-connect-the-vms)
- [Install the control plane](#install-the-control-plane)
- [Set up Kubernetes nodes](#set-up-kubernetes-nodes)
- [Install essential cluster services](#install-essential-cluster-services)
- [One script to run them all](#one-script-to-run-them-all)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Install necessary software

```bash
brew install qemu wget curl cdrtools dnsmasq tmux cfssl kubernetes-cli helm
```

## Clone the repository

```bash
git clone https://github.com/ghik/kubernetes-the-harder-way
cd kubernetes-the-harder-way
```

## Bootstrap security

Go to `auth` directory:

```bash
cd auth
```

Generate certificates, kubeconfigs, and an encryption key:

```bash
./genauth.sh
./genenckey.sh
```

Configure `kubeconfig` on the host machine:

```bash
./setuplocalkubeconfig.sh
```

Go back to parent directory:

```bash
cd ..
```

## Prepare VM environment

Download the base image:

```bash
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img
```

Make sure you have an SSH public key (`~/.ssh/id_rsa.pub`). If not, generate with:

```bash
ssh-keygen
```

Set up VM images and configs:

```bash
./vmsetupall.sh
```

Set up host network (DHCP, DNS, NFS):

```bash
sudo ./setuphost.sh
```

Or, if you're planning to use Cilium:

```bash
sudo USE_CILIUM=true ./setuphost.sh
```

## Launch and connect the VMs

It is recommended to have the following settings in `~/.tmux.conf`:

```
set -g mouse on
bind C-s setw synchronize-panes
```

Launch the VMs (in a detached `tmux` session):

```bash
sudo ./vmlaunchall.sh kubenet-qemu
```

Connect to VMs with SSH (in a separate terminal)

```bash
./vmsshall.sh kubenet-ssh
```

Upload VM setup scripts:

```bash
./deploysetup.sh
```

Upload security files to VMs:

```bash
./auth/deployauth.sh
```

Optionally, if you don't want to waste bandwidth by downloading the same binaries on every VM,
download them once and upload to each VM:

```bash
./deploybinaries.sh
```

## Install the control plane

Go to `ssh-controls` window of the `kubenet-ssh` TMUX session.
Enable pane synchronization (`Ctrl`+`b`,`:setw synchronize-panes on` or use shortcut if you have one configured).

Run on all `control` nodes:

```bash
sudo ./setupcontrol.sh
```

Go to `ssh-gateway` TMUX window and run:

```bash
sudo ./setupgateway.sh
```

## Set up Kubernetes nodes

Go to `ssh-nodes` window of the `kubenet-ssh` TMUX session and enable pane synchronization.

Run on all `control` and `worker` nodes:

```bash
sudo ./setupnode.sh
```

Or, if you want to use Cilium:

```bash
sudo USE_CILIUM=true ./setupnode.sh
```

If you *do not* use Cilium, configure pod CIDR routes on the host machine:

```bash
sudo ./setuproutes.sh
```

> [!IMPORTANT]
> Routes must be added while at least one VM is running, so that the bridge interface exists.
> Unfortunately, they will be removed once you shut down all the VMs.

Give `kube-apiserver` permissions to call `kubelet`. On the host machine, invoke:

```bash
./setupkubeletaccess.sh
```

## Install essential cluster services

On the host machine, add necessary helm repositories:

```bash
./addhelmrepos.sh
```

Then, to install all essential services:

```bash
./setupcluster.sh
```

Or, if you want to use Cilium:

```bash
USE_CILIUM=true ./setupcluster.sh
```

## One script to run them all

All of the above steps have been additionally automated with a single [`setupall.sh`](../setupall.sh) script.
Invoke it as `./setupall.sh` or `USE_CILIUM=true ./setupall.sh`.
