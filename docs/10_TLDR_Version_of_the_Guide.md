# TLDR Version of the Guide

This chapter is a "TLDR" version of this guide that contains pure instructions for setting up the Kubernetes
deployment. Explanations and "theoretical introductions" are omitted. Most of the work is contained within
scripts shipped with this repository.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Install necessary software](#install-necessary-software)
- [Clone the repository](#clone-the-repository)
- [Prepare VM environment](#prepare-vm-environment)
- [Launch and connect the VMs](#launch-and-connect-the-vms)
- [Bootstrap security](#bootstrap-security)
- [Install the control plane](#install-the-control-plane)
- [Register Kubernetes nodes](#register-kubernetes-nodes)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Install necessary software

```bash
brew install qemu wget curl cdrtools dnsmasq flock tmux cfssl kubernetes-cli helm
```

## Clone the repository

```bash
git clone https://github.com/ghik/kubenet
cd kubenet
```

## Prepare VM environment

Download the base image:

```bash
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img
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

Launch the VMs (in a separate terminal):

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

Upload security files to VMs:

```bash
./deployauth.sh
```

Configure `kubeconfig` on the host machine:

```bash
./setuplocalkubeconfig.sh
```

Go back to `kubenet` directory:

```bash
cd ..
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

## Register Kubernetes nodes

Go to `ssh-nodes` window of the `kubenet-ssh` TMUX session and enable pane synchronization.

Run on all `control` and `worker` nodes:

```bash
sudo ./setupnode.sh
```

Or, if you want to use Cilium:

```bash
sudo USE_CILIUM=true ./setupnode.sh
```

