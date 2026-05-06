# Debian agent

Containerized monitoring agents for Debian-family hosts running Docker.

## Overview

Two agents in Compose, plus node_exporter as a native systemd service.

- **node_exporter** (native) — exposes host metrics on `:9100` for Prometheus to scrape
- **cAdvisor** (container) — exposes container metrics on `:8080` for Prometheus to scrape
- **Alloy** (container) — discovers running Docker containers, ships their stdout to Loki

The agents run in their own Compose project at `/opt/monitoring-agents/`, separate from anything else on the host.
On `prod-git-0` for example, this lives alongside `/opt/gitea/` but operates independently.
Restarting Gitea doesn't bounce the agents.

## Prerequisites

The host needs:

- Debian 12+ or Ubuntu 22.04+ (any reasonably recent Debian-family distro)
- Docker Engine and Compose plugin installed (see [../../server/README.md](../../server/README.md) section "Install Docker" if needed)
- The non-root admin user in the `docker` group
- DNS resolution for `prod-mon-0.home.arpa` working (the agents push logs there)
- Outbound HTTP to `prod-mon-0.home.arpa:3100` (Loki) reachable
- Inbound HTTP from `prod-mon-0.home.arpa` to `:9100` (node_exporter) and `:8080` (cAdvisor) reachable

A few utilities are useful for verification:

```bash
sudo apt-get update
sudo apt-get install -y curl jq
```

## Deployment

Three phases, same pattern as the server: native node_exporter first, then the agent stack.

### 1. Install node_exporter natively

**On the target host:** create the dedicated service user.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
```

**On the target host:** download and install the binary.
Pin to v1.11.1 (matches the version used across the fleet):

```bash
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.11.1/node_exporter-1.11.1.linux-amd64.tar.gz
tar xzf node_exporter-1.11.1.linux-amd64.tar.gz

sudo install -m 0755 -o node_exporter -g node_exporter \
  node_exporter-1.11.1.linux-amd64/node_exporter \
  /usr/local/bin/node_exporter
```

**From the local repo clone:** copy the systemd unit to the host.
Replace `<path-to-repo>` and `<host>` with your actual values.

```bash
cd <path-to-repo>/monitoring/agents/debian

scp node_exporter.service <host>.home.arpa:/tmp/
```

**On the target host:** install the unit file and start the service.

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

### 2. Deploy the agent stack

**On the target host:** create the agent directory.

```bash
sudo mkdir -p /opt/monitoring-agents
```

The directory is owned by root, the standard convention for `/opt/`.

**From the local repo clone:** copy the configs to the host's `/tmp/` directory.

```bash
cd <path-to-repo>/monitoring/agents/debian

scp docker-compose.yml <host>.home.arpa:/tmp/
scp alloy/config.alloy <host>.home.arpa:/tmp/
```

**On the target host:** create the directory layout and move the configs into place.

```bash
sudo mkdir -p /opt/monitoring-agents/alloy/config

sudo mv /tmp/docker-compose.yml /opt/monitoring-agents/
sudo mv /tmp/config.alloy /opt/monitoring-agents/alloy/config/
```

**On the target host:** before starting, edit the Alloy config to set the `host` label.
Each agent's logs need to be uniquely identifiable in Loki:

```bash
sudo nvim /opt/monitoring-agents/alloy/config/config.alloy
# Find the labels block and set "host" to the short hostname of this host
# Example: "host" = "prod-git-0"
```

This is the one line that varies per host.
Everything else in the deployment is identical.

**On the target host:** bring up the stack.

```bash
cd /opt/monitoring-agents
sudo docker compose up -d
```

This pulls cAdvisor and Alloy and starts them.
First run takes a minute or two depending on download speed.

### 3. Add the host to the central server's scrape config

The agents are running, but the central server doesn't know about them yet.
Prometheus needs the new host added to its scrape targets.

**From the local repo clone:** edit `monitoring/server/prometheus/prometheus.yml`.
Add the new host to the `node` and `cadvisor` jobs:

```yaml
- job_name: "node"
  static_configs:
    - targets:
        - "prod-mon-0.home.arpa:9100"
        - "<new-host>.home.arpa:9100" # add this line

- job_name: "cadvisor"
  static_configs:
    - targets:
        - "prod-mon-0.home.arpa:8080"
        - "<new-host>.home.arpa:8080" # add this line
```

**On `prod-mon-0`:** copy the updated config and reload Prometheus.

**From the local repo clone:** copy the updated config to the host.

```bash
cd <path-to-repo>/monitoring/server

scp prometheus/prometheus.yml prod-mon-0.home.arpa:/tmp/
```

**On `prod-mon-0`:** move the config into place and reload Prometheus.

```bash
sudo mv /tmp/prometheus.yml /opt/monitoring/prometheus/config/

# Reload Prometheus without restarting the container:
curl -X POST http://localhost:9090/-/reload
```

````

Verify the new host shows as `UP` at `http://prod-mon-0.home.arpa:9090/targets`.

## Verification

On the target host, check that all containers are running:

```bash
cd /opt/monitoring-agents
docker compose ps
````

Both `cadvisor` and `alloy` should show `Up`.

Check that node_exporter is responding locally:

```bash
curl -s http://localhost:9100/metrics | head
```

Check that cAdvisor is responding:

```bash
curl -s http://localhost:8080/metrics | head
```

Check that Alloy is reachable:

```bash
curl -s http://localhost:12345/-/ready
# Should return: Alloy is ready.
```

From `prod-mon-0`, verify the central server is scraping this host:

```bash
curl -s http://localhost:9090/api/v1/targets | jq \
  '.data.activeTargets[] | select(.labels.instance | contains("<host>.home.arpa")) | {job, health}'
```

Logs should also be flowing into Loki.
On `prod-mon-0`:

```bash
curl -G -s 'http://localhost:3100/loki/api/v1/labels' | jq
# Should list "host" as one of the labels
```

In Grafana, navigate to Explore, select Loki as the data source, and run the query `{host="<host>"}` to verify logs are arriving.

## Operational notes

**Restart a single service:**

```bash
cd /opt/monitoring-agents
docker compose restart <service>
```

`<service>` is `cadvisor` or `alloy`.

**Restart node_exporter:**

```bash
sudo systemctl restart node_exporter
```

**Read logs:**

```bash
# Stack services
cd /opt/monitoring-agents
docker compose logs -f <service>

# node_exporter
journalctl -u node_exporter -f
```

**Stop the stack cleanly:**

```bash
cd /opt/monitoring-agents
docker compose down
```

The agents have no persistent state worth backing up.
node_exporter is stateless.
Alloy keeps a positions file (where it left off in each log source) inside the container's writable layer, but losing it just means logs replay from current time — annoying for ~5 minutes but not data loss.
