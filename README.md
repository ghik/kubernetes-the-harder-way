# Kubernetes the Harder Way

A guide to setting up a production-like Kubernetes cluster on a local machine 
(currently written for macOS & Apple Silicon).

It is written in the spirit, and with inspirations from Kelsey Hightower's [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way), 
and can be treated as its lengthier, extended version, optimized for a local deployment.

This repository contains the guide itself, as well as scripts and configuration files that serve as a
reference result of completing the guide. While the guide is written for macOS/ARM64 (Apple Silicon), the scripts
are multi-platform and have been tested on macOS/ARM64 and Ubuntu/AMD64.

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

Adapting this guide to the x86_64 CPU architecture requires minor changes:
* changing the QEMU command from `qemu-system-aarch64` to `qemu-system-x86_64`
* changing the OVMF (UEFI) binary from `edk2-aarch64-code.fd` to `edk2-x86_64-code.fd`
* changing the architecture of Ubuntu images from `arm64` to `amd64`
* changing the architecture of Kubernetes, container runtime & CNI binaries from `arm64` to `amd64`

Porting the guide to Linux would require some more work:
* Solving the problem of [QEMU serial console not displaying the login prompt](https://unix.stackexchange.com/questions/761426/no-login-prompt-in-qemu-serial-console)
* Using different QEMU machine type and hypervisor, i.e. `q35,accel=kvm` instead of `virt,accel=hvf`
* Using different network interface for QEMU VMs, i.e. `tap` backend instead of `vmnet-shared`
* Using Linux-specific package manager (e.g. `apt`, `yum`) in place of `homebrew`
* Using Linux-specific commands (e.g. `systemctl`) for restarting services in place of `brew services` and `nfsd`
* Different command for configuring routing on the host machine (`ip route` in place of `route`)
* Minor differences in some commands, e.g. `sed`, `nc`
* Minor differences in some paths, e.g. `dnsmasq` configuration file

All of these changes have already been included into reference scripts and tested on Ubuntu/AMD64.
While it is fine for scripts to be multi-platform, the text of the guide would become extremely unwieldy if it
tried to cover more than one platform. Therefore, a completely separate version is necessary for Linux.
