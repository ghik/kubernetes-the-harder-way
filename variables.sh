# Common variables reused in other scripts

etcd_version=3.6.2
k8s_version=1.33.2
cri_version=1.33.0
runc_version=1.3.0
containerd_version=2.1.3
cni_plugins_version=1.7.1
cni_spec_version=1.0.0

case $(uname -m) in
  arm64|aarch64) arch=arm64;;
  x86_64|amd64) arch=amd64;;
  *) echo "unsupported CPU architecture"; exit 1
esac
