#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

gencert() {
  name=$1
  cfssl gencert \
    -ca="$dir/ca.pem" \
    -ca-key="$dir/ca-key.pem" \
    -config="$dir/ca-config.json" \
    -profile=kubernetes \
    "$dir/$name-csr.json" | cfssljson -bare $name
}

genkubeconfig() {
  cert=$1
  user=$2
  kubeconfig="$dir/${cert}.kubeconfig"

  kubectl config set-cluster kubenet \
    --certificate-authority="$dir/ca.pem" \
    --embed-certs=true \
    --server=https://kubernetes:6443 \
    --kubeconfig="$kubeconfig"

  kubectl config set-credentials "$user" \
    --client-certificate="$dir/${cert}.pem" \
    --client-key="$dir/${cert}-key.pem" \
    --embed-certs=true \
    --kubeconfig="$kubeconfig"

  kubectl config set-context default \
    --cluster=kubenet \
    --user="$user" \
    --kubeconfig="$kubeconfig"

  kubectl config use-context default \
    --kubeconfig="$kubeconfig"
}

cfssl gencert -initca "$dir/ca-csr.json" | cfssljson -bare ca

for name in kubernetes admin kube-scheduler kube-controller-manager kube-proxy service-account; do
  gencert $name
done

for i in $(seq 0 2); do
  gencert control$i
  gencert worker$i
done

genkubeconfig admin admin
genkubeconfig kube-scheduler system:kube-scheduler
genkubeconfig kube-controller-manager system:kube-controller-manager
genkubeconfig kube-proxy system:kube-proxy

for i in $(seq 0 2); do
  genkubeconfig control$i system:node:control$i
  genkubeconfig worker$i system:node:worker$i
done
