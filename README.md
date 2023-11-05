# Kubernetes the Harder Way

A guide to setting up a production-like Kubernetes cluster on a local machine 
(optimized for macOS and Apple Silicon).

[**THE GUIDE**](docs/00_Introduction.md)

It is written in the spirit, and with inspirations from Kelsey Hightower's [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way), 
and can be treated as its lengthier, extended version, optimized for a local deployment.

This repository contains the guide itself, as well as some auxiliary scripts and
configuration files, referred throughout the guide's text.

## Guidelines for porting the guide to Linux/x86_64

Adapting this guide to the x86_64 CPU architecture should be fairly easy and includes:
* changing the QEMU command from `qemu-system-aarch64` to `qemu-system-x86_64`
* changing the OVMF (UEFI) binary from `edk2-aarch64-code.fd` to `edk2-x86_64-code.fd`
* changing the architecture of Ubuntu images from `arm64` to `amd64`
* changing the architecture of Kubernetes, container runtime & CNI binaries from `arm64` to `amd64`

Porting the guide to Linux would require some more work:
* Linux-specific package manager (e.g. `apt`, `yum`) in place of `homebrew`
* Linux-specific command (e.g. `systemctl`) for restarting services in place of `brew services` and `nfsd`
* running VMs (using QEMU) with `accel=kvm` instead of `accel=hvf`
* different network interface for QEMU VMs, in place of `vmnet-shared` - this would likely require some
  manual network configuration on the host machine (e.g. setting up a bridge, a `tap` device and NAT),
  but ultimately should be simpler (e.g. no problems with the [ephemeral nature](02_Preparing_Environment_for_a_VM_Cluster.md#restarting-dnsmasq) of bridge interfaces
  created by `vmnet`)
* different tool for formatting ISO images, in place of `mkisofs`
* different location of `dnsmasq` configuration file
* different command for configuring routing on the host machine
* minor differences in some commands, e.g. `sed`

Out of these changes, only the VM network interface setup seems to be potentially not trivial to port.
