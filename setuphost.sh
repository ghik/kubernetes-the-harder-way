#!/usr/bin/env bash

# This script configures various things on the host machine, necessary before VMs
# can be run (DNS, DHCP, NFS).

set -xe
dir=$(dirname "$0")
source "$dir/helpers.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

# Manually set up bridge interface with NAT on Linux

if [[ $(uname -s) == Linux ]]; then
cat <<EOF | tee /etc/netplan/99-kubenet.yaml
network:
  version: 2
  bridges:
    kubr0:
      addresses: [192.168.1.1/24]
EOF
chmod 600 /etc/netplan/99-kubenet.yaml
netplan apply

cat <<EOF | tee /etc/sysctl.d/50-ip-forward.conf
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/50-ip-forward.conf

cat <<EOF | tee /usr/local/bin/kubenet-nat.sh
#!/usr/bin/env sh

# Remove any previously added rules to keep the script idempotent
if iptables -t nat -L KUBENET_NAT > /dev/null 2>&1; then
  iptables -t nat -D POSTROUTING -j KUBENET_NAT
  iptables -t nat -F KUBENET_NAT
  iptables -t nat -X KUBENET_NAT
fi

iptables -t nat -N KUBENET_NAT
iptables -t nat -A POSTROUTING -j KUBENET_NAT
iptables -t nat -A KUBENET_NAT ! -o kubr0 -s 192.168.1.0/24 -j MASQUERADE
EOF
chmod +x /usr/local/bin/kubenet-nat.sh

cat <<EOF | tee /etc/systemd/system/kubenet-nat.service
[Unit]
Description=Kubenet VM network NAT rules
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kubenet-nat.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kubenet-nat
systemctl start kubenet-nat
fi

# DNS entries

sedi '/#setuphost_generated_start/,/#setuphost_generated_end/d' /etc/hosts
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

os=$(uname -s)
case "$os" in
  Darwin) dnsmasq_config="/opt/homebrew/etc/dnsmasq.conf";;
  Linux) dnsmasq_config="/etc/dnsmasq.conf";;
esac

sedi '/#setuphost_generated_start/,/#setuphost_generated_end/d' "$dnsmasq_config"

cat <<EOF | tee -a "$dnsmasq_config"
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
EOF

if [[ "$os" == Linux ]]; then
cat <<EOF | tee -a "$dnsmasq_config"
interface=kubr0
bind-interfaces
EOF
fi

cat <<EOF | tee -a "$dnsmasq_config"
#setuphost_generated_end
EOF

"$dir/restartdnsmasq.sh"

# NFS

case $(uname -s) in
  Darwin)
    user=$(stat -f '%Su' "$dir")
    group=$(stat -f '%Sg' "$dir")
    export="$(realpath "$dir")/nfs-pvs -network 192.168.1.0 -mask 255.255.255.0 -maproot=$user -alldirs"
    ;;
  Linux)
    uid=$(stat -c '%u' "$dir")
    gid=$(stat -c '%g' "$dir")
    user=$(stat -c '%U' "$dir")
    group=$(stat -c '%G' "$dir")
    export="$(realpath "$dir")/nfs-pvs 192.168.1.0/24(rw,root_squash,anonuid=$uid,anongid=$gid,no_subtree_check)"
    ;;
esac

mkdir -p "$dir/nfs-pvs"
chown "$user:$group" "$dir/nfs-pvs"

sedi '/#setuphost_generated_start/,/#setuphost_generated_end/d' /etc/exports
cat <<EOF | sudo tee -a /etc/exports
#setuphost_generated_start
$export
#setuphost_generated_end
EOF

case $(uname -s) in
  Darwin)
    nfsd enable
    nfsd restart
    ;;
  Linux)
    exportfs -a
    ;;
esac
