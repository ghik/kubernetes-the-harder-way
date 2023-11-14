\[ [**macOS/ARM64**](../../macos/docs/00_Introduction.md) | **Linux/AMD64** \]

Next: [Learning how to Run VMs with QEMU](01_Learning_How_to_Run_VMs_with_QEMU.md)

# Introduction

This guide describes how to set up a production-like Kubernetes cluster on a local machine.

The purpose is primarily educational: to understand better how Kubernetes works under the hood, what it is made of and how its 
components fit together. For this reason we'll be doing everything _from scratch_, and we'll avoid using any "convenience" 
tools that hide all the interesting details from us. If you're looking for a quick recipe to have a working cluster as fast
as possible, this guide is probably not for you (although you can also take a look at the 
[TLDR version](09_TLDR_Version_of_the_Guide.md)).

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Chapters](#chapters)
- [Credits](#credits)
- [Intended audience](#intended-audience)
- [Prerequisites](#prerequisites)
  - [Prior knowledge](#prior-knowledge)
  - [Hardware and OS](#hardware-and-os)
  - [Software](#software)
- [Scope](#scope)
- [Deployment overview](#deployment-overview)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Chapters

1. [Learning How to Run VMs with QEMU](01_Learning_How_to_Run_VMs_with_QEMU.md)
1. [Preparing Environment for a VM Cluster](02_Preparing_Environment_for_a_VM_Cluster.md)
1. [Launching the VM Cluster](03_Launching_the_VM_Cluster.md)
1. [Bootstrapping Kubernetes Security](04_Bootstrapping_Kubernetes_Security.md)
1. [Installing Kubernetes Control Plane](05_Installing_Kubernetes_Control_Plane.md)
1. [Spinning up Worker Nodes](06_Spinning_up_Worker_Nodes.md)
1. [Installing Essential Cluster Services](07_Installing_Essential_Cluster_Services.md)
1. [Simplifying Network Setup with Cilium](08_Simplifying_Network_Setup_with_Cilium.md) (optional)
1. [TLDR Version of the Guide](09_TLDR_Version_of_the_Guide.md) (auxiliary)

## Credits

This guide is a result of its author's learning process, which was largely facilitated by Kelsey Hightower's
[Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way). This guide is written in a similar spirit, with some of its parts loosely reusing
commands and configurations from the original.

However, compared to the original _Kubernetes the Hard Way_, this guide:

* uses a local environment, as opposed to Google Cloud Platform (which is used at least in the first version of KTHW)
* is lengthier, and contains more "theoretical" knowledge and introductory material for various tools and subjects,
  including outside of Kubernetes itself
* describes a more complete deployment, including a storage provisioner and a service load balancer
* ships with a set of scripts for the "impatient"

## Intended audience

This guide is intended for people which have used Kubernetes to some degree, but want to have a more in-depth
knowledge of its inner workings. This may be beneficial in several ways:
* being able to make better, more informed design decisions for systems running on Kubernetes
* being able to troubleshoot problems with Kubernetes more effectively
* being able to support your own Kubernetes deployment

## Prerequisites

### Prior knowledge

* some working knowledge of Kubernetes, i.e. knowing what a Pod or Service is, having used `kubectl` to
  deploy some simple workloads
* familiarity with fundamental network protocols (IP, ARP, DNS, DHCP, etc.)
* general familiarity with Linux and shell scripting

### Hardware and OS

This version of the guide was prepared and tested on a laptop with Intel Core i7 CPU, running Ubuntu 22.04 (Jammy).
It may be compatible with other Linux distributions, but it assumes usage of the following components:
* `apt` for package management (Ubuntu default repos are assumed)
* `systemd` for system initialization
* `netplan` for network configuration

Since we'll run several VMs at once, a decent amount of RAM is recommended, preferably at
least 32GB.

### Software

Use this script to install all the necessary software for this guide:

```bash
sudo apt install -y apt-transport-https ca-certificates

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

curl https://baltocdn.com/helm/signing.asc | sudo gpg --dearmor -o /usr/share/keyrings/helm.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
  | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
  
sudo apt update
sudo apt install -y \
  qemu-system-x86 curl genisoimage dnsmasq tmux golang-cfssl nfs-kernel-server kubectl helm
```

> [!NOTE]
> If you're seeing an error message indicating that `dnsmasq` could not start, do not worry.
> This is expected at this point, and we'll deal with it properly 
> [when the time comes](02_Preparing_Environment_for_a_VM_Cluster.md#using-dnsmasq).

## Scope

In order to make this guide complete, we won't focus just on Kubernetes. We'll also look at some foundational stuff within
Linux that makes containerization and Kubernetes possible. We'll also spend some time with general-purpose administrative
tools useful for installing and maintaining our deployment.

These include:
* [`qemu`](https://www.qemu.org/) and virtualization in general
* [`cloud-init`](https://canonical-cloud-init.readthedocs-hosted.com/en/latest/)
* [`dnsmasq`](https://en.wikipedia.org/wiki/Dnsmasq)
* [`tmux`](https://github.com/tmux/tmux/wiki)
* [`cfssl`](https://github.com/cloudflare/cfssl)
* [IPVS](https://en.wikipedia.org/wiki/IP_Virtual_Server) (`ipvsadm` and `ldirectord`)
* [`systemd`](https://systemd.io/)
* a bit of [`iptables`](https://en.wikipedia.org/wiki/Iptables)
* basics of Linux containerization: namespaces and cgroups

Apart from Kubernetes core, our deployment will also include the following third party projects:
* [`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
* [MetalLB](https://metallb.universe.tf/)
* [Cilium](https://cilium.io)

## Deployment overview

We'll create a cluster out of seven Linux virtual machines:
* three of them will serve as the Kubernetes [control plane](https://kubernetes.io/docs/concepts/overview/components/#control-plane-components)
* one VM will simulate a cloud/hardware load balancer for the Kubernetes API
* the remaining three VMs will serve as [worker nodes](https://kubernetes.io/docs/concepts/overview/components/#node-components)

The host (macOS) machine will also require some setup:
* it will run the virtual network between the VMs and provide internet access
* it will simulate external mass storage (e.g. a disk array) for Kubernetes, using an NFS-exported directory

Next: [Learning How to Run VMs with QEMU](01_Learning_How_to_Run_VMs_with_QEMU.md)
