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

## Workloads

### arpatek.dev

Personal site and CI/CD capstone, running at `arpatek.dev`.
FastAPI application that serves both HTML and curl-friendly terminal output.
Try it: `curl arpatek.dev`

Source code and pipeline configuration live in the `arpatek/arpatek.dev` repository on Gitea (`git.arpatek.dev`).
That repo is its own project — this directory only contains the k3s manifests needed to run it.

The CI pipeline runs on `prod-git-0` via act_runner.
Each push to `arpatek/arpatek.dev` triggers a build that packages the app into a container image and pushes it to the Gitea container registry at `git.arpatek.dev`.
k3s pulls the updated image using the `gitea-registry` imagePullSecret and `imagePullPolicy: Always`.

### git.arpatek.dev

Gitea is not a k3s workload — it runs on `prod-git-0` via Docker Compose.
k3s exposes it publicly through a headless Service + Endpoints object pointing at `10.33.111.101:3000`, with Traefik routing `git.arpatek.dev` to that backend over TLS.

## Stack versions

| Component   | Version           |
| ----------- | ----------------- |
| k3s         | v1.35.4+k3s1      |
| Kubernetes  | v1.35.4           |
| CNI         | Flannel (default)  |
| Ingress     | Traefik (default)  |
| cert-manager | v1.20.2          |

## Repository layout

```
k3s/
├── README.md                       # this file — cluster overview and node inventory
├── manifests/
│   ├── https-transport.yaml        # ServersTransport for HTTPS backends (Pi-hole, IPA)
│   ├── arpatek-dev/
│   │   ├── deployment.yaml         # arpatek.dev app — pulls image from Gitea registry
│   │   └── ingress.yaml            # Traefik ingress + Service for arpatek.dev
│   ├── cert-manager/
│   │   ├── clusterissuer.yaml      # Let's Encrypt ClusterIssuer (Cloudflare DNS-01)
│   │   └── wildcard-cert.yaml      # *.arpatek.dev wildcard certificate
│   ├── gitea/
│   │   ├── ingress.yaml            # Traefik ingress for git.arpatek.dev
│   │   └── service.yaml            # headless Service + Endpoints → prod-git-0:3000
│   ├── monitoring/
│   │   ├── ingress.yaml            # Traefik ingress for gf.arpatek.dev + pm.arpatek.dev
│   │   └── service.yaml            # headless Services + Endpoints → prod-mon-0:3000/9090
│   ├── pihole/
│   │   ├── ingress.yaml            # Traefik ingress for pi.arpatek.dev
│   │   └── service.yaml            # headless Service + Endpoints → netrunner-rpi:443
│   └── proxmox/
│       ├── ingress.yaml            # Traefik ingress for pve.arpatek.dev
│       └── service.yaml            # headless Service + Endpoints → devstem:8006
└── docs/
    ├── architecture.md             # control plane components, node roles, data flow
    ├── decisions.md                # k3s vs alternatives, cluster design choices
    ├── gotchas.md                  # issues hit during provisioning and cluster setup
    └── upgrading.md                # k3s upgrade procedures
```

## Deployment

### 1. Provision VMs

Run [proxmox/provision-k3s.sh](../proxmox/provision-k3s.sh) on `devstem` to create and start the three VMs.
Wait ~60 seconds for cloud-init to finish, then SSH in as `sysadmin`.

### 2. Add sysadmin user and enroll in IPA

On each node:

```bash
# Add sysadmin user (cloud-init creates it, but set the password)
sudo passwd sysadmin

# Set FQDN hostname
sudo hostnamectl set-hostname <hostname>.home.arpa

# Add hosts entries
echo "10.33.111.100 prod-ipa-0.home.arpa prod-ipa-0" | sudo tee -a /etc/hosts
echo "<node-ip> <hostname>.home.arpa <hostname>" | sudo tee -a /etc/hosts

# Enroll in IPA
sudo apt install freeipa-client -y
sudo ipa-client-install \
  --domain=home.arpa \
  --server=prod-ipa-0.home.arpa \
  --realm=HOME.ARPA \
  --hostname=<hostname>.home.arpa \
  --principal admin \
  --mkhomedir
```

### 3. Install k3s on the master

```bash
ssh arpatek@10.33.111.103

curl -sfL https://get.k3s.io | sudo sh -s - server \
  --node-taint node-role.kubernetes.io/control-plane=:NoSchedule \
  --tls-san prod-k3s-master-0.home.arpa \
  --tls-san 10.33.111.103 \
  --write-kubeconfig-mode 644
```

### 4. Join the workers

Get the node token from the master:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

On each worker:

```bash
export K3S_URL=https://10.33.111.103:6443
export K3S_TOKEN=<token-from-master>
curl -sfL https://get.k3s.io | sudo -E sh -
```

### 5. Label worker nodes

```bash
kubectl label node prod-k3s-worker-0.home.arpa node-role.kubernetes.io/worker=worker
kubectl label node prod-k3s-worker-1.home.arpa node-role.kubernetes.io/worker=worker
```

### 6. Set up kubectl access

See [Cluster access](#cluster-access) below.

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
