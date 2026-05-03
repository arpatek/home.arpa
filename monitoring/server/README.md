# Server (prod-mon-0)

## Overview

The central monitoring server.
Runs the storage and visualization layer (Prometheus, Loki, Grafana) plus the local agents (cAdvisor, Alloy in Compose; node_exporter as a native systemd service).

For architectural context, see [../README.md](../README.md) and [../docs/architecture.md](../docs/architecture.md).
This README is the operational guide for standing up `prod-mon-0` from a fresh Debian install.

## Prerequisites

Before starting, the host needs:

- Debian 13 (Trixie) installed and reachable on the `home.arpa` network
- DNS resolution working — `getent hosts prod-mon-0.home.arpa` should return `10.33.111.102`
- The non-root admin user (in this lab, `arpatek`) configured with sudo access
- Outbound internet access to fetch Docker, the node_exporter binary, and Docker images

The compose stack will pull images from Docker Hub and ghcr.io.
Make sure those registries are reachable before starting.

A few utilities used throughout this README aren't installed by default on a minimal Debian.
Install them up front:

```bash
sudo apt-get update
sudo apt-get install -y curl tar dnsutils jq
```

- `curl` — download the node_exporter binary
- `tar` — extract the node_exporter archive
- `dnsutils` — provides `dig` for DNS troubleshooting
- `jq` — parse JSON output from verification commands

## Deployment

The deployment has three phases.
Native node_exporter first (runs at the host level), then Docker, then the Compose stack.

### 1. Install node_exporter natively

**On `prod-mon-0`:** create the dedicated service user.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
```

**On `prod-mon-0`:** download and install the binary.
Pin to v1.11.1 (matches the version used across the fleet):

```bash
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.11.1/node_exporter-1.11.1.linux-amd64.tar.gz
tar xzf node_exporter-1.11.1.linux-amd64.tar.gz

sudo install -m 0755 -o node_exporter -g node_exporter \
  node_exporter-1.11.1.linux-amd64/node_exporter \
  /usr/local/bin/node_exporter
```

Using `install` rather than `mv` avoids carrying the source's `/tmp` context to the destination.
On Debian this doesn't matter (no SELinux), but using `install` everywhere keeps the procedure consistent across hosts.

**From the local repo clone:** copy the systemd unit to the host.
Replace `<path-to-repo>` below with wherever you have this repo cloned.

```bash
cd <path-to-repo>/monitoring/server

scp node_exporter.service prod-mon-0.home.arpa:/tmp/
```

**On `prod-mon-0`:** install the unit file and start the service.

```bash
sudo mv /tmp/node_exporter.service /etc/systemd/system/node_exporter.service
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
```

Verify:

```bash
systemctl status node_exporter
curl -s http://localhost:9100/metrics | head
```

The status output should show `active (running)`.
The curl should return Prometheus-format metrics.

### 2. Install Docker

Use the official Docker repository for Debian.
The Debian-packaged `docker.io` is older and we want to track upstream:

```bash
# Install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl

# Add Docker's GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine and Compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add your admin user to the docker group so you don't need sudo for compose commands:

```bash
sudo usermod -aG docker $USER
# Either log out and back in, or run 'newgrp docker' below to apply
# the group change in the current shell. New SSH sessions inherit the
# group automatically.
newgrp docker
```

Verify:

```bash
docker version
docker compose version
```

### 3. Deploy the Compose stack

**On `prod-mon-0`:** create the stack directory.

```bash
sudo mkdir -p /opt/monitoring
```

The directory is owned by root, which is the standard convention for `/opt/`.
File operations within this directory will use sudo.

**From the local repo clone:** copy the configs to the host's `/tmp/` directory.
We stage in `/tmp/` because `/opt/monitoring/` is root-owned and scp can't write there directly.
Replace `<path-to-repo>` below with wherever you have this repo cloned.

```bash
cd <path-to-repo>/monitoring/server

scp docker-compose.yml prod-mon-0.home.arpa:/tmp/
scp prometheus/prometheus.yml prod-mon-0.home.arpa:/tmp/
scp loki/loki.yml prod-mon-0.home.arpa:/tmp/
scp alloy/config.alloy prod-mon-0.home.arpa:/tmp/
scp -r grafana/provisioning prod-mon-0.home.arpa:/tmp/
```

**On `prod-mon-0`:** create the bind-mount directory layout and move the configs into place.

```bash
# Create config and data directories for each component
sudo mkdir -p /opt/monitoring/prometheus/{config,data}
sudo mkdir -p /opt/monitoring/loki/{config,data}
sudo mkdir -p /opt/monitoring/alloy/config
sudo mkdir -p /opt/monitoring/grafana/{config/provisioning,data}

# Move the configs into their bind-mount paths
sudo mv /tmp/docker-compose.yml /opt/monitoring/
sudo mv /tmp/prometheus.yml /opt/monitoring/prometheus/config/
sudo mv /tmp/loki.yml /opt/monitoring/loki/config/
sudo mv /tmp/config.alloy /opt/monitoring/alloy/config/
sudo mv /tmp/provisioning/* /opt/monitoring/grafana/config/provisioning/
sudo rmdir /tmp/provisioning
```

**On `prod-mon-0`:** set the data directory ownership.
Each container runs as a specific UID and needs write access to its data directory.

```bash
# Prometheus runs as UID 65534 (nobody) in the official image
sudo chown -R 65534:65534 /opt/monitoring/prometheus/data

# Loki runs as UID 10001
sudo chown -R 10001:10001 /opt/monitoring/loki/data

# Grafana runs as UID 472
sudo chown -R 472:472 /opt/monitoring/grafana/data
```

**From the local repo clone:** copy the env example to the host.

```bash
scp .env.example prod-mon-0.home.arpa:/tmp/
```

**On `prod-mon-0`:** create the actual `.env` file.

```bash
sudo mv /tmp/.env.example /opt/monitoring/.env
sudo chmod 600 /opt/monitoring/.env
sudo nvim /opt/monitoring/.env  # set GRAFANA_ADMIN_USER and GRAFANA_ADMIN_PASSWORD
```

**On `prod-mon-0`:** bring up the stack.

```bash
cd /opt/monitoring
sudo docker compose up -d
```

This pulls all images and starts the services in the background.
First run takes a few minutes depending on download speed.

## Verification

Check that all containers are running:

```bash
docker compose ps
```

All services should show `Up` or `Up (healthy)`.

Check Prometheus is scraping all targets:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job, instance, health}'
```

Every target should show `health: "up"`.
Or visit `http://prod-mon-0.home.arpa:9090/targets` in a browser for the same view.

Check Loki is ready and receiving:

```bash
curl -s http://localhost:3100/ready
# Should return: ready

curl -s http://localhost:3100/loki/api/v1/labels | jq
# Should list labels including "host"
```

Check Grafana is up and dashboards are provisioned:

```bash
curl -s http://localhost:3000/api/health
```

Then visit `http://prod-mon-0.home.arpa:3000` in a browser.
Log in with the credentials from `.env`.
Navigate to Dashboards — both `Node Exporter Full` and `cAdvisor Exporter` should be present.

## Operational notes

**Restart a single service:**

```bash
cd /opt/monitoring
docker compose restart <service>
```

`<service>` is one of: `prometheus`, `loki`, `grafana`, `alloy`, `cadvisor`.

**Restart node_exporter:**

```bash
sudo systemctl restart node_exporter
```

**Read logs:**

```bash
# Stack services
cd /opt/monitoring
docker compose logs -f <service>

# node_exporter
journalctl -u node_exporter -f
```

**Reload config without full restart:**

Prometheus supports config reload via SIGHUP or an HTTP endpoint:

```bash
# After editing /opt/monitoring/prometheus/config/prometheus.yml
curl -X POST http://localhost:9090/-/reload
```

This requires `--web.enable-lifecycle` in the Prometheus command, which is set in the compose file.

Loki and Grafana don't have hot-reload. Edit the config, then restart the relevant service.

**Stop the stack cleanly:**

```bash
cd /opt/monitoring
docker compose down
```

Data persists across `down`/`up` because data directories are bind mounts on the host, not Docker volumes that get removed with the containers.

**Backup:**

The persistent state is everything under `/opt/monitoring/{prometheus,loki,grafana}/data`.
A snapshot of those directories captures the entire observability state.
Bind-mount design means a simple `tar` of `/opt/monitoring/` covers everything except the actual containers (which are reproducible from the compose file).
