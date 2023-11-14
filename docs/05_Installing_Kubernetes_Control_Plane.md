\[ **macOS/ARM64** | [Linux/AMD64](../../linux/docs/05_Installing_Kubernetes_Control_Plane.md) \]

Previous: [Bootstrapping Kubernetes Security](04_Bootstrapping_Kubernetes_Security.md)

# Installing Kubernetes Control Plane

In this chapter we will install the Kubernetes control plane components, i.e. `etcd`, `kube-apiserver`,
`kube-scheduler` and `kube-controller-manager`. As a result, for the first time we'll have a fully functioning
Kubernetes API to talk to.

We will also set up a virtual IP based load balancer for the Kubernetes API on the `gateway` machine, making it
possible to reach the API using a simple domain name `kubernetes.kubenet` (or just `kubernetes`).

On the way, we'll also learn/remind some basic Linux tools and concepts, e.g. `systemd` and IPVS.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Prerequisites](#prerequisites)
- [Quick overview of `systemd`](#quick-overview-of-systemd)
  - [Unit files](#unit-files)
- [Installing core components](#installing-core-components)
  - [Common variables](#common-variables)
  - [Installing `etcd`](#installing-etcd)
  - [Installing `kube-apiserver`](#installing-kube-apiserver)
- [Kubernetes API load balancer](#kubernetes-api-load-balancer)
  - [What is a virtual IP?](#what-is-a-virtual-ip)
  - [Virtual IP on control nodes](#virtual-ip-on-control-nodes)
    - [Persisting the setup with `cloud-init` for control nodes](#persisting-the-setup-with-cloud-init-for-control-nodes)
  - [Setting up the load balancer machine](#setting-up-the-load-balancer-machine)
    - [Adding the virtual IP](#adding-the-virtual-ip)
    - [Playing with `ipvsadm`](#playing-with-ipvsadm)
    - [Setting IPVS properly with `ldirectord`](#setting-ipvs-properly-with-ldirectord)
- [Installing the remaining control plane components](#installing-the-remaining-control-plane-components)
  - [Installing `kube-controller-manager`](#installing-kube-controller-manager)
  - [Installing `kube-scheduler`](#installing-kube-scheduler)
- [Summary](#summary)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Make sure you have completed all the previous chapters, your VMs are [running](03_Launching_the_VM_Cluster.md#a-script-to-launch-them-all) 
and have all the certificates, keys and kubeconfigs [deployed](04_Bootstrapping_Kubernetes_Security.md#distributing-certificates-and-keys).

## Quick overview of `systemd`

Ubuntu uses [`systemd`](https://systemd.io/) as the "init system", i.e. a software suite that 
manages services/daemons, starting them during system boot, making sure they run in the correct order, etc.
We'll be using `systemd` throughout this chapter to run Kubernetes components. Because of that, let's have a quick
theoretical introduction into `systemd` in order to make things less magic.

### Unit files

In order to register a new service in the system and make it run on system boot, a _unit_ file needs to be created,
usually in the `/etc/systemd/system` directory.
Typically, unit files are managed by a package manager like [APT](https://en.wikipedia.org/wiki/APT_(software)). 
However, since we are doing things _the hard way_, we will be writing them by hand.

A unit file has a _type_ (corresponding to its file extension), that determines the type of entity it defines.
In this guide, we are only interested in the `.service` type, which indicates a runnable service definition.

`systemd` also talks about _targets_, which are synchronization points, effectively used to define dependencies between
units and force their initialization order.

A minimal service-type unit file could look like this:

```ini
[Unit]
Description=My custom service
After=network.target

[Service]
ExecStart=/usr/local/bin/myservice
Restart=always

[Install]
WantedBy=multi-user.target
```

which defines a service that requires the `network` target to be completed before running, and installs itself
as a dependency of the `multi-user` target.

`systemd` is associated with a command line program, `systemctl`, which can be used to reload unit definitions,
start, stop, restart, inspect services, etc.

## Installing core components

Let's start installing control plane components. In order to do this simultaneously on all control nodes, you can use 
`tmux` with pane synchronization, as [described](03_Launching_the_VM_Cluster.md#synchronizing-panes) elsewhere. 
Note that the way we have [set up](03_Launching_the_VM_Cluster.md#connecting-with-ssh) a `tmux`session with SSH connections to all VMs was designed specifically 
for that purpose.

> [!NOTE]
> This guide suggests running all commands by hand (via `tmux`) so that you can see and verify every step.
> However, the guide repository also contains scripted version that you can reuse later.

> [!IMPORTANT]
> The guide assumes that all commands are run from default user (`ubuntu`) home directory, which contains all the 
> uploaded certificates, keys and kubeconfigs.

### Common variables

Let's define some reusable shell variables to use throughout this chapter:

```bash
arch=arm64

etcd_version=3.5.9
k8s_version=1.28.3

vmaddr=$(ip addr show enp0s1 | grep -Po 'inet \K192\.168\.1\.\d+')
vmname=$(hostname -s)
```

### Installing `etcd`

Let's download the `etcd` binary, unpack it and copy into appropriate system directory:

```bash
etcd_archive=etcd-v${etcd_version}-linux-${arch}.tar.gz
wget -q --show-progress --https-only --timestamping \
  "https://github.com/etcd-io/etcd/releases/download/v${etcd_version}/$etcd_archive"
tar -xvf $etcd_archive
sudo cp etcd-v${etcd_version}-linux-${arch}/etcd* /usr/local/bin
```

Set up `etcd` data and configuration directories, then install all the necessary certificates and keys:

```bash
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd/
sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/
```

Create a `systemd` unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
Environment=ETCD_UNSUPPORTED_ARCH=${arch}
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
```

It's not worth explaining in detail *all* the options from the above file. The security related ones are a direct consequence
of the security assumptions from the [previous chapter](04_Bootstrapping_Kubernetes_Security.md). The other ones simply
tell the `etcd` cluster how it should initialize itself. Exhaustive reference can be found
[here](https://etcd.io/docs/v3.5/op-guide/configuration/).

Reload `systemd` unit definitions and start `etcd` service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
```

Verify if the service is running:

```bash
systemctl status etcd.service
```

If something is wrong, you can look up logs:

```bash
journalctl -u etcd.service
```

You can also verify if the cluster is running properly by listing cluster memebers with the following command:

```bash
sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem
```

The output should look similar to this:

```
91bdf612a6839630, started, control0, https://192.168.1.11:2380, https://192.168.1.11:2379, false
bb39bdb8c49d4b1b, started, control2, https://192.168.1.13:2380, https://192.168.1.13:2379, false
dc0336cac5c58d30, started, control1, https://192.168.1.12:2380, https://192.168.1.12:2379, false
```

### Installing `kube-apiserver`

Download the binary and copy it to `/usr/local/bin`:

```bash
wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-apiserver"
chmod +x kube-apiserver
sudo cp kube-apiserver /usr/local/bin
```

Create a configuration directory for `kube-apiserver` and copy all the necessary security-related files into it:

```bash
sudo mkdir -p /var/lib/kubernetes/
sudo cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
  service-account-key.pem service-account.pem \
  encryption-config.yaml /var/lib/kubernetes/
```

Create a `systemd` unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
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
```

Again, configuration options are not worth discussing in detail, but there are some interesting things to note:
* the security related options (certs, etc.) simply reflect the assumptions made in the
  [previous chapter](04_Bootstrapping_Kubernetes_Security.md).
* the `--service-cluster-ip-range` specifies the range of IPs assigned to
  [Kubernetes Services](https://kubernetes.io/docs/concepts/services-networking/service/). These IPs will only
  be visible from within the cluster (i.e. pods).
* the `--service-node-port-range` specifies the range of ports used for 
  [`NodePort` Services](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport)

Exhaustive option reference can be found [here](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/).

Enable and run it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver
sudo systemctl start kube-apiserver
```

You can verify if `kube-apiserver` is running correctly with `systemctl status` or by invoking its health-check API:

```bash
curl -v --cacert /var/lib/kubernetes/ca.pem https://127.0.0.1:6443/healthz
```

> [!NOTE]
> `curl` may not be installed by default. You can install it manually with `sudo apt install curl`, but you can also
> make `cloud-init` do this automatically for you, as 
> [described previously](02_Preparing_Environment_for_a_VM_Cluster.md#installing-apt-packages).

## Kubernetes API load balancer

The Kubernetes API server is now running, and we can try using it. Unfortunately, this would require referring to
one of the control node IPs/addresses directly, rather than using a single, uniform IP and name for the entire
API. We have configured all our kubeconfigs to use `https://kubernetes:6443` as the API url.
The name `kubernetes` is [configured in the DNS server](02_Preparing_Environment_for_a_VM_Cluster.md#dns-server-configuration)
to resolve to a mysterious, unassigned address 192.168.1.21. This is a virtual IP, and it is now time to properly
set it up.

### What is a virtual IP?

A virtual IP address is an address within a local network that is not bound to a single machine but is rather
recognized by multiple machines as their own. All the packets destined for the virtual IP must go through a load
balancer (the `gateway` VM, in our case) which distributes them across machines that actually handle them.

> [!NOTE]
> Only the incoming packets go through the load balancer, 
> the returning packets go directly from destination to source.

This simple load balancing technique is implemented in the Linux kernel by the IPVS module, 
and has the advantage of not involving any address translation or tunnelling 
(although it can be configured to do so).

### Virtual IP on control nodes

First, we need to make sure all the control nodes recognize the virtual IP 192.168.1.21 as their own.
At first, this seems very easy to do: just assign this address statically to one of the network interfaces on the VM.
For example, we could do something like this:

```bash
sudo ip addr add 192.168.1.21/32 dev enp0s1
```

However, we have a problem: an IP address conflict in the network. If anyone on the local network asks (via ARP) who has
this address, all control nodes will respond. This is bad. We actually want only the load balancer machine
to publicly admit the possession of this virtual IP. In order to make sure that control nodes never announce this
IP as their own, we need to use some tricks:

First, assign the address on loopback interface rather than virtual ethernet:

```bash
sudo ip addr add 192.168.1.21/32 dev lo
```

This is not enough, though. By default, Linux considers all the addresses from all interfaces for ARP requests 
and responses. We need some more twiddling in kernel network options:

```bash
sudo sysctl net.ipv4.conf.all.arp_ignore=1
sudo sysctl net.ipv4.conf.all.arp_announce=2
```

Without going into too many details, the first option (`arp_ignore`) makes sure that the virtual IP never appears
in ARP _responses_ sent from control nodes, while the second option (`arp_announce`) ensures that it does not appear 
in ARP _requests_. For more details, see the [Linux kernel documentation](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt).

Note how these options are global - they are not bound to any specific IP or interface. They work for the virtual IP
specifically because it is configured on a different interface (loopback) than the interface where all the ARP traffic
happens (virtual ethernet).

Let's test this setup by pinging the virtual IP from the host machine:

```bash
$ ping 192.168.1.21
PING 192.168.1.21 (192.168.1.21): 56 data bytes
ping: sendto: Host is down
ping: sendto: Host is down
Request timeout for icmp_seq 0
```

If you see failures like the ones above, our setup worked.

#### Persisting the setup with `cloud-init` for control nodes

It would be nice for `cloud-init` to do all this setup for us. Otherwise, it will be lost upon every VM reboot.

In order to configure the virtual IP as a static one, we must use the `network-config` file for `cloud-init`.
Edit the `cloud-init/network-config.control` template file that 
[we have set up earlier](02_Preparing_Environment_for_a_VM_Cluster.md#impromptu-bash-templating-for-cloud-init-files)
and add the following content:

```yaml
network:
  version: 2
  ethernets:
    lo:
      match:
        name: lo
      addresses: [192.168.1.21/32]
    eth:
      match:
        name: enp*
      dhcp4: true
```

> [!NOTE]
> Even though we only want to modify the loopback interface, we must include a default entry for the virtual
> ethernet with DHCP enabled. Otherwise, it will not be configured.

> [!NOTE]
> This is the same YAML format as the one used by Ubuntu's [netplan](https://netplan.io/) utility.

In order to persist the ARP-related kernel options, add this to `cloud-init/user-data.control`:

```yaml
write_files:
  - path: /etc/sysctl.d/50-vip-arp.conf
    content: |
      net.ipv4.conf.all.arp_announce = 2
      net.ipv4.conf.all.arp_ignore = 1
runcmd:
  - sysctl -p /etc/sysctl.d/50-vip-arp.conf
```

### Setting up the load balancer machine

The control nodes are properly provisioned with the virtual IP, so now it's time to set up the load balancer itself.

First, make sure the following packages are installed on the `gateway machine`:

```bash
sudo apt install ipvsadm ldirectord
```

...or via `cloud-init/user-data.gateway`:

```yaml
packages:
  - ipvsadm
  - ldirectord
```

#### Adding the virtual IP

Just like the control nodes, the `gateway` machine must recognize the virtual IP as its own. Unlike for control
nodes, we want the `gateway` VM to publicly admit the ownership of this address with ARP. Therefore, there is no need
to configure it on loopback (although it would work too) nor to change any kernel network options.

```bash
sudo ip addr add 192.168.1.21/32 dev <interface-name>
```

...or in `cloud-init/network-config.gateway`:

```yaml
network:
  version: 2
  ethernets:
    eth:
      match:
        name: enp*
      addresses: [192.168.1.21/32]
      dhcp4: true
```

#### Playing with `ipvsadm`

`ipvsadm` is the utility that allows us to configure a load-balanced virtual IP within the Linux kernel.
Ultimately, we won't be using it directly, and we'll allow this to be done by an userspace utility, `ldirectord`.
However, just for educational purposes, let's try to do it by hand.

On the `gateway` machine, invoke:

```bash
sudo ipvsadm -A -t 192.168.1.21:6443 -s rr
sudo ipvsadm -a -t 192.168.1.21:6443 -r 192.168.1.11:6443 -g
sudo ipvsadm -a -t 192.168.1.21:6443 -r 192.168.1.12:6443 -g
sudo ipvsadm -a -t 192.168.1.21:6443 -r 192.168.1.13:6443 -g
```

The `-s rr` specifies load balancing strategy (round-robin) and the `-g` option indicates direct routing
(i.e. no tunnelling or NAT).

You can now verify it using `sudo ipvsadm -L`:

```
$ sudo ipvsadm -L
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  gateway:6443 rr
  -> control0.kubevms:6443        Route   1      0          0
  -> control1.kubevms:6443        Route   1      0          0
  -> control2.kubevms:6443        Route   1      0          0
```

This should be enough for the load balancing to work. Let's try contacting the Kubernetes API via the virtual IP,
from the host machine:

```bash
curl -v --cacert auth/ca.pem https://kubernetes:6443/healthz
```

You should get a successful (200 OK) response.

We can also try using `kubectl` for the first time to contact our nascent Kubernetes deployment:

```bash
kubectl get namespaces
```

You should see an output like this if everything works fine:

```
NAME              STATUS   AGE
default           Active   159m
kube-node-lease   Active   159m
kube-public       Active   159m
kube-system       Active   159m
```

Yay! This is the first time ever we have actually used the Kubernetes API!

#### Setting IPVS properly with `ldirectord`

Using `ipvsadm` directly works, but it has the following problems:
* the configuration is not persistent, it will disappear after reboot
* control nodes are not monitored, i.e. when a control node goes down, it will not be excluded from load balancing

The second problem is especially pressing and absolutely unacceptable if we want our deployment to be as close to
a production one as possible. We need to make sure that when a control node goes down, the load balancer detects this
and stops routing traffic to it.

Fortunately, there are many simple user-space tools that can do this for us. They use IPVS under the hood and additionally 
monitor target machines in userspace. If they detect that any of them is down, IPVS is dynamically reconfigured to 
exclude a faulty route.

The tool of our choice is `ldirectord` - an old and simple utility, but more than enough for our purposes.
Instead of invoking `ipvsadm` manually, we define the load balanced service in a file:

```bash
cat <<EOF | sudo tee /etc/ha.d/ldirectord.cf
checktimeout=5
checkinterval=1
autoreload=yes
quiescent=yes

virtual=192.168.1.21:6443
    servicename=kubernetes
    real=192.168.1.11:6443 gate
    real=192.168.1.12:6443 gate
    real=192.168.1.13:6443 gate
    scheduler=wrr
    checktype=negotiate
    service=https
    request="healthz"
    receive="ok"
EOF
```

The three last lines of this configuration specify how target nodes are monitored: by issuing an HTTPS request
on `/healthz` path and expecting an `ok` response.

There's one last problem: we are using HTTPS for health checks but this machine does not trust our Kubernetes API
certificate, so health checks fail. Unfortunately, there is no way to configure a trusted CA within `ldirectord`
configuration, so we have no choice but make it trusted in the whole system:

```bash
sudo cp ca.pem /usr/local/share/ca-certificates/kubernetes-ca.crt
sudo update-ca-certificates
```

We can also provision this certificate via `cloud-init/user-data.gateway`. Add the following section to it:

```yaml
ca_certs:
  trusted:
    - |
$(sed "s/^/      /g" "$dir/auth/ca.pem")
```

> [!NOTE]
> The ungodly `sed` incantation is responsible for adding indent to the contents of the `ca.pem` file being pasted,
> so that YAML's significant indentation rules are satisfied.

Make sure `ldirectord` is restarted after config changes:

```bash
sudo systemctl restart ldirectord
```

Then check `sudo ipvsadm -L` again. You should see something like this:

```
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  gateway:6443 wrr
  -> control0.kubevms:6443        Route   1      0          0
  -> control1.kubevms:6443        Route   1      0          0
  -> control2.kubevms:6443        Route   1      0          0
```

The notable difference from the manual config is that now we are using the `wrr` strategy (weighted round-robin).
Every target node has weight 1 assigned, meaning that they are treated equally. When `ldirectord` detects a node
down, it sets its weight to 0. We can test this by stopping `kube-apiserver` on one of the control nodes, e.g. on
`control0`:

```bash
sudo systemctl stop kube-apiserver
```

and you should see this reflected in the `ipvsadm -L` output:

```
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  gateway:6443 wrr
  -> control0.kubevms:6443        Route   0      0          0
  -> control1.kubevms:6443        Route   1      0          0
  -> control2.kubevms:6443        Route   1      0          0
```

Great! This concludes the setup of the Kubernetes API server.

## Installing the remaining control plane components

Let's go back to control nodes. We have two more things to install on them:
* `kube-controller-manager`
* `kube-scheduler`

### Installing `kube-controller-manager`

Download the binary and install it in appropriate system dir:

```bash
wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-controller-manager"
chmod +x kube-controller-manager
sudo cp kube-controller-manager /usr/local/bin
```

Set up `kube-controller-manager`'s kubeconfig:

```bash
sudo cp kube-controller-manager.kubeconfig /var/lib/kubernetes/
```

Create a `systemd` unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.0.0.0/12 \\
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
```

Some things to note from the options:
* As with all other components, security-related options reflect the assumptions made in the
  [previous chapter](04_Bootstrapping_Kubernetes_Security.md)
* The `--cluster-signing-cert-file` and `--cluster-signing-key-file` are related to a feature that was not yet
  mentioned - an [API to dynamically sign certificates](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/)
* The `--service-cluster-ip-range` must be the same as in `kube-apiserver`
* The `--cluster-cidr` specifies IP range for pods in the cluster. We will discuss this in more detail in
  the [next chapter](06_Spinning_up_Worker_Nodes.md#splitting-pod-ip-range-between-nodes)

Launch it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable kube-controller-manager
sudo systemctl start kube-controller-manager
```

### Installing `kube-scheduler`

Download the binary and install it in appropriate system dir:

```bash
wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v${k8s_version}/bin/linux/${arch}/kube-scheduler"
chmod +x kube-scheduler
sudo cp kube-scheduler /usr/local/bin
```

Set up `kube-scheduler`'s configuration:

```bash
sudo cp kube-scheduler.kubeconfig /var/lib/kubernetes/
sudo mkdir -p /etc/kubernetes/config

cat <<EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1beta3
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF
```

Create a `systemd` unit file:

```bash
cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
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
```

Launch it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable kube-scheduler
sudo systemctl start kube-scheduler
```

## Summary

In this chapter, we have:
- installed all the control plane components of a proper Kubernetes deployment (except `cloud-controller-manager`)
- set up an IPVS based load balancer for the Kubernetes API

At this point we have a fully functional Kubernetes API, but there aren't yet any worker nodes to schedule actual work.

Next: [Spinning up Worker Nodes](06_Spinning_up_Worker_Nodes.md)
