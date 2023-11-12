#!/usr/bin/env sh

# A script that sets up a tap interface for a VM.
# Passed as the `-nic tap,script=...` option to QEMU on Linux.
# It assumes that a bridge named `kubr0` is already configured.

ifname="$1"
ip link set "$ifname" master kubr0
ip link set "$ifname" up
