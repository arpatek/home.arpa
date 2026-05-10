# k3s

## Cluster nodes

| Host                          | VMID | Role          | vCPUs | RAM  | Disk  | IP              |
| ----------------------------- | ---- | ------------- | ----- | ---- | ----- | --------------- |
| prod-k3s-master-0.home.arpa   | 103  | control-plane | 2     | 4GB  | 100GB | 10.33.111.103   |
| prod-k3s-worker-0.home.arpa   | 104  | worker        | 2     | 4GB  | 100GB | 10.33.111.104   |
| prod-k3s-worker-1.home.arpa   | 105  | worker        | 2     | 4GB  | 100GB | 10.33.111.105   |

All nodes: Debian 13.3 (Trixie), provisioned via cloud-init from a Proxmox template.
See [proxmox/provision-k3s.sh](../proxmox/provision-k3s.sh) for the VM provisioning commands.

## Overview

k3s cluster running on `devstem` (Proxmox).
k3s is a lightweight Kubernetes distribution — same API as full Kubernetes but packaged as a single binary with sensible defaults for resource-constrained environments.

The master is tainted `control-plane:NoSchedule` — it runs only the Kubernetes control plane.
All workloads schedule exclusively on the two worker nodes.

Planned workloads:
- Portfolio website
- FastAPI application (k3s capstone project)

## Stack versions

| Component  | Version         |
| ---------- | --------------- |
| k3s        | v1.35.4+k3s1    |
| Kubernetes | v1.35.4         |
| CNI        | Flannel (default) |
| Ingress    | Traefik (default) |

## Repository layout

```
k3s/
├── README.md                   # this file — cluster overview and node inventory
└── docs/
    ├── architecture.md         # control plane components, node roles, data flow
    ├── decisions.md            # k3s vs alternatives, cluster design choices
    ├── gotchas.md              # issues hit during provisioning and cluster setup
    └── upgrading.md            # k3s upgrade procedures
```

## Cluster access

The cluster API server runs on `prod-k3s-master-0` at port 6443.
`kubectl` access requires the kubeconfig from the master:

```bash
mkdir -p ~/.kube
scp arpatek@10.33.111.103:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Linux
sed -i 's/127.0.0.1/10.33.111.103/' ~/.kube/config

# macOS
sed -i '' 's/127.0.0.1/10.33.111.103/' ~/.kube/config
```

For ARM64 clients (Asahi Linux), install the matching kubectl:

```bash
curl -LO "https://dl.k8s.io/release/v1.35.4/bin/linux/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

## Current deployment

```bash
kubectl get nodes
NAME                          STATUS   ROLES           AGE   VERSION
prod-k3s-master-0.home.arpa   Ready    control-plane   —     v1.35.4+k3s1
prod-k3s-worker-0.home.arpa   Ready    worker          —     v1.35.4+k3s1
prod-k3s-worker-1.home.arpa   Ready    worker          —     v1.35.4+k3s1
```
