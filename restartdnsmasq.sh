#!/usr/bin/env bash

# If dnsmasq was restarted while no VM was running, it will not bind to the VM bridge interface
# (because it doesn't exists) and DNS will not work inside VMs when they start.
# The workaround to handle this problem is to temporarily run a dummy VM and restart dnsmasq
# *while the VM is running*.

set -xe

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

case $(uname -s) in
  Linux)
    until systemctl restart dnsmasq; do sleep 1; done
    ;;

  Darwin)
    brew services restart dnsmasq

    if ! lsof -ni4TCP:53 | grep -q '192\.168\.1\.1'; then
      qemu-system-aarch64 \
          -nographic \
          -machine virt \
          -nic vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0 \
          </dev/null >/dev/null 2>&1 &
      qemu_pid=$!

      sleep 1

      # Restart dnsmasq while the bridge interface exists (because a VM is running)
      brew services restart dnsmasq
      until lsof -i4TCP:53 | grep -q vmhost; do sleep 1; done
      kill $qemu_pid
      wait $qemu_pid
    fi
    ;;
esac
