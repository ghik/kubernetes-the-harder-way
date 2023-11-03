# Introduction

This guide describes how to set up a production-like Kubernetes cluster on a laptop.

The purpose is primarily educational: to understand better how Kubernetes works under the hood, what it is made of and how its 
components fit together. For this reason we'll be doing everything _from scratch_, and we'll avoid using any "convenience" 
tools that hide all the interesting details from us. If you're looking for a quick recipe to have a working cluster as fast
as possible, this guide is probably not for you (although you can also take a look at the 
[TLDR version](10_TLDR_Version_of_the_Guide.md)).

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Scope](#scope)
- [Credits](#credits)
- [Who is this guide intended for?](#who-is-this-guide-intended-for)
- [Deployment overview](#deployment-overview)
- [Hardware used](#hardware-used)
- [Chapter list](#chapter-list)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Scope

In order to make this guide complete, we won't focus just on Kubernetes. We'll also look at some foundational stuff within
Linux that makes containerization and Kubernetes possible. We'll also spend some time with some general-purpose system tools 
that happen to be useful for installing and maintaining our deployment.

In particular, these are the tools and subjects, apart from Kubernetes itself, that we'll learn to some degree:
* [`qemu`](https://www.qemu.org/) and virtualization in general
* [`cloud-init`](https://canonical-cloud-init.readthedocs-hosted.com/en/latest/)
* [`dnsmasq`](https://en.wikipedia.org/wiki/Dnsmasq)
* [`tmux`](https://github.com/tmux/tmux/wiki)
* [`cfssl`](https://github.com/cloudflare/cfssl)
* [IPVS](https://en.wikipedia.org/wiki/IP_Virtual_Server) (`ipvsadm` and `ldirectord`)
* basics of Linux containerization: namespaces and cgroups
* a bit of `iptables`

Apart from Kubernetes core, our deployment will also include the following third party projects:
* [`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
* [MetalLB](https://metallb.universe.tf/)
* [Cilium](https://cilium.io)

## Credits

This guide is a result of its author's learning process, which was largely facilitated by Kelsey Hightower's 
[Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) tutorial. Some parts of this guide are based on it.

However, compared to the original _Kubernetes the Hard Way_, this guide:

* uses local environment (a laptop), as opposed to Google Cloud Platform (at least in the first version of KTHW)
* describes in detail how to set up local environment and automate running VMs
* describes a more complete deployment, including storage and load balancer
* tries to explain in more detail what's going on

I've also used other sources which I will properly link throughout this guide.

## Who is this guide intended for?

This guide was created by a software engineer, i.e. not a platform/DevOps engineer with extensive OS 
administration skills. It provides a good amount of "under the hood" knowledge that goes beyond what a regular
Kubernetes user would see. However, the prerequisites for completing this guide are not extensive:

* Some working knowledge of Kubernetes, i.e. knowing what a Pod or Service is, having used `kubectl` to
  deploy some simple workloads
* General understanding of fundamental network protocols (IP, ARP, DNS, DHCP, etc.)
* General familiarity with Linux and shell scripting

As already hinted, this guide is meant for _learning by doing_, but the goal is learning and building understanding,
rather than just having something that works.

## Deployment overview

Kubernetes is a distributed system, so we'll need to simulate a multi-machine environment using a set of virtual machines.
Since containerization and Kubernetes runs almost exclusively on Linux in the real world and is heavily optimized for 
Linux environments, we will use Linux VMs.

We will set up a total of seven virtual machines:
* three of them will serve as the Kubernetes [control plane](https://kubernetes.io/docs/concepts/overview/components/#control-plane-components)
* one VM will be dedicated to simulate a cloud/hardware load balancer for the Kubernetes API
* the remaining three VMs will serve as [worker nodes](https://kubernetes.io/docs/concepts/overview/components/#node-components)

The host (macOS) machine will also play some important roles:
* it will run the virtual network between the VMs and provide internet access
* it will simulate external mass storage (e.g. a disk array) for Kubernetes, using an NFS-exported directory

## Hardware used

The hardware that I use is a MacBook Pro M2 Max machine running macOS Ventura. This means that some of the commands 
and tools used by me will be specific to the Apple Silicon CPU architecture (also known as AArch64 or ARM64). 
In principle however, everything I do here should be portable to Intel/AMD.

Since we'll run several VMs at once, a decent amount of RAM is recommended. My machine has 64GB but 32GB should 
also be sufficient.

## Chapter list

1. [Learning How to Run VMs with QEMU](02_Learning_How_to_Run_VMs_with_QEMU.md)
1. [Preparing Environment for a VM Cluster](03_Preparing_Environment_for_a_VM_Cluster.md)
1. [Launching the VM Cluster](04_Launching_the_VM_Cluster.md)
1. [Bootstrapping Kubernetes Security](05_Bootstrapping_Kubernetes_Security.md)
1. [Installing Kubernetes Control Plane](06_Installing_Kubernetes_Control_Plane.md)
1. [Spinning up Worker Nodes](07_Spinning_up_Worker_Nodes.md)
1. [Installing Essential Cluster Services](08_Installing_Essential_Cluster_Services.md)
1. [Simplifying Network Setup with Cilium](09_Simplifying_Network_Setup_with_Cilium.md) (optional)
1. [TLDR Version of the Guide](10_TLDR_Version_of_the_Guide.md) (auxiliary)

Next: [Learning How to Run VMs with QEMU](02_Learning_How_to_Run_VMs_with_QEMU.md)
