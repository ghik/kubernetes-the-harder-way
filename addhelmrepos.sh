#!/usr/bin/env bash

set -x

helm repo add cilium https://helm.cilium.io/
helm repo add coredns https://coredns.github.io/helm/
helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo add metallb https://metallb.github.io/metallb/
