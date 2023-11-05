#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

kubectl config set-cluster kubenet \
  --certificate-authority="$dir/ca.pem" \
  --embed-certs=true \
  --server=https://kubernetes:6443

kubectl config set-credentials admin \
  --client-certificate="$dir/admin.pem" \
  --client-key="$dir/admin-key.pem" \
  --embed-certs=true

kubectl config set-context kubenet \
  --cluster=kubenet \
  --user=admin

kubectl config use-context kubenet
