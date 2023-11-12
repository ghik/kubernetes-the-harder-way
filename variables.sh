# Common variables reused in other scripts

etcd_version=3.5.9
k8s_version=1.28.3
cri_version=1.28.0
runc_version=1.1.9
containerd_version=1.7.7
cni_plugins_version=1.3.0

case $(uname -m) in
  arm64|aarch64) arch=arm64;;
  x86_64|amd64) arch=amd64;;
  *) echo "unsupported CPU architecture"; exit 1
esac
