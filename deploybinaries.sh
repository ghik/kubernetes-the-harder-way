#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

source "$dir/variables.sh"

etcd_archive=etcd-v${etcd_version}-linux-${arch}.tar.gz
crictl_archive=crictl-v${cri_version}-linux-${arch}.tar.gz
containerd_archive=containerd-${containerd_version}-linux-${arch}.tar.gz
cni_plugins_archive=cni-plugins-linux-${arch}-v${cni_plugins_version}.tgz

mkdir -p "$dir/bin"
wget -P "$dir/bin" -q --show-progress --https-only --timestamping \
  https://github.com/etcd-io/etcd/releases/download/v${etcd_version}/$etcd_archive \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-apiserver \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-controller-manager \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-scheduler \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v${cri_version}/${crictl_archive} \
  https://github.com/opencontainers/runc/releases/download/v${runc_version}/runc.${arch} \
  https://github.com/containerd/containerd/releases/download/v${containerd_version}/${containerd_archive} \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kubelet

if [[ -z $USE_CILIUM ]]; then
  wget -P "$dir/bin" -q --show-progress --https-only --timestamping \
    https://github.com/containernetworking/plugins/releases/download/v${cni_plugins_version}/${cni_plugins_archive} \
    https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-proxy
fi

for i in $(seq 0 2); do
  scp \
    "$dir/bin/$etcd_archive" \
    "$dir/bin/kube-apiserver" \
    "$dir/bin/kube-controller-manager" \
    "$dir/bin/kube-scheduler" \
    "$dir/bin/$crictl_archive" \
    "$dir/bin/runc.$arch" \
    "$dir/bin/$containerd_archive" \
    "$dir/bin/kubelet" \
    ubuntu@control$i:

  if [[ -z $USE_CILIUM ]]; then
    scp \
      "$dir/bin/$cni_plugins_archive" \
      "$dir/bin/kube-proxy" \
      ubuntu@control$i:
  fi
done

for i in $(seq 0 2); do
  scp \
    "$dir/bin/$crictl_archive" \
    "$dir/bin/runc.$arch" \
    "$dir/bin/$containerd_archive" \
    "$dir/bin/kubelet" \
    ubuntu@worker$i:

  if [[ -z $USE_CILIUM ]]; then
    scp \
      "$dir/bin/$cni_plugins_archive" \
      "$dir/bin/kube-proxy" \
      ubuntu@worker$i:
  fi
done
