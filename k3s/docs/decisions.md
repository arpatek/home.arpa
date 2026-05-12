# Decisions

The design choices made while building this k3s cluster.

## k3s over full Kubernetes (kubeadm)

**Decision.** The cluster runs k3s, not a full Kubernetes distribution installed via kubeadm or another tool.

**Alternatives considered.**

_kubeadm._ The official tool for bootstrapping Kubernetes clusters.
Gives full control over every component.
Requires separately installing and configuring a container runtime, CNI, ingress controller, and DNS.
More educational at the individual component level, but significant operational overhead for a homelab.

_kind / minikube._ Local Kubernetes environments designed for development and testing.
Run on a single machine, not suitable for multi-node or persistent workloads.

_Talos Linux._ An immutable OS designed exclusively for running Kubernetes.
Opinionated, secure by default, excellent for production.
Steep learning curve — every aspect of the OS is managed via a Kubernetes-like API.
More than needed for this stage.

**Why k3s.**

k3s is fully Kubernetes-conformant.
Anything that runs on full Kubernetes runs on k3s — the API is the same, the manifests are the same, the kubectl commands are the same.
The learning that happens on this cluster transfers directly to production Kubernetes environments.

The operational overhead is lower.
k3s installs as a single binary, manages its own containerd and CNI, and starts immediately.
This means more time learning Kubernetes concepts and less time debugging component installation.

The resource footprint matters.
The cluster runs on VMs sharing a single hypervisor with other lab services.
k3s's lower overhead (less RAM consumed by control plane components) leaves more headroom for actual workloads.

## Cloud-init template over ISO installation

**Decision.** The three cluster VMs were provisioned from a Debian 13 cloud-init template cloned in Proxmox, not installed from the netinstall ISO.

**Alternatives considered.**

_ISO installation._ Install Debian manually on each VM via the netinstall ISO.
This is how the other lab VMs (prod-ipa-0, prod-git-0, prod-mon-0) were installed.
Works, but requires interactive console sessions for each VM.

**Why cloud-init template.**

Three VMs with identical base configuration is exactly the use case cloud-init was designed for.
Create one template, clone it three times, and inject per-VM configuration (hostname, IP, SSH key) via cloud-init metadata.
The entire provisioning process is scriptable — see [proxmox/provision-k3s.sh](../../proxmox/provision-k3s.sh).

This also establishes the pattern for future cluster expansion.
Adding a fourth worker node means cloning the template and running one `qm clone` + `qm set` sequence.

It maps directly to how Terraform and Ansible provision infrastructure.
Terraform's Proxmox provider uses the same clone-and-configure model.
Learning the qm CLI workflow is learning the mental model that Terraform implements.

## Control-plane-only master (tainted)

**Decision.** The master node is tainted `node-role.kubernetes.io/control-plane=:NoSchedule`.
No workloads are scheduled on it.

**Alternatives considered.**

_Master also runs workloads._ A 3-node cluster with all nodes running pods gives more total workload RAM.
Common in small homelab clusters.

**Why control-plane-only.**

The two workers have 4GB RAM each — 8GB total workload capacity.
The current workload (`arpatek.dev` and supporting services) fits comfortably in that space.

The control-plane-only pattern is what production Kubernetes environments use.
Running the cluster this way means the operational model (master = control plane, workers = workloads) is accurate and transferable.

Mixing control plane and workloads on the master creates a failure scenario where a misbehaving workload can starve the API server of resources and destabilize the whole cluster.
On a homelab this is unlikely but avoidable.

## Flannel CNI over Calico or Cilium

**Decision.** Flannel is the CNI — the default bundled with k3s.

**Alternatives considered.**

_Calico._ Feature-rich CNI with native NetworkPolicy enforcement, BGP routing support, and fine-grained observability.
Worth adopting if NetworkPolicy enforcement or more complex routing becomes a requirement.

_Cilium._ eBPF-based CNI with advanced observability and security features.
Higher resource overhead, steeper learning curve.
More appropriate when the goal is learning eBPF or building a production-grade network security posture.

**Why Flannel.**

For this cluster's workload (`arpatek.dev`), CNI selection has no practical impact on day-to-day operation.
Flannel is simple, well-understood, and maintained by the Kubernetes community.
It handles pod-to-pod routing across nodes correctly, which is all that's needed here.
Using Calico or Cilium would be optimizing a dimension that isn't a bottleneck.

## Traefik ingress over nginx

**Decision.** Traefik is the ingress controller — the default bundled with k3s.

**Alternatives considered.**

_nginx ingress controller._ The most common Kubernetes ingress controller.
More widespread in tutorials and production environments.

**Why Traefik.**

Traefik comes preconfigured in k3s with no additional setup.
For exposing `arpatek.dev` and `git.arpatek.dev` over HTTPS, Traefik handles the requirements without extra configuration.

If nginx-specific behavior becomes necessary (e.g. fine-grained lua scripting, specific nginx annotations), switching ingress controllers is a contained change — it affects only the Ingress resources and the controller deployment, not the applications themselves.

## IPA enrollment for all cluster nodes

**Decision.** All three k3s nodes are enrolled as FreeIPA clients.

**Why.**

Consistency with the rest of the lab.
Every production VM is IPA-enrolled.
`arpatek` and `sysadmin` access works the same way on k3s nodes as on any other lab host.
HBAC and sudo rules apply without per-host configuration.

The k3s control plane doesn't interact with IPA at all — enrollment is purely for SSH access and host identity, not for Kubernetes itself.
