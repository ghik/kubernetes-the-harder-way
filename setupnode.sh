#!/usr/bin/env bash

# This script installs the container runtime, kubelet and (optionally) kube-proxy on a node.

set -xe
dir=$(dirname "$0")
source "$dir/variables.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

vmname=$(hostname -s)

case "$vmname" in
  control*)
    vmid=$((1 + ${vmname:7}));;
  worker*)
    vmid=$((4 + ${vmname:6}));;
  *)
    echo "expected control or worker VM, got $vmname" >&2
    return 1;;
esac

pod_cidr=10.${vmid}.0.0/16

crictl_archive=crictl-v${cri_version}-linux-${arch}.tar.gz
containerd_archive=containerd-${containerd_version}-linux-${arch}.tar.gz
cni_plugins_archive=cni-plugins-linux-${arch}-v${cni_plugins_version}.tgz

wget -q --show-progress --https-only --timestamping \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v${cri_version}/${crictl_archive} \
  https://github.com/opencontainers/runc/releases/download/v${runc_version}/runc.${arch} \
  https://github.com/containerd/containerd/releases/download/v${containerd_version}/${containerd_archive} \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kubelet

mkdir -p \
  /opt/cni/bin \
  /etc/cni/net.d \
  /var/lib/kubelet \
  /var/lib/kubernetes \
  /var/run/kubernetes

mkdir -p containerd
tar -xvf $crictl_archive
tar -xvf $containerd_archive -C containerd
cp runc.${arch} runc
chmod +x runc crictl kubelet
cp runc crictl kubelet /usr/local/bin/
cp containerd/bin/* /bin/

if [[ -z $USE_CILIUM ]]; then
  wget -q --show-progress --https-only --timestamping \
    https://github.com/containernetworking/plugins/releases/download/v${cni_plugins_version}/${cni_plugins_archive} \
    https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-proxy

  mkdir -p /var/lib/kube-proxy
  chmod +x kube-proxy
  cp kube-proxy /usr/local/bin/
  tar -xvf $cni_plugins_archive -C /opt/cni/bin/
fi 

# containerd

mkdir -p /etc/containerd/

cat << EOF | tee /etc/containerd/config.toml
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
    BinaryName = "/usr/local/bin/runc"
EOF

cat <<EOF | tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

# cni

if [[ -z $USE_CILIUM ]]; then

cat <<EOF | tee /etc/cni/net.d/10-bridge.conf
{
    "cniVersion": "${cni_spec_version}",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${pod_cidr}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF

cat <<EOF | tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "${cni_spec_version}",
    "name": "lo",
    "type": "loopback"
}
EOF

fi

# kubelet

cp ${vmname}-key.pem ${vmname}.pem /var/lib/kubelet/
cp ${vmname}.kubeconfig /var/lib/kubelet/kubeconfig
cp ca.pem /var/lib/kubernetes/

cat <<EOF | tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${vmname}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${vmname}-key.pem"
containerRuntimeEndpoint: "unix:///var/run/containerd/containerd.sock"
cgroupDriver: "systemd"
EOF

if [[ $vmname =~ ^control[0-9]+ ]]; then cat <<EOF | tee -a /var/lib/kubelet/kubelet-config.yaml
registerWithTaints:
  - key: node-roles.kubernetes.io/control-plane
    value: ""
    effect: NoSchedule
EOF
fi

cat <<EOF | tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# kube-proxy

if [[ -z $USE_CILIUM ]]; then

cp kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

cat <<EOF | tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.0.0.0/12"
EOF

cat <<EOF | tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

fi

# run it all

systemctl daemon-reload
systemctl enable containerd kubelet
systemctl start containerd kubelet

if [[ -z $USE_CILIUM ]]; then
  systemctl enable kube-proxy
  systemctl start kube-proxy
fi
