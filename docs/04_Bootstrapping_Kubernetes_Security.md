\[ **macOS/ARM64** | [Linux/AMD64](../../linux/docs/04_Bootstrapping_Kubernetes_Security.md) \]

Previous: [Launching the VM Cluster](03_Launching_the_VM_Cluster.md)

# Bootstrapping Kubernetes Security

At this point in the guide, we have all the virtual hardware prepared, and we're eager to start installing
Kubernetes on it.

However, in order to properly understand all the steps and various magic options of Kubernetes components, 
it would be worth to stop and look at the Kubernetes architecture from a bird's eye view. Kubernetes is a fairly complex
system, made of multiple interconnected components. In a system like that, security is paramount, and must be understood
and set up with diligence.

In this chapter, we're going to outline the entire Kubernetes architecture, i.e. list all its components and
communication channels. Then we'll explain how each communication channel is secured. Finally, we will prepare
a set of certificates and configuration files that we'll use during actual installation of Kubernetes components,
in subsequent chapters.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Prerequisites](#prerequisites)
- [Overview of Kubernetes building blocks](#overview-of-kubernetes-building-blocks)
  - [Communication channels](#communication-channels)
  - [Kubernetes API authentication overview](#kubernetes-api-authentication-overview)
  - [Listing all the necessary certificates](#listing-all-the-necessary-certificates)
  - [Simplifying the setup](#simplifying-the-setup)
  - [Kubeconfigs](#kubeconfigs)
- [Bootstrapping the security](#bootstrapping-the-security)
  - [Generating certificates with `cfssl`](#generating-certificates-with-cfssl)
    - [Root Certificate Authority](#root-certificate-authority)
    - [CA configuration file](#ca-configuration-file)
    - [The main Kubernetes API certificate](#the-main-kubernetes-api-certificate)
    - [The `admin` user certificate](#the-admin-user-certificate)
    - [Worker node certificates](#worker-node-certificates)
    - [The `kube-scheduler` certificate](#the-kube-scheduler-certificate)
    - [The `kube-controller-manager` certificate](#the-kube-controller-manager-certificate)
    - [The `kube-proxy` certificate](#the-kube-proxy-certificate)
    - [The service account token signing certificate](#the-service-account-token-signing-certificate)
  - [Scripting up](#scripting-up)
  - [Generating kubeconfigs](#generating-kubeconfigs)
  - [Generating cluster data encryption key](#generating-cluster-data-encryption-key)
- [Distributing certificates and keys](#distributing-certificates-and-keys)
- [Setting up local `kubeconfig`](#setting-up-local-kubeconfig)
- [Summary](#summary)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Make sure you have completed the previous chapters and have all the necessary
[packages](00_Introduction.md#software) installed.

## Overview of Kubernetes building blocks

Kubernetes is made of multiple [components](https://kubernetes.io/docs/concepts/overview/components/), 
running as separate processes that communicate with each other. They are split between control plane and worker nodes.

The control plane components include:
* `etcd` - the central, distributed, highly reliable database holding the entire cluster state
* `kube-apiserver` - the Kubernetes API server, i.e. the public interface of the cluster
* `kube-scheduler` - the component responsible for assigning pods to worker nodes
* `kube-controller-manager` - the component running [Kubernetes controllers](https://kubernetes.io/docs/concepts/architecture/controller/)
* `cloud-controller-manager` - provides integrations specific to cloud provider (AWS, GCP, etc.) - **not used in this guide**

Worker nodes run the following components:
* `kubelet` - manages the lifecycle of pods on a given worker node
* `kube-proxy` - serves as a local proxy/load balancer for 
  [Kubernetes services](https://kubernetes.io/docs/concepts/services-networking/service/)

For [technical reasons explained later](06_Spinning_up_Worker_Nodes.md#turning-control-plane-nodes-into-worker-like-nodes),
we'll run `kubelet` and `kube-proxy` on control plane nodes, too.

### Communication channels

Now, let's outline all the ways these components 
[communicate](https://kubernetes.io/docs/concepts/architecture/control-plane-node-communication/) with each other.

* every `etcd` instance talks to all other `etcd` instances (peers)
* `kube-apiserver` talks to `etcd` as a client
* `kube-scheduler` talks to `kube-apiserver` as a client
* `kube-controller-manager` talks to `kube-apiserver` as a client
* `kubelet` talks to `kube-apiserver` as a client
* `kube-proxy` talks to `kube-apiserver` as a client
* also, the `kube-apiserver` talks to `kubelet` as a client - for some specific purposes like fetching logs
  or setting up port forwarding to pods
* external clients talk to `kube-apiserver`, typically using `kubectl`
* pods running in the cluster may talk to `kube-apiserver` as clients
* `kube-apiserver` may occasionally communicate with services running in the cluster 
  (e.g. [admission webhooks](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/))

Most of this communication will be secured using TLS with X.509 certificates.
Authentication must be mutual, i.e. both the server and the client must present a valid certificate.
Of course, every certificate must be signed by a certificate authority that is trusted by the receiving party.

### Kubernetes API authentication overview

Even though we are going to use mostly certificates to authenticate to the Kubernetes API server,
[several other strategies](https://kubernetes.io/docs/reference/access-authn-authz/authentication/) are possible.

Let's quickly discuss the basic authentication model of Kubernetes:
* A human client of a Kubernetes API typically identifies itself as a _user_, 
  optionally belonging to one or more _groups_. Users and groups are not managed by Kubernetes in any way, i.e. there
  is no catalogue of users and groups maintained by the cluster. Instead, users and groups are treated like opaque 
  identifiers, and the API server trusts its selected _authentication strategy_ to determine them. \
  For example, in case of certificates, when the certificate is valid according to preconfigured CA, the _Common Name_ 
  field is assumed to contain the username, while _Organization_ fields are interpreted as group names.
* A non-human client of a Kubernetes API (e.g. a pod running in the cluster) typically authenticates itself using a 
  [service account](https://kubernetes.io/docs/concepts/security/service-accounts/). Unlike users and groups, service
  accounts are managed by Kubernetes, i.e. they can be created, deleted, etc. When identifying as a service account,
  an API client uses a [JWT](https://jwt.io/) token, previously generated and provisioned by the cluster
  to the pod (see [projected volumes](https://kubernetes.io/docs/concepts/storage/projected-volumes/#serviceaccounttoken)).
  However, the token itself must be signed - unsurprisingly - with a certificate, and this certificate must be
  preconfigured.

### Listing all the necessary certificates

This gives us an overview of all the certificates that we need to prepare for a fully functioning Kubernetes cluster:

* `etcd` peer certificate, for every `etcd` instance
* server certificates:
  * `etcd` server certificate, for every `etcd` instance
  * `kube-apiserver` server certificate
  * `kubelet` server certificate
* client certificates
  * `kube-apiserver` client certificate to communicate with `etcd`
  * `kube-apiserver` client certificate to communicate with `kubelet`s
  * `kubelet` client certificate to communicate with `kube-apiserver`, for every control and worker node
  * `kube-scheduler` client certificate to communicate with `kube-apiserver`
  * `kube-controller-manager` client certificate to communicate with `kube-apiserver`
  * `kube-proxy` client certificate to communicate with `kube-apiserver`
  * client certificates for human users to communicate with the Kubernetes API (`kube-apiserver`)
* certificate and key for verifying and signing service account tokens

Of course, every certificate must be signed by a Certificate Authority. Technically, it is possible to have
distinct CAs for different kinds of certificates:
* a CA to sign `etcd` peer certificates
* a CA to sign `etcd` server certificate(s)
* a CA to sign `kube-apiserer` server certificate
* a CA to sign `kubelet` server certificate
* a CA to sign `etcd` client certificates
* a CA to sign `kube-apiserver` client certificates
* a CA to sign `kubelet` client certificates

### Simplifying the setup

The previous section presents an exhaustive list of certificates and CAs that could be configured separately.
In practice, however, there is no reason to go that far, at least for the purposes of this guide.
We'll simplify things in the following ways:

* We'll use a single root CA to sign all the certificates
* `kube-apiserver`, even though deployed as three separate instances, is seen by its clients as a single
  service. We are planning to set up a load balancer for it (the `gateway` VM) and make it reachable using
  a single virtual IP address and domain name. For this reason it is natural (and necessary) to have a single
  server certificate for the Kubernetes API. This certificate will contain [SAN](https://en.wikipedia.org/wiki/Subject_Alternative_Name)
  entries for all the possible IPs and domain names that can be used to reach the API, including addresses
  of individual instances, the virtual, load balanced address, as well as Kubernetes-internal IPs and domains.
* `etcd` runs on the same nodes as `kube-apiserver`, so it is natural to reuse the Kubernetes API certificate for `etcd`,
  to serve both as a peer and server certificate, on every `etcd` instance.
* We will also use the main Kubernetes API certificate as the client certificate used to communicate with
  `etcd` and `kubelet`.
* Each `kubelet`'s server certificate will also serve as its client certificate to communicate with `kube-apiserver`.

As for the client certificates used to communicate with `kube-apiserver`, we must keep them separate. This is because 
we must maintain separate identities for `kube-scheduler`, `kube-controller-manager`, every node's
`kubelet`, `kube-proxy`, and external, human users, in order for each of these actors to get the appropriate 
set of permissions within the Kubernetes API server.

In this guide, the only human user will be the `admin` user, with full permissions to the entire Kubernetes API.

Ultimately, this gives us the following list of certificates to prepare:

1. The root CA
2. The main Kubernetes API certificate
3. The `admin` user certificate
4. Node (`kubelet`) certificates, separate for each control and worker node
5. The `kube-scheduler` certificate
6. The `kube-controller-manager` certificate
7. The `kube-proxy` certificate
8. The certificate for signing service account tokens

### Kubeconfigs

Every Kubernetes API client needs three pieces of data to communicate with the server: the client certificate, 
its associated private key, and the CA to verify the server certificate. These three files are usually not configured 
directly, but rather included into a [kubeconfig](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/).

For the purposes of this guide, we'll treat kubeconfigs as simple wrappers over these three files. In their generality,
however, they can be more complex. For example, they can include authentication data for multiple users of
multiple independent Kubernetes clusters.

We will need to generate a kubeconfig for every client of the Kubernetes API:
* The `admin` user
* Each node (i.e. `kubelet`)
* `kube-scheduler`
* `kube-controller-manager`
* `kube-proxy`

## Bootstrapping the security

It's time to generate all the listed certificates and kubeconfigs.

> [!NOTE]
> This section is largely based on 
> [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md)

### Generating certificates with `cfssl`

There are many tools to generate X.509 certificates. Our utility of choice is 
[cfssl](https://github.com/cloudflare/cfssl).

Let's create a directory for everything security-related:

```bash
mkdir auth && cd auth
```

#### Root Certificate Authority

The first thing to generate is the root certificate authority. We can do that by preparing a JSON file
representing a Certificate Signing Request and pass it to `cfssl`.

Create the `ca-csr.json` file:

```json
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "Kubernetes",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ]
}
```

All the names in this CSR are arbitrary, you can choose whatever you like.

Generate the CA with:

```bash
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
```

This generates `ca.csr`, `ca.pem` (the certificate) and `ca-key.pem` (the private key).
The `.csr` file will not be used and may be discarded.

> [!NOTE]
> `cfssl` is designed to work like a REST API and returns its result wrapped into JSON.
> We use `cfssljson` utility to convert it into PEM files.

#### CA configuration file

In order to facilitate signing client & server certificates, we can factor out common settings
into a shared configuration file, the `ca-config.json`:

```json
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "87600h"
      }
    }
  }
}
```

Here are some details to note about it:
* `default` specifies global options, while `profiles` contains a set of arbitrarily named "profiles" that may
  override these options. When generating a certificate, the desired profile is selected with a command line option. 
  This way the config file may serve as an aggregate for multiple, independent sets of options.
* `expiry` specifies the validity of a certificate - in this case we set it to 10 years
  (unfortunately, hour is the largest time unit possible to use here)
* `usages` corresponds to the [Key Usage Extension](https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.3) of
  the X.509 certificate format

#### The main Kubernetes API certificate

Create a `kubernetes-csr.json` file:

```json
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "Kubernetes",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ],
  "hosts": [
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster",
    "kubernetes.default.svc.cluster.local",
    "10.32.0.1",
    "kubernetes.kubenet",
    "192.168.1.21",
    "control0",
    "control0.kubenet",
    "192.168.1.11",
    "control1",
    "control1.kubenet",
    "192.168.1.12",
    "control2",
    "control2.kubenet",
    "192.168.1.13",
    "127.0.0.1"
  ]
}
```

CN and `names` for this certificate are arbitrary. What's important is the `hosts` list, which includes all the domain 
names and IPs that may be used to reach the Kubernetes API, both from outside and inside the Kubernetes cluster:
* `kubernetes.default.*` are domain names used to communicate with the Kubernetes API from within the cluster,
  they will resolve to the Kubernetes API internal Service IP
* 10.32.0.1 is the Kubernetes API internal Service IP - it may be chosen arbitrarily as long as it is consistent
  with configuration of `kube-proxy` and/or other Kubernetes components - we will see that in subsequent chapters
* `kubernetes.kubenet` is the full domain name that resolves to the load-balanced virtual IP of the Kubernetes API
  from outside the cluster
* 192.168.1.21 is the Kubernetes API virtual IP, which we will take care of in another chapter
* the simple name `kubernetes` is resolvable both from outside and inside the cluster
* `controlX`, `controlX.kubenet` are control node domain names
* 192.168.1.1X are control node IPs
* finally, a 127.0.0.1 entry to allow reaching Kubernetes API via localhost on control nodes

Generate and sign the certificate with:

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes
```

The resulting interesting files are `kubernetes.pem` and `kubernetes-key.pem`.

#### The `admin` user certificate

Create an `admin-csr.json` file:

```json
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "system:masters",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ]
}
```

Then generate a signed certificate and key using:

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin
```

This will generate `admin.pem` and `admin-key.pem`.

> [!IMPORTANT]
> The `admin` user gets unrestricted access to the Kubernetes API thanks to its magic `system:masters` _group_ name. 
> This is a special group within the Kubernetes [RBAC authorization mode](https://kubernetes.io/docs/reference/access-authn-authz/rbac/) 
> that is bootstrapped to have unlimited permissions.
> The CN `admin`, interpreted as _user_ name, also has a special meaning.

#### Worker node certificates

We need six separate certificates for control and worker nodes. They differ only in names, IPs and hostnames, so let's use
some scripting. Write out the `controlX-csr.json` and `workerX-csr.json` files:

```bash
vmnames=(control{0,1,2} worker{0,1,2})

for vmid in $(seq 1 ${#vmnames[@]}); do 
vmname=${vmnames[$vmid]}
cat <<EOF > "$vmname-csr.json"
{
  "CN": "system:node:$vmname",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "system:nodes",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ],
  "hosts": [
    "$vmname",
    "$vmname.kubenet",
    "192.168.1.$((10 + $vmid))"
  ]
}
EOF
done
```

and generate the certificates:

```bash
for vmname in $vmnames; do cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  $vmname-csr.json | cfssljson -bare $vmname
done
```

> [!IMPORTANT]
> `system:node:<nodename>` and `system:nodes` are magic user and group names interpreted by
> Kubernetes [node authorization mode](https://kubernetes.io/docs/reference/access-authn-authz/node/).

#### The `kube-scheduler` certificate

Create `kube-scheduler-csr.json`:

```json
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "system:kube-scheduler",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ]
}
```

Generate certificate with:

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler
```

> [!IMPORTANT]
> `system:kube-scheduler` is a magic string recognized by Kubernetes
> [RBAC authorization mode](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

#### The `kube-controller-manager` certificate

Create `kube-controller-manager-csr.json`:

```json
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "system:kube-controller-manager",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ]
}
```

Generate the certificate with:

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
```

> [!IMPORTANT]
> `system:kube-controller-manager` is a magic string recognized by Kubernetes
> [RBAC authorization mode](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

#### The `kube-proxy` certificate

Create `kube-proxy-csr.json`:

```json
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "system:node-proxier",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ]
}
```

Generate the certificate with:

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy
```

> [!IMPORTANT]
> `system:kube-proxy` and `system:node-proxier` are magic strings recognized by Kubernetes
> [RBAC authorization mode](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

#### The service account token signing certificate

Create `service-account-csr.json`:

```json
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "PL",
      "L": "Krakow",
      "O": "Kubernetes",
      "OU": "kubenet",
      "ST": "Lesser Poland"
    }
  ]
}
```

Generate the certificate with:

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account
```

### Scripting up

Let's remove some boilerplate and have a script to turn all the `*-csr.json` files into PEM files at once.
Let's save it as `genauth.sh` (in the `auth` directory).

```bash
#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

gencert() {
  name=$1
  cfssl gencert \
    -ca="$dir/ca.pem" \
    -ca-key="$dir/ca-key.pem" \
    -config="$dir/ca-config.json" \
    -profile=kubernetes \
    "$dir/$name-csr.json" | cfssljson -bare $name
}

cfssl gencert -initca "$dir/ca-csr.json" | cfssljson -bare ca

for name in kubernetes admin kube-scheduler kube-controller-manager kube-proxy service-account; do
  gencert $name
done

for i in $(seq 0 2); do
  gencert control$i
  gencert worker$i
done

```

### Generating kubeconfigs

As already explained, we need a _kubeconfig_ for every Kubernetes API client certificate.
We can make them with the `kubectl` command. Below is a script fragment that does this. 
You can add it to `genauth.sh`.

```bash
genkubeconfig() {
  cert=$1
  user=$2
  kubeconfig="$dir/${cert}.kubeconfig"

  kubectl config set-cluster kubenet \
    --certificate-authority="$dir/ca.pem" \
    --embed-certs=true \
    --server=https://kubernetes:6443 \
    --kubeconfig="$kubeconfig"

  kubectl config set-credentials "$user" \
    --client-certificate="$dir/${cert}.pem" \
    --client-key="$dir/${cert}-key.pem" \
    --embed-certs=true \
    --kubeconfig="$kubeconfig"

  kubectl config set-context default \
    --cluster=kubenet \
    --user="$user" \
    --kubeconfig="$kubeconfig"

  kubectl config use-context default \
    --kubeconfig="$kubeconfig"
}

genkubeconfig admin admin
genkubeconfig kube-scheduler system:kube-scheduler
genkubeconfig kube-controller-manager system:kube-controller-manager
genkubeconfig kube-proxy system:kube-proxy

for i in $(seq 0 2); do
  genkubeconfig control$i system:node:control$i
  genkubeconfig worker$i system:node:worker$i
done
```

### Generating cluster data encryption key

The final security-related piece of data, although unrelated to authentication, is a symmetric encryption
key which can be used by `kube-apiserver` to encrypt sensitive data stored in `etcd`. The key is random, and the only
thing we need to do is to wrap it into a simple YAML file.

Let's do it with a script, `genenckey.sh`:

```bash
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
```

## Distributing certificates and keys

Let's upload all the prepared files into the VMs.
Make sure the VMs are running, as described in the [previous chapter](03_Launching_the_VM_Cluster.md).
Also, make sure that [`vmsshsetup.sh`](02_Preparing_Environment_for_a_VM_Cluster.md#automating-establishment-of-vms-authenticity) 
has been run for all the VMs.

Then, upload the files with a script, `deployauth.sh`:

```bash
#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

for i in $(seq 0 2); do
  vmname=control$i
  scp \
      "$dir/ca.pem" \
      "$dir/ca-key.pem" \
      "$dir/kubernetes-key.pem" \
      "$dir/kubernetes.pem" \
      "$dir/service-account-key.pem" \
      "$dir/service-account.pem" \
      "$dir/admin.kubeconfig" \
      "$dir/kube-controller-manager.kubeconfig" \
      "$dir/kube-scheduler.kubeconfig" \
      "$dir/encryption-config.yaml" \
      "$dir/$vmname.pem" \
      "$dir/$vmname-key.pem" \
      "$dir/$vmname.kubeconfig" \
      "$dir/kube-proxy.kubeconfig" \
      ubuntu@$vmname:~
done

for i in $(seq 0 2); do
  vmname=worker$i
  scp \
      "$dir/ca.pem" \
      "$dir/$vmname.pem" \
      "$dir/$vmname-key.pem" \
      "$dir/$vmname.kubeconfig" \
      "$dir/kube-proxy.kubeconfig" \
      ubuntu@$vmname:~
done

scp "$dir/ca.pem" ubuntu@gateway:~
```

## Setting up local `kubeconfig`

As for the `admin` certificate, we want to use it locally, so instead of creating a separate `kubeconfig` file,
we add it into a local, default one (i.e. `~/.kube/config`), which may already exist and contain entries for other
Kubernetes clusters.

We can do this with the following script, `setuplocalkubeconfig.sh`:

```bash
#!/usr/bin/env bash

set -xe
dir=$(dirname "$0")

kubectl config set-cluster kubenet \
  --certificate-authority="$dir/ca.pem" \
  --embed-certs=true \
  --server=https://kubernetes:6443

kubectl config set-credentials admin \
  --client-certificate="$dir/admin.pem" \
  --client-key="$dir/admin-key.pem" \
  --embed-certs=true

kubectl config set-context kubenet \
  --cluster=kubenet \
  --user=admin

kubectl config use-context kubenet
```

This will allow us to use the `kubectl` command locally to communicate with the (currently nonexistent) Kubernetes
cluster.

## Summary

In this chapter, we have:
* learned about all the components that a Kubernetes deployment is made of
* thoroughly understood which of these components communicate with each other and how this communication is secured
* learned the basic architecture of Kubernetes API client authentication
* generated all the certificates and configuration files necessary for secure Kubernetes deployment
* uploaded the files into the VMs

Next: [Installing Kubernetes Control Plane](05_Installing_Kubernetes_Control_Plane.md)
