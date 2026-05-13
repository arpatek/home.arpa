# Upgrading

Procedures for upgrading k3s and the cluster nodes.

## Currently installed

| Component    | Version      |
| ------------ | ------------ |
| k3s          | v1.35.4+k3s1 |
| Kubernetes   | v1.35.4      |
| cert-manager | v1.20.2      |

v1.35.4 was the latest stable Kubernetes release at the time of cluster provisioning.
cert-manager v1.20.2 was the latest stable release at the time of installation.
Neither is a special pin — upgrade when a new minor version has been out for a few weeks and the changelog is clean.

Check running versions:

```bash
kubectl version
kubectl get nodes -o wide    # shows version per node
```

## Upgrading k3s

k3s upgrades follow Kubernetes release cadence.
The version format is `v<kubernetes-version>+k3s<patch>` — for example, `v1.35.4+k3s1` is Kubernetes 1.35.4 with k3s patch 1.

**Upgrade the master first, then each worker.**
The Kubernetes API server is backward-compatible with kubelets one minor version behind, so workers running the old version continue working while the master is being upgraded.
Never upgrade workers before the master.

### Manual upgrade procedure

**On the master:**

```bash
ssh arpatek@10.33.111.103

# Check available versions at https://github.com/k3s-io/k3s/releases
# Set the target version
export INSTALL_K3S_VERSION=v1.36.0+k3s1

curl -sfL https://get.k3s.io | sudo -E sh -s - server \
  --node-taint node-role.kubernetes.io/control-plane=:NoSchedule \
  --tls-san prod-k3s-master-0.home.arpa \
  --tls-san 10.33.111.103 \
  --write-kubeconfig-mode 644
```

Wait for the master to come back up:

```bash
kubectl get nodes
# master should show new version and Ready status
```

**On each worker** (one at a time):

```bash
# Drain the node first — moves its pods to the other worker
kubectl drain prod-k3s-worker-0.home.arpa --ignore-daemonsets --delete-emptydir-data

ssh arpatek@10.33.111.104
export INSTALL_K3S_VERSION=v1.36.0+k3s1
export K3S_URL=https://10.33.111.103:6443
export K3S_TOKEN=$(ssh arpatek@10.33.111.103 "sudo cat /var/lib/rancher/k3s/server/node-token")
curl -sfL https://get.k3s.io | sudo -E sh -

# Back on local machine — uncordon the node to allow scheduling again
kubectl uncordon prod-k3s-worker-0.home.arpa
```

Repeat for `prod-k3s-worker-1`.

**Why drain before upgrading a worker:**
Draining evicts all pods from the node gracefully before the upgrade restarts the k3s-agent service.
Without draining, pods are killed abruptly mid-upgrade.
The `--ignore-daemonsets` flag skips DaemonSet pods (like Traefik and Flannel) since those can't be moved.

### Rollback

k3s rollback is the same as upgrading — reinstall the previous version by pinning `INSTALL_K3S_VERSION`.

**On the master:**

```bash
ssh arpatek@10.33.111.103
export INSTALL_K3S_VERSION=v1.35.4+k3s1
curl -sfL https://get.k3s.io | sudo -E sh -s - server \
  --node-taint node-role.kubernetes.io/control-plane=:NoSchedule \
  --tls-san prod-k3s-master-0.home.arpa \
  --tls-san 10.33.111.103 \
  --write-kubeconfig-mode 644
```

**On each worker:**

```bash
kubectl drain prod-k3s-worker-0.home.arpa --ignore-daemonsets --delete-emptydir-data
ssh arpatek@10.33.111.104
export INSTALL_K3S_VERSION=v1.35.4+k3s1
export K3S_URL=https://10.33.111.103:6443
export K3S_TOKEN=$(ssh arpatek@10.33.111.103 "sudo cat /var/lib/rancher/k3s/server/node-token")
curl -sfL https://get.k3s.io | sudo -E sh -
kubectl uncordon prod-k3s-worker-0.home.arpa
```

Kubernetes API compatibility means the workers will reconnect immediately once the master is back.
etcd state is not affected by a k3s binary rollback — no data is lost.

### Automated upgrade with system-upgrade-controller

k3s provides an official upgrade controller that handles rolling upgrades automatically.
For a homelab, manual upgrades are simpler and more educational.
The system-upgrade-controller is worth exploring when the cluster grows to more nodes.

Documentation: <https://docs.k3s.io/upgrades/automated>

## Upgrading cluster node OS

The k3s nodes run Debian 13.
OS patch upgrades are safe to apply without k3s-specific steps:

```bash
ssh arpatek@10.33.111.10x
sudo apt update && sudo apt upgrade
sudo reboot
```

After rebooting, k3s starts automatically on boot (`--onboot 1` was set at VM creation).
Verify the node rejoins:

```bash
kubectl get nodes
```

## Upgrading cert-manager

cert-manager is installed from the upstream release manifest.
Check for new versions at <https://github.com/cert-manager/cert-manager/releases>.

**Apply new CRDs first, then the controller:**

```bash
export CERT_MANAGER_VERSION=v1.21.0

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml
```

**Verify:**

```bash
kubectl get pods -n cert-manager
# all three pods (controller, cainjector, webhook) should reach Running
kubectl get certificates -A
# wildcard cert should remain Ready
```

**Rollback:**
Reapply the previous version's manifests using the same two commands with the old version pinned.
CRDs from a newer version are generally backward-compatible with an older controller, but rolling back CRDs is not safe — only roll back the controller manifest unless the CRD schema itself changed.

## Version skew policy

Kubernetes supports a maximum version skew of ±1 minor version between the API server and kubelets.
This means:
- kubectl should be within 1 minor version of the server
- Workers should be within 1 minor version of the master

After upgrading the cluster to a new minor version, update kubectl on all client machines:

```bash
# On each machine with kubectl installed
# x86_64 (Mac, Linux on Intel)
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl"
# or on macOS
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/darwin/arm64/kubectl"
# ARM64 Linux (Asahi)
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/arm64/kubectl"

chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
