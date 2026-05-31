# RPi agent

Native systemd monitoring agents for Raspberry Pi OS (Debian-based, ARM64) hosts without Docker.

## Overview

Two agents as native systemd services.

- **node_exporter** — exposes host metrics on `:9100` for Prometheus to scrape
- **Alloy** — reads the systemd journal and ships log entries to Loki

cAdvisor is not included because this host does not run Docker.
This pattern is identical to the RHEL pattern in structure, but uses ARM64 binaries and skips SELinux and firewalld steps.

The agents install under standard FHS paths: binaries in `/usr/local/bin/`, configs in `/etc/`, systemd units in `/etc/systemd/system/`.

## Prerequisites

The host needs:

- Raspberry Pi OS (Debian-based, ARM64)
- DNS resolution for `netwatch.home.arpa` working
- Outbound HTTP to `netwatch.home.arpa:3100` (Loki) reachable
- Inbound HTTP from `netwatch.home.arpa` to `:9100` (node_exporter) and `:12345` (Alloy debug UI) reachable

## Deployment

### 1. Install node_exporter natively

**On the target host:** create the dedicated service user.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
```

**On the target host:** download and install the ARM64 binary.
Pin to v1.11.1 (matches the version used across the fleet):

```bash
cd /tmp
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.11.1/node_exporter-1.11.1.linux-arm64.tar.gz
tar xzf node_exporter-1.11.1.linux-arm64.tar.gz

sudo install -m 0755 -o node_exporter -g node_exporter \
  node_exporter-1.11.1.linux-arm64/node_exporter \
  /usr/local/bin/node_exporter
```

**From the local repo clone:** copy the systemd unit to the host.

```bash
cd <path-to-repo>/monitoring/agents/rpi

scp node_exporter.service <host>:/tmp/
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

### 2. Install Alloy natively

**On the target host:** create the dedicated service user and add it to the `systemd-journal` group.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin alloy
sudo usermod -aG systemd-journal alloy
```

**On the target host:** download and install the ARM64 Alloy binary.
Pin to v1.15.1:

```bash
cd /tmp
curl -LO https://github.com/grafana/alloy/releases/download/v1.15.1/alloy-linux-arm64.zip
unzip alloy-linux-arm64.zip

sudo install -m 0755 -o alloy -g alloy alloy-linux-arm64 /usr/local/bin/alloy
```

**From the local repo clone:** copy the Alloy config and systemd unit to the host.

```bash
cd <path-to-repo>/monitoring/agents/rpi

scp alloy.service <host>:/tmp/
scp alloy/config.alloy <host>:/tmp/
```

**On the target host:** install the config and unit file.

```bash
sudo mkdir -p /etc/alloy
sudo mv /tmp/config.alloy /etc/alloy/config.alloy
sudo mv /tmp/alloy.service /etc/systemd/system/alloy.service
```

**On the target host:** before starting, edit the Alloy config to set the `host` label.

```bash
sudo nano /etc/alloy/config.alloy
# Set "host" to the short hostname of this host
# Example: "host" = "netrunner"
```

**On the target host:** start Alloy.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now alloy
```

Verify:

```bash
systemctl status alloy
curl -s http://localhost:12345/-/ready
# Should return: Alloy is ready.
```

### 3. Add the host to the central server's scrape config

**From the local repo clone:** edit `monitoring/server/prometheus/prometheus.yml`.
Add the new host to the `node` job only (no cAdvisor on RPi hosts):

```yaml
- job_name: "node"
  static_configs:
    - targets:
        - "netwatch.home.arpa:9100"
        - "<new-host>.home.arpa:9100" # add this line
```

**From the local repo clone:** copy the updated config to `netwatch`.

```bash
cd <path-to-repo>/monitoring/server

scp prometheus/prometheus.yml netwatch.home.arpa:/tmp/
```

**On `netwatch`:** move the config into place and reload Prometheus.

```bash
sudo mv /tmp/prometheus.yml /opt/monitoring/prometheus/config/
curl -X POST http://localhost:9090/-/reload
```

## Verification

```bash
systemctl is-active node_exporter alloy

curl -s http://localhost:9100/metrics | head
curl -s http://localhost:12345/-/ready
```

## Operational notes

**Restart a service:**

```bash
sudo systemctl restart alloy
sudo systemctl restart node_exporter
```

**Read logs:**

```bash
journalctl -u alloy -f
journalctl -u node_exporter -f
```

**Reload Alloy config without restart:**

```bash
sudo systemctl reload alloy
```
