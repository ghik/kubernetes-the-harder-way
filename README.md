# Kubernetes the Harder Way

A guide to setting up a production-like Kubernetes cluster on a local machine.

It is written in the spirit, and with inspirations from Kelsey Hightower's [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way), 
and may be considered its lengthier, extended version, optimized for a local deployment.

This repository contains the guide itself, as well as scripts and configuration files that serve as a
reference result of completing the guide. The guide comes in two versions: for **macOS/ARM64** (Apple Silicon)
and for [Linux/AMD64](https://github.com/ghik/kubernetes-the-harder-way/tree/linux#readme) (Ubuntu). 
The scripts work on both platforms (there are no separate versions).

## License

This guide follows the license of the original 
[Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way):
[Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](http://creativecommons.org/licenses/by-nc-sa/4.0/)

## Chapters

\[ **macOS/ARM64** | [Linux/AMD64](https://github.com/ghik/kubernetes-the-harder-way/tree/linux#chapters) \]

0. [Introduction](docs/00_Introduction.md)
1. [Learning How to Run VMs with QEMU](docs/01_Learning_How_to_Run_VMs_with_QEMU.md)
1. [Preparing Environment for a VM Cluster](docs/02_Preparing_Environment_for_a_VM_Cluster.md)
1. [Launching the VM Cluster](docs/03_Launching_the_VM_Cluster.md)
1. [Bootstrapping Kubernetes Security](docs/04_Bootstrapping_Kubernetes_Security.md)
1. [Installing Kubernetes Control Plane](docs/05_Installing_Kubernetes_Control_Plane.md)
1. [Spinning up Worker Nodes](docs/06_Spinning_up_Worker_Nodes.md)
1. [Installing Essential Cluster Services](docs/07_Installing_Essential_Cluster_Services.md)
1. [Simplifying Network Setup with Cilium](docs/08_Simplifying_Network_Setup_with_Cilium.md) (optional)
1. [TLDR Version of the Guide](docs/09_TLDR_Version_of_the_Guide.md) (auxiliary)

