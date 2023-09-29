# Introduction

In this tutorial, I will show you how to set up a production-like Kubernetes cluster on a laptop.

The purpose is primarily educational: to understand better how Kubernetes works under the hood, what it is made of and how its 
components fit together. For this reason we'll be doing everything _from scratch_ and we'll avoid using any "convenience" 
tools that hide all the interesting details from us. If you're looking for a quick recipe to have a working cluster as fast
as possible, this guide is probably not for you.

In order to make this guide complete, we won't focus just on Kubernetes. We'll also look at some foundational stuff within
Linux that makes containerization and Kubernetes possible. We'll also spend some time with some general-purpose system tools 
that happen to be useful for installing and maintaining our deployment.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Credits](#credits)
- [Deployment overview](#deployment-overview)
- [Hardware used](#hardware-used)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Credits

This guide is a result of my own learning process. It would not be possible without Kelsey Hightower's 
great [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) guide. Some parts of this tutorial
are largely based on it.

However, as compared to _Kubernetes the Hard Way_, this guide:

* describes how to create a deployment on a local machine as opposed to Google Cloud Platform
* is more up-to-date with tools and components being used
* describes a more complete deployment, including storage and load balancer
* tries to explain in more detail what's going on

I've also used other sources which I will properly link throughout this guide.

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

The hardware that I use is a MacBook Pro M2 Max machine running macOS Ventura. This means that some of the commands and tools used by me will be specific 
to the Apple Silicon CPU architecture (also known as AArch64 or ARM64). In principle however, everything I do here should be portable to Intel/AMD.

Since we'll run several VMs at once, a decent amount of RAM is recommended. My machine has 64GB but 32GB should also be sufficient.

Next: [Launching VMs with QEMU](Launching_VMs_with_QEMU.md)
