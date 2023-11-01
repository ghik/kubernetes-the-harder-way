#!/usr/bin/env bash

set -xe

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  return 1
fi

cat <<EOF | tee /etc/ha.d/ldirectord.cf
checktimeout=5
checkinterval=1
autoreload=yes
quiescent=yes

virtual=192.168.1.21:6443
    servicename=kubernetes
    real=192.168.1.11:6443 gate
    real=192.168.1.12:6443 gate
    real=192.168.1.13:6443 gate
    scheduler=wrr
    checktype=negotiate
    service=https
    request="healthz"
    receive="ok"
EOF

systemctl restart ldirectord
