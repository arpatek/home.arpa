# RHEL agent

Native systemd monitoring agents for RHEL-family hosts (RHEL, Rocky Linux, AlmaLinux).

## Overview

Two agents as native systemd services.

- **node_exporter** — exposes host metrics on `:9100` for Prometheus to scrape
- **Alloy** — reads the systemd journal and ships log entries to Loki

cAdvisor is not included because RHEL hosts in this lab don't run Docker.
If you need container metrics on a RHEL host, see the Debian pattern as a reference and adapt the cAdvisor service to use Podman's socket instead.

The agents install under standard FHS paths: binaries in `/usr/local/bin/`, configs in `/etc/`, systemd units in `/etc/systemd/system/`.

## Prerequisites

The host needs:

- RHEL 9, Rocky Linux 9, AlmaLinux 9, or compatible
- The non-root admin user (in this lab, IPA-managed users) with sudo access
- DNS resolution for `prod-mon-0.home.arpa` working
- Outbound HTTP to `prod-mon-0.home.arpa:3100` (Loki) reachable
- Inbound HTTP from `prod-mon-0.home.arpa` to `:9100` (node_exporter) and `:12345` (Alloy debug UI) reachable

A few utilities are useful for verification:

```bash
sudo dnf install -y curl jq
```

`curl`, `tar`, and `getent` are available in the default RHEL install. `jq` is in EPEL or the main repos depending on version.

### A note on SELinux

This pattern assumes SELinux is in enforcing mode (the default).
The deployment uses `install` (not `mv`) when placing binaries, which sets the correct file context for `/usr/local/bin/` automatically.
The systemd units run in the `init_t` domain, which permits exec from `/usr/local/bin/`.

If something fails to start with permission errors that don't make sense, check `/var/log/audit/audit.log` for AVC denials before debugging deeper.
See [../../docs/gotchas.md](../../docs/gotchas.md) for the full SELinux story.

## Deployment

Three phases: node_exporter native install, Alloy native install, then firewall and central-server scrape config.

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

Using `install` is critical on RHEL.
A `mv` from `/tmp` would carry the `user_tmp_t` SELinux context to the destination, and systemd would refuse to exec it.

**From the local repo clone:** copy the systemd unit to the host.
Replace `<path-to-repo>` and `<host>` with your actual values.

```bash
cd <path-to-repo>/monitoring/agents/rhel

scp node_exporter.service <host>.home.arpa:/tmp/
```

**On the target host:** install the unit file and start the service.

```bash
sudo mv /tmp/node_exporter.service /etc/systemd/system/node_exporter.service
sudo restorecon -v /etc/systemd/system/node_exporter.service

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
```

The `restorecon` step resets the SELinux context on the unit file to whatever the policy expects for `/etc/systemd/system/`.
This is the same problem as with the binary, applied to a different file.

Verify:

```bash
systemctl status node_exporter
curl -s http://localhost:9100/metrics | head
```

### 2. Install Alloy natively

**On the target host:** create the dedicated service user and add it to the `systemd-journal` group.
Alloy reads journal files, which requires group membership.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin alloy
sudo usermod -aG systemd-journal alloy
```

**On the target host:** download and install the Alloy binary.
Pin to v1.15.1:

```bash
cd /tmp
curl -LO https://github.com/grafana/alloy/releases/download/v1.15.1/alloy-linux-amd64.zip
unzip alloy-linux-amd64.zip

sudo install -m 0755 -o alloy -g alloy \
  alloy-linux-amd64 \
  /usr/local/bin/alloy
```

**From the local repo clone:** copy the Alloy config and systemd unit to the host.

```bash
cd <path-to-repo>/monitoring/agents/rhel

scp alloy.service <host>.home.arpa:/tmp/
scp alloy/config.alloy <host>.home.arpa:/tmp/
```

**On the target host:** install the config and unit file.

```bash
# Config goes in /etc/alloy/
sudo mkdir -p /etc/alloy
sudo mv /tmp/config.alloy /etc/alloy/config.alloy
sudo restorecon -v /etc/alloy/config.alloy

# Systemd unit
sudo mv /tmp/alloy.service /etc/systemd/system/alloy.service
sudo restorecon -v /etc/systemd/system/alloy.service
```

**On the target host:** before starting, edit the Alloy config to set the `host` label.
Each agent's logs need to be uniquely identifiable in Loki:

```bash
sudo vim /etc/alloy/config.alloy
# Find the labels block and set "host" to the short hostname of this host
# Example: "host" = "prod-ipa-0"
```

This is the one line that varies per host.

**On the target host:** start Alloy.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now alloy
```

The systemd unit has `SupplementaryGroups=systemd-journal` set explicitly.
This is required in addition to the `usermod -aG` step from earlier — systemd's hardening directives can drop supplementary groups, so the group must be declared in both places.

Verify:

```bash
systemctl status alloy
curl -s http://localhost:12345/-/ready
# Should return: Alloy is ready.
```

If Alloy is running but no logs are appearing in Loki, check that it can read the journal:

```bash
sudo -u alloy journalctl -n 5
```

If this fails with permission errors, the supplementary group setup is incomplete.

### 3. Open firewall ports and update the central server

**On the target host:** open the ports that Prometheus and operators need to reach.

```bash
sudo firewall-cmd --permanent --add-port=9100/tcp  # node_exporter
sudo firewall-cmd --permanent --add-port=12345/tcp # Alloy debug UI (optional)
sudo firewall-cmd --reload
```

The `--permanent` flag writes the rule to disk; `--reload` applies it to the running firewall.
Both steps are required.
Verify:

```bash
sudo firewall-cmd --list-ports
# Should include 9100/tcp and 12345/tcp
```

The `12345/tcp` rule for Alloy's debug UI is optional.
The agent works fine without it because the agent pushes to Loki rather than being scraped, but having the debug UI reachable is useful for troubleshooting.

**From the local repo clone:** edit `monitoring/server/prometheus/prometheus.yml`.
Add the new host to the `node` job (no cAdvisor on RHEL hosts):

```yaml
- job_name: "node"
  static_configs:
    - targets:
        - "prod-mon-0.home.arpa:9100"
        - "<new-host>.home.arpa:9100" # add this line
```

**From the local repo clone:** copy the updated config to the central server.

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

Verify the new host shows as `UP` at `http://prod-mon-0.home.arpa:9090/targets`.

## Verification

On the target host, check that both services are active:

```bash
systemctl is-active node_exporter alloy
# Both should print: active
```

Check node_exporter is responding:

```bash
curl -s http://localhost:9100/metrics | head
```

Check Alloy is ready:

```bash
curl -s http://localhost:12345/-/ready
# Should return: Alloy is ready.
```

From `prod-mon-0`, verify the central server is scraping this host:

```bash
curl -s http://localhost:9090/api/v1/targets | jq \
  '.data.activeTargets[] | select(.labels.instance | contains("<host>.home.arpa")) | {job, health}'
```

In Grafana, navigate to Explore, select Loki as the data source, and run the query `{host="<host>"}` to verify journal logs are arriving.
A useful follow-up query: `{host="<host>", level="err"}` to see only error-level entries.

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

Alloy supports config reload via SIGHUP:

```bash
sudo systemctl reload alloy
```

This re-reads `/etc/alloy/config.alloy` without dropping the open journal cursor.

**Stop a service cleanly:**

```bash
sudo systemctl stop alloy
sudo systemctl stop node_exporter
```

**SELinux troubleshooting:**

If a service fails to start with `Permission denied` errors that aren't explained by file modes:

```bash
# Check audit log for AVC denials
sudo ausearch -m AVC -ts recent

# Reset context on a specific file
sudo restorecon -v /path/to/file

# View current context (note the -Z flag)
ls -lZ /usr/local/bin/alloy
```

The agents have no persistent state worth backing up beyond the configs themselves, which already live in the repo.
