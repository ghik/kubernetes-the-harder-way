# Installing Kubernetes Control Plane

We've reached the part where we can start installing some actual Kubernetes.

Three of the VMs prepared in the previous chapters (`control0`, `control1`, and `control2`) will run
the [Kubernetes control plane](https://kubernetes.io/docs/concepts/overview/components/#control-plane-components).
The control plane governs the global state of the cluster, by maintaining the database of Kubernetes
resources, exposing the API to manipulate them, and making sure that whatever is described in various
Kubernetes resources, is reflected in reality (e.g. by scheduling pods).

### Credits

This chapter is largely based on [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
guide, but is updated for newer versions of Kubernetes and its components, and provides more explanations
rather than pure install instructions.

## Control plane components

Control plane nodes run several separate services that make up the control plane:
* `etcd` - a highly reliable and consistent, distributed database for Kubernetes resources
* `kube-apiserver` - the Kubernetes API server
* `kube-scheduler` - responsible for assigning newly created pods to worker nodes
* `kube-controller-manager` - runs Kubernetes [controllers](https://kubernetes.io/docs/concepts/architecture/controller/)
* `cloud-controller-manager` - provides integration with a cloud provider, specific to that provider
  (it is therefore not used in this guide)
