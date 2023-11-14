\[ **macOS/ARM64** | [Linux/AMD64](../../linux/docs/07_Installing_Essential_Cluster_Services.md) \]

Previous: [Spinning up Worker Nodes](06_Spinning_up_Worker_Nodes.md)

# Installing Essential Cluster Services

We have reached an important milestone: we have fully configured all the VMs in our Kubernetes cluster.
No more direct access to the VMs should be necessary to perform further setup. From on now, we should be able to
do everything using `kubectl`, and other tools that use Kubernetes API under the hood.

However, in order to run typical workloads (i.e. a web server, a database, etc.), we need to install some
essential services:

* Cluster-internal DNS server \
  This DNS server will allow pods in the cluster to refer to services and other pods using their names 
  rather than IPs.
* Persistent volume dynamic provisioner \
  Workloads that use persistent storage (e.g. databases) typically store their data on volumes backed by
  some external storage (e.g. a disk array, cloud persistent disk etc.). Worker nodes' disk drives should
  generally not be used for that purpose, because pods can be moved between nodes. We need something to simulate
  external storage in our deployment.
* Service load balancer \
  Kubernetes Services can be configured with type `LoadBalancer`, making them have an external IP and become available 
  to the external world via a load balancer (typically, a cloud load balancer). We need something to simulate this
  in our local deployment as well.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**  *generated with [DocToc](https://github.com/thlorenz/doctoc)*

- [Prerequisites](#prerequisites)
- [`helm`](#helm)
- [`coredns`](#coredns)
- [NFS dynamic provisioner](#nfs-dynamic-provisioner)
  - [Setting up NFS on the host machine](#setting-up-nfs-on-the-host-machine)
  - [Installing NFS client on worker nodes](#installing-nfs-client-on-worker-nodes)
  - [Installing the dynamic provisioner](#installing-the-dynamic-provisioner)
  - [Testing the dynamic provisioner](#testing-the-dynamic-provisioner)
- [MetalLB](#metallb)
  - [Testing MetalLB](#testing-metallb)
- [Summary](#summary)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Prerequisites

Make sure you have completed the previous chapters and have all the necessary
[packages](00_Introduction.md#software) installed.

## `helm`

Installing a service or workload on a Kubernetes cluster ultimately boils down to creating an (often large) set
of Kubernetes resources with the Kubernetes API, and waiting for the cluster to synchronize itself to reflect
the desired state expressed by these resources.

One of the most popular tools to automate this process is [`helm`](https://helm.sh/). Helm bundles kubernetes resources
in packages called _charts_. A chart is conceptually similar to a DEB or RPM package, except the "operating system"
that it is installed on is the entire Kubernetes cluster. Upon installation, a chart can be customized with parameters, 
called _values_. This way `helm` can be used to install an entire distributed service with a single command.
There are several public chart repositories available, and we can choose from a plethora of pre-packaged charts for
popular software.

Helm is a pure client utility. It runs fully on the client machine - the same where you would invoke plain `kubectl`.
Kubernetes itself does not care or know that something was installed using Helm.

## `coredns`

[`coredns`](https://coredns.io/) will serve as the cluster-internal DNS service. Let's install it with `helm`:

```bash
helm repo add coredns https://coredns.github.io/helm
helm install -n kube-system coredns coredns/coredns --set service.clusterIP=10.32.0.10 --set replicaCount=2
```

> [!IMPORTANT]
> Note the `--set service.clusterIP=10.32.0.10` option. This must be consistent with the DNS address specified
> previously in [`kubelet`](06_Spinning_up_Worker_Nodes.md#kubelet) configuration.

Let's see if it works by inspecting pods with `kubectl -n kube-system get pods -o wide`.
`coredns` may take some time to start. Ultimately, you should see something similar to this:

```
NAME                              READY   STATUS    RESTARTS   AGE   IP         NODE      NOMINATED NODE   READINESS GATES
coredns-coredns-967ddbb6d-5wtdr   1/1     Running   0          80s   10.0.0.2   worker0   <none>           <none>
coredns-coredns-967ddbb6d-j5m4z   1/1     Running   0          80s   10.2.0.2   worker2   <none>           <none>
```

You can also look at the `Service` object with `kubectl -n kube-system get services`:

```
NAME              TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)         AGE     SELECTOR
coredns-coredns   ClusterIP   10.32.0.10   <none>        53/UDP,53/TCP   4m38s   app.kubernetes.io/instance=coredns,app.kubernetes.io/name=coredns,k8s-app=coredns
```

You can also run `helm install` with the `--wait` option.

## NFS dynamic provisioner

The next thing we need is something to simulate external storage.

When a pod needs persistent storage, it defines a `PersistentVolumeClaim`, optionally also specifying a
`StorageClass`. Storage classes typically correspond to different throughput, latency, replication characteristics and
price of the underlying storage. The `PersistentVolumeClaim` is then picked up by a _dynamic provisioner_, which
creates a `PersistentVolume` for it. The way it happens and the way this volume is mounted to the requesting pod is
a pure implementation detail. Kubernetes hides this under an abstraction called 
[Container Storage Interface](https://github.com/container-storage-interface/spec/blob/master/spec.md) (CSI).

Our implementation of persistent storage will be provided by
[`nfs-subdir-external-provisioner`](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner).

Using it, we'll expose a single directory on the host machine via NFS. The dynamic provisioner will then create
a subdirectory for every `PersistentVolume`.

### Setting up NFS on the host machine

In the toplevel project directory (`kubenet`) on the host machine, create a directory to be exported via NFS:

```bash
mkdir nfs-pvs
```

Now, let's append an entry to `/etc/exports` file to export this directory:

```bash
cat <<EOF | sudo tee -a /etc/exports
$(pwd)/nfs-pvs -network 192.168.1.0 -mask 255.255.255.0 -maproot=$(whoami) -alldirs
EOF
```

> [!NOTE]
> This command is assumed to be invoked from the parent directory of `nfs-pvs` (i.e. `kubenet`).
> Also note that this line is *appended* to `/etc/exports` (the `-a` option) so be careful not to invoke it multiple
> times. If you need to correct something, just edit the file with `sudo nano` or `sudo vim`.

Enable NFS with:

```bash
sudo nfsd enable
```

(or use `sudo nfsd update` if `nfsd` is already enabled)

### Installing NFS client on worker nodes

In the beginning of this chapter, it was claimed that we won't need to configure VMs directly anymore.
It was a bit of a lie. Even though we're going to install the dynamic provisioner using `helm`, it won't work if
worker machines don't have an NFS client installed. So, go back to SSH for worker nodes and invoke:

```bash
sudo apt install nfs-common
```

or persist it in `cloud-init/user-data.worker`:

```yaml
packages:
  - nfs-common
```

### Installing the dynamic provisioner

Install the dynamic provisioner using `helm`:

```bash
helm repo add nfs-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install -n kube-system nfs-provisioner nfs-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=192.168.1.1 \
  --set nfs.path=$(pwd)/nfs-pvs \
  --set storageClass.defaultClass=true
```

> [!NOTE]
> This is assumed to be invoked from the parent directory of `nfs-pvs` (i.e. `kubenet`).

To test if it worked, let's check `StorageClass` definitions with `kubectl get storageclass`.
The output should be:

```
NAME                   PROVISIONER                                                     RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
nfs-client (default)   cluster.local/nfs-provisioner-nfs-subdir-external-provisioner   Delete          Immediate           true                   14s
```

### Testing the dynamic provisioner

Let's see if external storage works by installing something that needs it.
In our case, this will be [Redis](https://redis.io/):

```bash
helm install redis oci://registry-1.docker.io/bitnamicharts/redis --set replica.replicaCount=2
```

Redis will take a while to spin up. You can see it happening with `kubectl get pod -w`. Ultimately, if everything is
fine, you should see something similar to:

```
redis-master-0     1/1     Running   0             80s   10.2.0.3   worker2   <none>           <none>
redis-replicas-0   1/1     Running   0             80s   10.1.0.3   worker1   <none>           <none>
redis-replicas-1   1/1     Running   0             38s   10.0.0.4   worker0   <none>           <none>
```

Let's see persistent volumes with `kubectl get persistentvolume`

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                                 STORAGECLASS   REASON   AGE
pvc-8e5f64b5-af57-4fe5-9ec8-8342c1914bb8   8Gi        RWO            Delete           Bound    default/redis-data-redis-replicas-1   nfs-client              4m31s
pvc-93c2115d-a6f7-4e59-a41b-fbef620613f3   8Gi        RWO            Delete           Bound    default/redis-data-redis-replicas-0   nfs-client              5m8s
pvc-9de54e35-b9c2-48fa-b92a-c365ef3dff5e   8Gi        RWO            Delete           Bound    default/redis-data-redis-master-0     nfs-client              5m8s
```

Finally, let's see them in the NFS exported directory:

```
$ ls -l nfs-pvs
total 0
drwxrwxrwx  3 rjghik  staff   96 Oct 26 17:51 default-redis-data-redis-master-0-pvc-9de54e35-b9c2-48fa-b92a-c365ef3dff5e
drwxrwxrwx  4 rjghik  staff  128 Oct 26 17:52 default-redis-data-redis-replicas-0-pvc-93c2115d-a6f7-4e59-a41b-fbef620613f3
drwxrwxrwx  4 rjghik  staff  128 Oct 26 17:52 default-redis-data-redis-replicas-1-pvc-8e5f64b5-af57-4fe5-9ec8-8342c1914bb8
```

## MetalLB

Kubernetes Services can be [exposed to the external world](https://kubernetes.io/docs/concepts/services-networking/service/#loadbalancer)
using load balancers. In addition to cluster-internal IP, a Service of type `LoadBalancer` gets assigned an _external IP_.
In a real cloud environment, traffic to this external IP is handled by a load balancer, before being forwarded to
Kubernetes cluster. Exactly how `LoadBalancer`-type services are synchronized with the load balancer is an implementation 
detail specific to a particular cloud platform and its integration with Kubernetes.

We don't have a true load balancer in our local deployment, but we can simulate it. In fact, we have already done it
for the Kubernetes API - the `gateway` VM serves this purpose. Can we do something similar for `LoadBalancer`-type
services?

In principle, we could imagine an implementation that would configure Service external IPs as virtual IPs on the
`gateway` machine, just like we have done it manually for the Kubernetes API. Unfortunately, there does not seem to
be an implementation like this available (likely because this is a very "educational" scenario that doesn't happen
in the real world very often).

We'll use a different method instead, implemented by the [MetalLB](https://metallb.universe.tf/) project.
In this approach, one of the worker nodes takes the role of a load balancer and assumes the ownership of external IPs
of `LoadBalancer`-type services. In case this node fails, another node takes over its job. This way the load-balancing 
node is not a single point of failure.

Let's install `metallb`:

```bash
helm repo add metallb https://metallb.github.io/metallb
helm install -n kube-system metallb metallb/metallb --wait --timeout 5m
```

Now we need to configure it with some additional Kubernetes resources:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lb-pool
  namespace: kube-system
spec:
  addresses:
    - 192.168.1.30-192.168.1.254
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lb-l2adv
  namespace: kube-system
spec:
  ipAddressPools:
    - lb-pool
EOF
```

Note the allocated range for Service external IPs (192.168.1.30-254). It's important for this range to be within
the local network of the VMs, but outside the DHCP-assignable range. This is why we have previously
[configured](02_Preparing_Environment_for_a_VM_Cluster.md#dhcp-server-configuration) it to be very narrow.

### Testing MetalLB

Let's create a simple HTTP echo service, similar to the one from 
[previous chapter](06_Spinning_up_Worker_Nodes.md#testing-out-service-traffic):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-lb
  labels:
    app: echo-lb
spec:
  replicas: 3
  selector:
    matchLabels:
      app: echo-lb
  template:
    metadata:
      labels:
        app: echo-lb
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
  name: echo-lb
spec:
  type: LoadBalancer
  selector:
    app: echo-lb
  ports:
    - protocol: TCP
      port: 5678
      targetPort: 5678
EOF
```

After a while, you should see an external IP assigned to it:

```bash
$ kubectl get svc echo-lb
NAME      TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)          AGE
echo-lb   LoadBalancer   10.32.89.174   192.168.1.30   5678:32479/TCP   72s
```

Try connecting to it from your host machine:

```bash
$ curl http://192.168.1.30:5678
hello-world
```

And this way the service has become available from outside the cluster!

## Summary

In this chapter we, have installed essential services necessary to run typical workloads:
* a cluster-internal DNS server
* a dynamic storage provisioner
* a load balancer for Kubernetes services

Next: [Siplifying Network Setup with Cilium](08_Simplifying_Network_Setup_with_Cilium.md) (optional)
