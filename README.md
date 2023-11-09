# Kubernetes the Harder Way

A guide to setting up a production-like Kubernetes cluster on a local machine 
(currently targeting macOS and Apple Silicon).

It is written in the spirit, and with inspirations from Kelsey Hightower's [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way), 
and can be treated as its lengthier, extended version, optimized for a local deployment.

This repository contains the guide itself, as well as some auxiliary scripts and
configuration files, referred throughout the guide's text.

## License

This guide follows the license of the original 
[Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way):
[Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License](http://creativecommons.org/licenses/by-nc-sa/4.0/)

## Chapters

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

## Guidelines for porting the guide to Linux/x86_64

Adapting this guide to the x86_64 CPU architecture should be fairly easy and includes:
* changing the QEMU command from `qemu-system-aarch64` to `qemu-system-x86_64`
* changing the OVMF (UEFI) binary from `edk2-aarch64-code.fd` to `edk2-x86_64-code.fd`
* changing the architecture of Ubuntu images from `arm64` to `amd64`
* changing the architecture of Kubernetes, container runtime & CNI binaries from `arm64` to `amd64`

Porting the guide to Linux would require some more work:
* Different network interface for QEMU VMs, in place of `vmnet-shared` \
  This would likely require some manual network configuration on the host machine (e.g. setting up a bridge, a `tap` 
  device and NAT), but ultimately should result in a simpler and more robust configuration, as Linux is more flexible 
  in this regard than macOS (e.g. no problems with the [ephemeral nature](docs/02_Preparing_Environment_for_a_VM_Cluster.md#restarting-dnsmasq) 
  of bridge interfaces created by `vmnet`)
* Linux-specific package manager (e.g. `apt`, `yum`) in place of `homebrew`
* Linux-specific command (e.g. `systemctl`) for restarting services in place of `brew services` and `nfsd`
* running VMs (using QEMU) with `accel=kvm` instead of `accel=hvf`
* different tool for formatting ISO images, in place of `mkisofs`
* different location of `dnsmasq` configuration file
* different command for configuring routing on the host machine
* minor differences in some commands, e.g. `sed`

Out of these changes, only the setup of VM network interface seems to be potentially not trivial to port
(but not necessarily hard).
