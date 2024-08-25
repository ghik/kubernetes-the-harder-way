# Common variables reused in other scripts

etcd_version=3.5.15
k8s_version=1.31.0
cri_version=1.31.1
runc_version=1.1.13
containerd_version=1.7.20
cni_plugins_version=1.5.1

case $(uname -m) in
  arm64|aarch64) arch=arm64;;
  x86_64|amd64) arch=amd64;;
  *) echo "unsupported CPU architecture"; exit 1
esac
