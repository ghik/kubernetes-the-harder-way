#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

for i in $(seq 0 2); do
  vmname=control$i
  scp \
      "$dir/ca.pem" \
      "$dir/ca-key.pem" \
      "$dir/kubernetes-key.pem" \
      "$dir/kubernetes.pem" \
      "$dir/service-account-key.pem" \
      "$dir/service-account.pem" \
      "$dir/admin.kubeconfig" \
      "$dir/kube-controller-manager.kubeconfig" \
      "$dir/kube-scheduler.kubeconfig" \
      "$dir/encryption-config.yaml" \
      "$dir/$vmname.pem" \
      "$dir/$vmname-key.pem" \
      "$dir/$vmname.kubeconfig" \
      "$dir/kube-proxy.kubeconfig" \
      ubuntu@$vmname:~
done

for i in $(seq 0 2); do
  vmname=worker$i
  scp \
      "$dir/ca.pem" \
      "$dir/$vmname.pem" \
      "$dir/$vmname-key.pem" \
      "$dir/$vmname.kubeconfig" \
      "$dir/kube-proxy.kubeconfig" \
      ubuntu@$vmname:~
done

scp "$dir/ca.pem" ubuntu@gateway:~
