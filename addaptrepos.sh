#!/usr/bin/env bash

if [[ "$EUID" -ne 0 ]]; then
  echo "this script must be run as root" >&2
  exit 1
fi

apt install -y apt-transport-https ca-certificates

if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]]; then
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' \
    | tee /etc/apt/sources.list.d/kubernetes.list
fi

if [[ ! -f /etc/apt/sources.list.d/helm-stable-debian.list ]]; then
  curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
    | tee /etc/apt/sources.list.d/helm-stable-debian.list
fi

apt update
