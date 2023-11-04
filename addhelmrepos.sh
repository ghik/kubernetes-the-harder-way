#!/usr/bin/env bash

set -x

helm repo add --force-update cilium https://helm.cilium.io/
helm repo add --force-update coredns https://coredns.github.io/helm/
helm repo add --force-update nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo add --force-update metallb https://metallb.github.io/metallb/
helm repo update
