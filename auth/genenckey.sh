#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

key=$(head -c 32 /dev/urandom | base64)

cat > "$dir/encryption-config.yaml" <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $key
      - identity: {}
EOF
