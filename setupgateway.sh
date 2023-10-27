#!/usr/bin/env bash

set -xe
sudo -v

cat <<EOF | sudo tee /etc/ha.d/ldirectord.cf
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

sudo systemctl restart ldirectord
