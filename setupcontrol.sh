#!/usr/bin/env bash

# This script installs Kubernetes control plane components on a node.

set -xe
dir=$(dirname "$0")
source "$dir/variables.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

vmaddr=$(ip addr show | grep -Po 'inet \K192\.168\.1\.1\d+')
vmname=$(hostname -s)

# etcd

etcd_archive=etcd-v${etcd_version}-linux-${arch}.tar.gz
wget -q --show-progress --https-only --timestamping \
  https://github.com/etcd-io/etcd/releases/download/v${etcd_version}/$etcd_archive

tar -xvf $etcd_archive
cp etcd-v${etcd_version}-linux-${arch}/etcd* /usr/local/bin
mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd/
cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/

cat <<EOF | tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name $vmname \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${vmaddr}:2380 \\
  --listen-peer-urls https://${vmaddr}:2380 \\
  --listen-client-urls https://${vmaddr}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${vmaddr}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster control0=https://192.168.1.11:2380,control1=https://192.168.1.12:2380,control2=https://192.168.1.13:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable etcd
systemctl start etcd

# kubernetes control plane setup

mkdir -p /etc/kubernetes/config

wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-apiserver \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-controller-manager \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-scheduler \

chmod +x kube-apiserver kube-controller-manager kube-scheduler
cp kube-apiserver kube-controller-manager kube-scheduler /usr/local/bin/

mkdir -p /var/lib/kubernetes/
cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
  service-account-key.pem service-account.pem \
  encryption-config.yaml /var/lib/kubernetes/

# kube-apiserver

cat <<EOF | tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${vmaddr} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://192.168.1.11:2379,https://192.168.1.12:2379,https://192.168.1.13:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-account-signing-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-account-issuer=https://192.168.1.21:6443 \\
  --service-cluster-ip-range=10.32.0.0/16 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# kube-controller-manager

cp kube-controller-manager.kubeconfig /var/lib/kubernetes/

cat <<EOF | tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.0.0.0/8 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/16 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# kube-scheduler

cp kube-scheduler.kubeconfig /var/lib/kubernetes/

cat <<EOF | tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1beta3
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

cat <<EOF | tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl start kube-apiserver kube-controller-manager kube-scheduler
