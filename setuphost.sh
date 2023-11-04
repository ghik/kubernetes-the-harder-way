#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

# DNS entries

sed -i '' '/#setuphost_generated_start/,/#setuphost_generated_end/d' /etc/hosts
cat <<EOF | tee -a /etc/hosts
#setuphost_generated_start
192.168.1.1   vmhost
192.168.1.10  gateway
192.168.1.11  control0
192.168.1.12  control1
192.168.1.13  control2
192.168.1.14  worker0
192.168.1.15  worker1
192.168.1.16  worker2
192.168.1.21  kubernetes
#setuphost_generated_end
EOF

# dnsmasq config (DHCP & DNS)

sed -i '' '/#setuphost_generated_start/,/#setuphost_generated_end/d' /opt/homebrew/etc/dnsmasq.conf
cat <<EOF | tee -a /opt/homebrew/etc/dnsmasq.conf
#setuphost_generated_start
dhcp-range=192.168.1.2,192.168.1.20,12h
dhcp-host=52:52:52:00:00:00,192.168.1.10
dhcp-host=52:52:52:00:00:01,192.168.1.11
dhcp-host=52:52:52:00:00:02,192.168.1.12
dhcp-host=52:52:52:00:00:03,192.168.1.13
dhcp-host=52:52:52:00:00:04,192.168.1.14
dhcp-host=52:52:52:00:00:05,192.168.1.15
dhcp-host=52:52:52:00:00:06,192.168.1.16
dhcp-authoritative
domain=kubenet
expand-hosts
#setuphost_generated_end
EOF

brew services restart dnsmasq

# If dnsmasq was restarted while no VM was running, it will not bind to the VM bridge interface
# (because it doesn't exists) and DNS will not work inside VMs when they start.
# The workaround to handle this problem is to temporarily run a dummy VM and restart dnsmasq *while it is running*.
if ! lsof -i4TCP:53 | grep -q vmhost; then
  qemu-system-aarch64 \
      -nographic \
      -machine virt \
      -nic vmnet-shared,start-address=192.168.1.1,end-address=192.168.1.20,subnet-mask=255.255.255.0 \
      </dev/null >/dev/null 2>&1 &
  qemu_pid=$!

  sleep 1

  # Restart dnsmasq while the bridge interface exists (because a VM is running)
  brew services restart dnsmasq

  while ! lsof -i4TCP:53 | grep -q vmhost; do sleep 1; done

  kill $qemu_pid
fi

# Pod CIDR routes

if [[ -z $USE_CILIUM ]]; then
  for vmid in $(seq 1 6); do
    route -n add -net 10.${vmid}.0.0/16 192.168.1.$((10 + $vmid))
  done
fi

# NFS

user=$(stat -f '%Su' "$dir")
group=$(stat -f '%Sg' "$dir")

mkdir -p "$dir/nfs-pvs"
chown "$user:$group" "$dir/nfs-pvs"

sed -i '' '/#setuphost_generated_start/,/#setuphost_generated_end/d' /etc/exports
cat <<EOF | sudo tee -a /etc/exports
#setuphost_generated_start
$(realpath "$dir/nfs-pvs") -network 192.168.1.0 -mask 255.255.255.0 -maproot=$user -alldirs
#setuphost_generated_end
EOF

nfsd enable
nfsd restart
