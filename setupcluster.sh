#!/usr/bin/env bash

# This script installs all the essential services on an already working Kubernetes cluster
# (i.e. VMs running with all the necessary Kubernetes components on them).
# This script is run on the host machine.

set -xe
dir=$(dirname "$0")

if [[ -n $USE_CILIUM ]]; then
  helm install -n kube-system cilium cilium/cilium \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=kubernetes \
    --set k8sServicePort=6443 \
    --set cgroup.automount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --wait --timeout 15m
fi

helm install -n kube-system coredns coredns/coredns \
  --set service.clusterIP=10.32.0.10 \
  --set replicaCount=2 \
  --wait --timeout 3m

helm install -n kube-system nfs-provisioner nfs-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=192.168.1.1 \
  --set nfs.path="$(realpath "$dir")/nfs-pvs" \
  --set storageClass.defaultClass=true

helm install -n kube-system metallb metallb/metallb \
  --wait --timeout 3m

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lb-pool
  namespace: kube-system
spec:
  addresses:
    - 192.168.1.30-192.168.1.254
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lb-l2adv
  namespace: kube-system
spec:
  ipAddressPools:
    - lb-pool
EOF
