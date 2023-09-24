# Introduction

In this tutorial, I will show you how to set up a production-like Kubernetes cluster on a Mac.

The purpose is primarily educational, i.e. to understand better how Kubernetes works under the hood, what it's made of and how its 
different components fit together. For this reason we'll be doing everything from scratch and we'll avoid using any "convenience" 
tools that hide all the interesting details from us.

In order to make this guide complete, we won't focus just on Kubernetes. We'll also look at some foundations within
Linux that make containerization and Kubernetes possible. We'll also spent some time on system tools that happen to be
useful or necessary for installing and maintaining our deployment.

## Credits

This guide is a result of my own learning process. It would not be possible without Kelsey Hightower's 
great [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) guide. Some parts of this tutorial
are largely based on it.

However, as compared to _Kubernetes the Hard Way_, this guide:

* describes how to create a deployment on a local machine as opposed to Google Cloud Platform
* is more up-to-date with tools and components being used
* describes a more complete deployment, including storage and load balancer
* tries to explain in more detail what's going on

## Deployment overview

Kubernetes is a distributed system, so we'll need to simulate a multi-machine environment using a set of virtual machines.
Since containerization and Kubernetes runs almost exclusively on Linux in the real world and is havily optimized for 
Linux environments, we will use Linux VMs.

We will set up a total of seven virtual machines:
* three of them will serve as the Kubernetes [control plane](https://kubernetes.io/docs/concepts/overview/components/#control-plane-components)
* one VM will be dedicated to simulate a cloud/hardware load balancer for the Kubernetes API
* the remaining three VMs will serve as worker nodes

## Hardware used

The hardware that I use is an Apple M2 machine running macOS Ventura. This means that some of the commands and tools used by me will be specific 
to the Apple Silicon CPU architecture (also known as AArch64 or ARM64). In principle however, everything I do here should be
easily portable to Intel/AMD.

Since we'll run several VMs at once, a decent amount of RAM is recommended. My machine has 64GB but 32GB should also be sufficient.
