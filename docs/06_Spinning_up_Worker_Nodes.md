\[ **macOS/ARM64** | [Linux/AMD64](../../linux/docs/06_Spinning_up_Worker_Nodes.md) \]

Previous: [Installing Kubernetes Control Plane](05_Installing_Kubernetes_Control_Plane.md)

# Spinning up Worker Nodes

The control plane is working, and we have a nice, highly available, load balanced Kubernetes API at our disposal.
It's time for the worker nodes to join the party.

This chapter is a mix of deployment instructions and explanations of Kubernetes' inner workings. In particular,
we're going to take this chapter as an opportunity to dive a bit deeper into how container runtimes work,
and what are the underlying mechanisms responsible for Kubernetes networking.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Prerequisites](#prerequisites)
- [Overview](#overview)
- [Turning control plane nodes into "pseudo-workers"](#turning-control-plane-nodes-into-pseudo-workers)
- [Shell variables](#shell-variables)
- [The Container Runtime](#the-container-runtime)
  - [What are containers?](#what-are-containers)
  - [Installing container runtime binaries](#installing-container-runtime-binaries)
- [CNI plugins](#cni-plugins)
  - [Splitting pod IP range between nodes](#splitting-pod-ip-range-between-nodes)
  - [Installing and configuring standard CNI plugins](#installing-and-configuring-standard-cni-plugins)
- [`kubelet`](#kubelet)
- [Scheduling a first pod](#scheduling-a-first-pod)
  - [Peeking into pod networking](#peeking-into-pod-networking)
- [Routing pod traffic via the host machine](#routing-pod-traffic-via-the-host-machine)
- [Authorizing `kube-apiserver` to `kubelet` traffic](#authorizing-kube-apiserver-to-kubelet-traffic)
- [`kube-proxy`](#kube-proxy)
  - [Forcing `iptables` for bridge traffic](#forcing-iptables-for-bridge-traffic)
  - [Testing out service traffic](#testing-out-service-traffic)
  - [Digging deeper into service load balancing](#digging-deeper-into-service-load-balancing)
- [Summary](#summary)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Just like in the [previous chapter](05_Installing_Kubernetes_Control_Plane.md), we'll be installing stuff
on multiple nodes at once (both control and worker VMs). It is recommended to do this with `tmux` pane synchronization,
as [described before](03_Launching_the_VM_Cluster.md#synchronizing-panes).

## Overview

The most important Kubernetes component running on worker nodes is `kubelet`. It is responsible for announcing
worker node's presence in the cluster to `kube-apiserver`, and it is the toplevel entity responsible for the lifecycle
of all the pods/containers running on a worker node.

However, `kubelet` does not manage containers directly. This part of Kubernetes is highly abstracted, pluggable and
extensible. Namely, there are (at least) two abstract specifications that `kubelet` integrates with:

* The [Container Runtime Interface](https://kubernetes.io/docs/concepts/architecture/cri/)
* The [Container Network Interface](https://github.com/containernetworking/cni)

The CRI is implemented by a _container runtime_ while the CNI is implemented by the so called CNI _plugins_. 
We'll need to install them manually and configure `kubelet` properly to use them.

Finally, a worker node typically runs a `kube-proxy`, a component responsible for handling and load balancing
traffic to Kubernetes [Services](https://kubernetes.io/docs/concepts/services-networking/service/).

## Turning control plane nodes into "pseudo-workers"

`kubelet`, container runtime and `kube-proxy` are typically necessary only on worker nodes, as these are the
components needed to run actual cluster workloads, inside pods.

However, we'll install these components on control plane nodes as well. The reasons for that are
technical, the most important of them being the fact that `kube-apiserver` occasionally needs to communicate with
services running inside the cluster (e.g. [admission webhooks](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/#what-are-admission-webhooks)).

This requires control plane nodes to participate in the cluster overlay network, so that service Cluster IPs are
routable from them. This means that, at minimum, we need to run `kube-proxy` on control plane nodes. Unfortunately, 
`kube-proxy` refuses to run on a non-registered node, so we are forced to turn control plane nodes into fully-configured
worker-like nodes with `kubelet` and container runtime.

Having said that, we want to avoid running any actual workloads on control plane nodes. Fortunately, Kubernetes
has [mechanisms](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/) for excluding nodes 
from regular pod scheduling, and we'll take advantage of that.

## Shell variables

Let's define some reusable shell variables for this chapter. Run this in the SSH shell on all control & worker nodes:

```bash
arch=arm64
k8s_version=1.28.3
cri_version=1.28.0
runc_version=1.1.9
containerd_version=1.7.7
cni_plugins_version=1.3.0
cni_spec_version=1.0.0
```

All further instructions assume availability of these variables (make sure to run everything in the same shell).

## The Container Runtime

Let's start worker setup with installation of the container runtime. We'll take this step as an opportunity to
do a little introduction (or refresh) on what containerization fundamentally is and how it is realized in
Linux. If you're not interested in this theoretical introduction, you can 
[skip it](#installing-container-runtime-binaries).

### What are containers?

A _container_, in practice, is a regular Linux process, but run in a special way, so that it has a
different (i.e. limited) view of its environment, in comparison to a plain, non-containerized process. The goal
of containerization is to provide sufficient level of isolation between containerized processes, so that they cannot
see or affect each other, or the host operating system. Despite their isolation, containerized processes still run 
in the same OS (kernel), which makes it a more lightweight alternative to full virtualization.

The Linux kernel implements two core features that make this isolation possible: the 
[namespaces](https://en.wikipedia.org/wiki/Linux_namespaces) and the [cgroups](https://en.wikipedia.org/wiki/Cgroups).

Namespaces put containerized processes into "sandboxes" where a process cannot "see" the outside of its sandbox. 
There are multiple namespace types, each one controlling a different aspect of what a process can see. 
The most important ones include:
* The _mount_ namespace \
  Makes the containerized process see a completely different set of mount points than on the
  host operating system, effectively making it have its own, isolated filesystem tree.
* The _PID_ namespace \
  Assigns a new, virtual PID to the containerized process (usually equal to 1) and hides all
  other processes from it, unless they are running in the same namespace.
* The _user_ namespace \
  Creates an illusion for the containerized process of running as a different user
  (often the `root` user) than it is actually being run as. True system users are invisible for the containerized 
  process.
* The _network_ namespace \
  Makes the containerized process see a completely different set of network interfaces than
  on the host operating system. Usually this involves creating some kind of virtual ethernet interface visible within
  the container. This virtual interface is then connected in some way (e.g. bridged) to host OS interfaces (invisibly
  to the container).

Cgroups are a mechanism for putting resource limits (CPU, memory, IO, etc.) on containerized processes.
A Linux system has a global cgroup _hierarchy_, represented by a special filesystem. In case of Ubuntu, the cgroup
hierarchy is already managed by `systemd`. The container runtime must be aware of that in order to cooperate with
`systemd`. You will see that reflected in various configuration options throughout this chapter.

So, if you're looking for a short, technical (Linux-specific) and concrete answer to the question "what is a container?",
the answer would be:

> A *container* is a process isolated from its host operating system and other processes 
> using Linux namespaces and cgroups.

It is important to stress the flexibility of isolation provided by namespaces and cgroups. In particular, it is possible
to run a process with partial isolation, e.g. using only a separate network namespace, while letting all other
aspects of the system to be non-isolated. This is used in practice by Kubernetes to run pods with special "privileges".
These pods can be used for direct configuration or monitoring of the nodes they run on.

Namespaces are also designed to be shared by multiple processes. This is also a standard thing in Kubernetes, e.g.
all containers in a pod share the same network namespace.

### Installing container runtime binaries

The container runtime for our deployment consists of three elements:
* `containerd`, a system daemon that manages the lifecycle of containers,
  contains an implementation of the CRI, invoked by `kubelet`
* `runc`, a low-level utility for launching containerized processes, 
  a reference implementation of the [OCI](https://opencontainers.org/about/overview/), invoked by `containerd`
* `crictl`, a command line tool to inspect and manage containers, 
  installed for usage by humans for monitoring and troubleshooting purposes

> [!NOTE]
> Note how Docker is not involved in the container runtime, even though we are going to be running
> Docker images. The relationship between Docker, `containerd`, CRI, OCI, etc. is complex, and has evolved repeatedly 
> over time. Long story short, using `containerd` and `runc` is - for our purposes -
> equivalent to using Docker, because nowadays Docker is built on top of these lower-level utilities, anyway.
> We are only getting rid of Docker's "frontend" - which is nice if you want to use it directly but not essential for Kubernetes.

Download and install the container runtime binaries on all control & worker nodes:

```bash
crictl_archive=crictl-v${cri_version}-linux-${arch}.tar.gz
containerd_archive=containerd-${containerd_version}-linux-${arch}.tar.gz

wget -q --show-progress --https-only --timestamping \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v${cri_version}/${crictl_archive} \
  https://github.com/opencontainers/runc/releases/download/v${runc_version}/runc.${arch} \
  https://github.com/containerd/containerd/releases/download/v${containerd_version}/${containerd_archive}

mkdir -p containerd
tar -xvf $crictl_archive
tar -xvf $containerd_archive -C containerd
cp runc.${arch} runc
chmod +x crictl runc
sudo cp crictl runc /usr/local/bin/
sudo cp containerd/bin/* /bin/
```

Configure `containerd`:

```bash
sudo mkdir -p /etc/containerd/

cat << EOF | sudo tee /etc/containerd/config.toml
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    SystemdCgroup = true
    BinaryName = "/usr/local/bin/runc"
EOF
```

Create a `systemd` unit file for `containerd`:

```bash
cat <<EOF | sudo tee /etc/systemd/system/containerd.service
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
```

Enable and run it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable containerd
sudo systemctl start containerd
```

## CNI plugins

As already mentioned, `kubelet` uses an abstraction layer called CNI (Container Network Interface) in order
to set up pod networking. The CNI is implemented by a set of _plugins_.

A CNI plugin is an executable program responsible for configuring some aspect of pod networking. Every plugin
is configured separately, and ultimately they are invoked in a chain, following a well-defined order. Collectively, 
CNI plugins are responsible for configuring the network namespace for each pod. This includes setting up virtual 
interfaces seen from within the pod, connecting them to the external world (the host system), and assigning IP addresses. 
This may also include putting in place various, more complex network traffic manipulation mechanisms based on
lower-level Linux features such as `iptables`, IPVS or eBPF.

The primary goal is to satisfy the fundamental assumption of 
[Kubernetes networking](https://kubernetes.io/docs/concepts/services-networking/): all pods in the cluster
(across all nodes) must be able to communicate with each other without any network address translation.
Pods use a dedicated, cluster-internal IP range. When pod-to-pod traffic needs to be forwarded between worker nodes,
it is the responsibility of the CNI layer to set up some form of forwarding, tunnelling, etc. that is invisible to individual
pods.

### Splitting pod IP range between nodes

During [control plane setup](05_Installing_Kubernetes_Control_Plane.md#installing-kube-controller-manager), 
we have already decided that 10.0.0.0/12 is going to be the IP range for all pods in the cluster.

Now we also need to split this range between individual nodes. We'll use the second octet of IP address to
encode [VM id](02_Preparing_Environment_for_a_VM_Cluster.md#topology-overview), and reduce subnet size to `/16`.

Let's save this into some shell variables:

```bash
vmname=$(hostname -s)

case "$vmname" in
  control*)
    vmid=$((1 + ${vmname:7}));;
  worker*)
    vmid=$((4 + ${vmname:6}));;
  *)
    echo "expected control or worker VM, got $vmname"; return 1;;
esac

pod_cidr=10.${vmid}.0.0/16
```

Note how pod CIDR is disjoint from Service CIDR, which we have configured to 10.32.0.0/16

### Installing and configuring standard CNI plugins

In this guide, we'll use a very simple setup provided by reference implementations of CNI plugins.

First, let's download and install them into the system:

```bash
cni_plugins_archive=cni-plugins-linux-${arch}-v${cni_plugins_version}.tgz

wget -q --show-progress --https-only --timestamping \
  https://github.com/containernetworking/plugins/releases/download/v${cni_plugins_version}/${cni_plugins_archive}
  
sudo mkdir -p /opt/cni/bin
sudo tar -xvf $cni_plugins_archive -C /opt/cni/bin/
```

Now, enable and configure the desired plugins. We'll use two of them: one to set up the loopback interface,
and another to set up a virtual ethernet interface bridged to host network.

```bash
sudo mkdir -p /etc/cni/net.d

cat <<EOF | sudo tee /etc/cni/net.d/10-bridge.conf
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

cat <<EOF | sudo tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "${cni_spec_version}",
    "name": "lo",
    "type": "loopback"
}
EOF
```

The CNI plugins are now ready to be invoked by `kubelet`.

## `kubelet`

Download and install the `kubelet` binary:

```bash
wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kubelet
  
chmod +x kubelet
sudo cp kubelet /usr/local/bin/
```

Copy all the necessary security-related files into place:

```bash
sudo mkdir -p /var/lib/kubelet/ /var/lib/kubernetes/
sudo cp ${vmname}-key.pem ${vmname}.pem /var/lib/kubelet/
sudo cp ${vmname}.kubeconfig /var/lib/kubelet/kubeconfig
sudo cp ca.pem /var/lib/kubernetes/
```

Configure `kubelet`:

```bash
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
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

if [[ $vmname =~ ^control[0-9]+ ]]; then cat <<EOF | sudo tee -a /var/lib/kubelet/kubelet-config.yaml
registerWithTaints:
  - key: node-roles.kubernetes.io/control-plane
    value: ""
    effect: NoSchedule
EOF
```

> [!IMPORTANT]
> The `registerWithTaints` configuration option is appended only on control plane nodes, and it ensures that
> they are excluded from regular pod scheduling (unless very explicitly requested).

> [!NOTE]
> 10.32.0.10 is the (arbitrarily chosen) address of a cluster-internal DNS server.
> We will install it in the [next chapter](07_Installing_Essential_Cluster_Services.md#coredns). 
> `kubelet` must be explicitly aware of this address because it needs to be configured as the DNS server address 
> on every pod's virtual network interface.

Create a `systemd` unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
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
```

Enable and run it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl start kubelet
```

> [!WARNING]
> `kubelet` by default requires that swap is turned off. This seems to be the case for Ubuntu cloud images.
> However, just to be sure you can run `sudo swapoff` on all worker nodes.

## Scheduling a first pod

Upon launching `kubelet`, worker nodes will join the cluster. To verify, run this on your host machine:

```bash
kubectl get nodes -o wide
```

You should see an output like this:

```
NAME      STATUS   ROLES    AGE   VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION      CONTAINER-RUNTIME
control0  Ready    <none>   59s   v1.28.3   192.168.1.11   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic   containerd://1.7.7
control1  Ready    <none>   59s   v1.28.3   192.168.1.12   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic   containerd://1.7.7
control2  Ready    <none>   59s   v1.28.3   192.168.1.13   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic   containerd://1.7.7
worker0   Ready    <none>   59s   v1.28.3   192.168.1.14   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic   containerd://1.7.7
worker1   Ready    <none>   59s   v1.28.3   192.168.1.15   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic   containerd://1.7.7
worker2   Ready    <none>   59s   v1.28.3   192.168.1.16   <none>        Ubuntu 22.04.3 LTS   5.15.0-83-generic   containerd://1.7.7
```

At this point our Kubernetes deployment is starting to become functional.
We should already be able to schedule some pods. Let's try it out:

```bash
kubectl run busybox --image=busybox --command -- sleep 3600
```

Then, run `kubectl get pods -o wide` and you should see an output like this:

```
NAME      READY   STATUS    RESTARTS   AGE    IP         NODE      NOMINATED NODE   READINESS GATES
busybox   1/1     Running   0          6m4s   10.5.0.2   worker1   <none>           <none>
```

### Peeking into pod networking

Just out of curiosity, let's see what the CNI layer actually does. Go to the SSH shell of the worker node
running the pod (use `Ctrl`+`b`,`z` in `tmux` to zoom a single pane) and list network interfaces with
`sudo ip addr`. Among the standard VM network interfaces, you should also see two new interfaces:

```
3: cnio0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 46:ec:cb:d5:8a:ab brd ff:ff:ff:ff:ff:ff
    inet 10.5.0.1/16 brd 10.5.255.255 scope global cnio0
       valid_lft forever preferred_lft forever
    inet6 fe80::44ec:cbff:fed5:8aab/64 scope link
       valid_lft forever preferred_lft forever
4: veth609000bb@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master cnio0 state UP group default
    link/ether 56:cc:ca:be:a7:51 brd ff:ff:ff:ff:ff:ff link-netns cni-408de7e4-b0c4-ad7c-51a3-cf76805b3289
    inet6 fe80::54cc:caff:febe:a751/64 scope link
       valid_lft forever preferred_lft forever
```

`cnio0` is the bridge created by the `bridge` CNI plugin. We can see that it got an IP address from the pod IP range
for this worker node. This way pods can communicate directly with the worker node, and it can serve as a default
routing gateway for pods.

`veth609000bb` is a virtual ethernet interface. An interface like this is created for every pod.
There are some interesting details to note about it:
* `master cnio0` indicates that this interface is connected to the bridge
* `link-netns cni-408de7e4-b0c4-ad7c-51a3-cf76805b3289` indicates that this interface is connected
  to another interface in the network namespace `cni-408de7e4-b0c4-ad7c-51a3-cf76805b3289` 
  (an emulated point-to-point connection). As we can guess, this is going to be the pod's namespace.
* The `@if2` part indicates the corresponding interface in the target network namespace

The virtual interface of the pod is on the other side of the point-to-point connection starting at `veth609000bb`.
We cannot see it now. In order to see it, we must break into the network namespace. Fortunately, this is easy to
do with `ip netns` command:

```bash
sudo ip netns exec cni-408de7e4-b0c4-ad7c-51a3-cf76805b3289 ip addr
```

This command executes an `ip addr` command from within a specified network namespace. The output should look like this:

```
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 3a:9e:9b:36:b7:08 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.5.0.2/16 brd 10.5.255.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::389e:9bff:fe36:b708/64 scope link
       valid_lft forever preferred_lft forever
```

And this is finally what the pod sees. We can see its IP address configured on the `eth0` virtual interface.
The `@if4` and `link-netnsid 0` confirm that this is the "other side" of `veth609000bb`.

In the rudimentary setup that we are using now, pod networking also involves some address translation via
`iptables`. Let's see what's going on there:

```bash
sudo iptables-save
```

We can see a chain and some rules that got created specifically for this particular pod:

```
:CNI-c8c65bddd829b2f007c0887f - [0:0]
-A POSTROUTING -s 10.5.0.2/32 -m comment --comment "name: \"bridge\" id: \"1719d3feb472cc90d9694f539d72fe284ad49ac4dae226e91936e3f80a326828\"" -j CNI-c8c65bddd829b2f007c0887f
-A CNI-c8c65bddd829b2f007c0887f -d 10.5.0.0/16 -m comment --comment "name: \"bridge\" id: \"1719d3feb472cc90d9694f539d72fe284ad49ac4dae226e91936e3f80a326828\"" -j ACCEPT
-A CNI-c8c65bddd829b2f007c0887f ! -d 224.0.0.0/4 -m comment --comment "name: \"bridge\" id: \"1719d3feb472cc90d9694f539d72fe284ad49ac4dae226e91936e3f80a326828\"" -j MASQUERADE
```

These rules effectively enable source NAT (`-j MASQUERADE`) for when this pod communicates with another pod, 
scheduled on another node.

## Routing pod traffic via the host machine

The CNI configures a source NAT for communication between pods, but the destination address is not changed.
This means that pod IP addresses must be routable within the local network where VMs live.

Unfortunately, this is a result of the fact that our network setup in this chapter is very rudimentary.
It is regrettable that cluster-internal IP addresses show up outside the cluster, even on the host machine itself.
We need to remedy this by adding appropriate routes on the host machine:

```bash
for vmid in $(seq 1 6); do
  sudo route -n add -net 10.${vmid}.0.0/16 192.168.1.$((10 + $vmid))
done
```

> [!IMPORTANT]
> Make sure routes are added while at least one VM is running, so that the bridge interface exists.
> Unfortunately, if you stop all the VMs, the routes will be deleted.

A better solution to this problem would be to use a CNI implementation that does not expose
cluster-internal IP addresses to the nodes' network. We'll do that in an 
[extra chapter](08_Simplifying_Network_Setup_with_Cilium.md) where we'll replace the default CNI
plugins with [Cilium](https://cilium.io).

## Authorizing `kube-apiserver` to `kubelet` traffic

As mentioned in [Bootstrapping Kubernetes Security](04_Bootstrapping_Kubernetes_Security.md), some cluster operations
require `kube-apiserver` to call `kubelet`. Those operations include executing commands in pods, setting up port
forwarding, fetching pod logs, etc.

`kubelet` needs to authorize these operations. It does that by... consulting `kube-apiserver`, so we end up with
somewhat of a silly situation where `kube-apiserver` just authorizes itself. Regardless of that, the RBAC rules
for this are not set up automatically. We need to put them in place manually.

On the host machine, invoke:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF
```

Let's verify if it works by executing a command in the running `busybox` pod:

```bash
kubectl exec -it busybox -- sh
```

## `kube-proxy`

The final component we need for a fully configured node is `kube-proxy`, which is responsible for
handling and load balancing traffic destined for Kubernetes 
[Services](https://kubernetes.io/docs/concepts/services-networking/service/).

> [!NOTE]
> In an [extra chapter](08_Simplifying_Network_Setup_with_Cilium.md),
> we'll replace `kube-proxy` with [Cilium](https://cilium.io).

Download and install the binary:

```bash
wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-proxy

chmod +x kube-proxy
sudo cp kube-proxy /usr/local/bin/
```

Configure it:

```bash
sudo mkdir -p /var/lib/kube-proxy/
sudo cp kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.0.0.0/12"
EOF
```

Create `systemd` unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
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
```

Launch it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable kube-proxy
sudo systemctl start kube-proxy
```

### Forcing `iptables` for bridge traffic

There's one more technical hurdle to overcome with `kube-proxy`. By default, it uses `iptables` to set up
Service IP handling and load balancing. Unfortunately, this does not always work well with our bridge-based CNI
configuration and default Linux behaviour.

Here's a problematic scenario:
* Pod A (10.4.0.2), running on `worker0`, connects to Service S (10.32.0.2)
* `kube-proxy` load balancing chooses Pod B (10.4.0.3), also running on `worker0`, as the endpoint for this connection
* `iptables` rules translate the destination Service address (10.32.0.2) to Pod B address (10.4.0.3)
* Pod B receives the connection and responds. The returning packet has source 10.4.0.3 and destination 10.4.0.2
* At this point, `iptables` should translate the source address of the returning packet back to the Service address,
  10.32.0.2. Unfortunately, *this does not happen*. As a result, Pod A receives a packet whose source address does not
  match its original destination address, and the packet is dropped.

Why don't `iptables` fire on the returning packet? The reason is that a packet from 10.4.0.3 to 10.4.0.2 is a
Layer 2 only traffic - it just needs to pass the bridge shared between pods. `iptables`, on the other hand, is a 
Layer 3 thing.

So, overall, this behavior makes sense 🤷. Unfortunately, it breaks our deployment and we have to do something 
about it. Luckily, there's a hack to force Linux to run `iptables` even for bridge-only traffic:

```bash
sudo modprobe br_netfilter
```

Run this on all control and worker nodes. In order to make it persistent, add it to 
`cloud-init/user-data.control` and `cloud-init/user-data.worker`:

```yaml
write_files:
  - path: /etc/modules-load.d/cloud-init.conf
    content: |
      br_netfilter

runcmd:
  - modprobe br_netfilter
```

> [!NOTE]
> We won't need this when we replace `kube-proxy` with [Cilium](https://cilium.io) based solution
> (or any other that doesn't use `iptables`).

### Testing out service traffic

Let's deploy a dummy `Deployment` with 3 replicas of an HTTP echo server, along with a `Service` on top of it:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  labels:
    app: echo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  selector:
    app: echo
  ports:
    - protocol: TCP
      port: 5678
      targetPort: 5678
EOF
```

Let's test it out by running a pod that makes a request to this service. First we'll need the cluster IP of the
service (we don't have a cluster-internal DNS server installed yet). You can easily find out this ip with
`kubectl get svc echo`. In my case, it was 10.32.152.5

Now, let's try to contact this service from within a node. Invoke this on any control or worker node:

```
$ curl http://10.32.152.5:5678
hello-world
```

You should see an output consisting of `hello world` - which indicates that the service works and has returned 
an HTTP response.

### Digging deeper into service load balancing

Now, let's take a peek in what's really going on. The service IP is picked up by `iptables` rules and translated
into the IP of one of the pods implementing the service (randomly). If we go through the output of `iptables-save`
on any of the nodes, we can pick up the relevant parts:

```
*nat
...
-A PREROUTING -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
-A OUTPUT -m comment --comment "kubernetes service portals" -j KUBE-SERVICES
...
-A KUBE-SERVICES -d 10.32.152.5/32 -p tcp -m comment --comment "default/echo cluster IP" -m tcp --dport 5678 -j KUBE-SVC-HV6DMF63W6MGLRDE
...
-A KUBE-SVC-HV6DMF63W6MGLRDE -m comment --comment "default/echo -> 10.4.0.14:5678" -m statistic --mode random --probability 0.33333333349 -j KUBE-SEP-7G5D55VBK7L326G3
-A KUBE-SVC-HV6DMF63W6MGLRDE -m comment --comment "default/echo -> 10.5.0.25:5678" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-HS2AVEBF7XNLG3WC
-A KUBE-SVC-HV6DMF63W6MGLRDE -m comment --comment "default/echo -> 10.6.0.18:5678" -j KUBE-SEP-OQSOJ7ZUSSHWFS7Y
...
-A KUBE-SEP-7G5D55VBK7L326G3 -p tcp -m comment --comment "default/echo" -m tcp -j DNAT --to-destination 10.4.0.14:5678
-A KUBE-SEP-HS2AVEBF7XNLG3WC -p tcp -m comment --comment "default/echo" -m tcp -j DNAT --to-destination 10.5.0.25:5678
-A KUBE-SEP-OQSOJ7ZUSSHWFS7Y -p tcp -m comment --comment "default/echo" -m tcp -j DNAT --to-destination 10.6.0.18:5678
```

The interesting rules are the ones in the `KUBE-SVC-HV6DMF63W6MGLRDE` chain, which are set up so that only one of
them fires, at random, with uniform probability. This is how `kube-proxy` leverages `iptables` to implement
load balancing.

## Summary

In this chapter, we have:
* learned about container runtimes and foundation of Kubernetes networking
* learned about linux namespaces and cgroups, core kernel features that make containers possible
* installed the container runtime, CNI plugins, `kubelet` and `kube-proxy` on control and worker nodes
* tested the cluster by deploying pods and services
* peeked into the inner workings of CNI plugins and `kube-proxy` by inspecting network interfaces and namespaces,
  as well as `iptables` rules that make up the Kubernetes overlay network

Next: [Installing Essential Cluster Services](07_Installing_Essential_Cluster_Services.md)
