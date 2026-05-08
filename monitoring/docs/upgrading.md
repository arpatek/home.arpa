# Upgrading

Procedures and considerations for upgrading the components of this monitoring stack.

This doc covers what's pinned, why those specific versions were chosen, and how to upgrade each component when the time comes.
For the broader "why pin at all" reasoning, see [decisions.md](decisions.md).
For the gotchas that informed some of these version choices, see [gotchas.md](gotchas.md).

## Version pin philosophy

Every image and binary in this stack is pinned to a specific version.
No `:latest` tags, no floating versions, no automatic distro-package upgrades.

This means upgrades are deliberate.
Read the changelog, change the version number, apply, verify.
The cost is occasional manual upgrade work.
The benefit is that nothing changes underneath the stack without consent.

The trade-off is that pinned stacks accumulate drift over time.
A stack pinned today and untouched for a year will be running CVE-vulnerable versions of several components by then.
The discipline this requires: review pinned versions on a cadence (quarterly is reasonable), check for security releases, upgrade deliberately.

## Currently pinned versions

| Component     | Pinned version | Source                          |
| ------------- | -------------- | ------------------------------- |
| Prometheus    | `v3.11.2`      | Docker Hub: `prom/prometheus`   |
| Loki          | `3.7.1`        | Docker Hub: `grafana/loki`      |
| Grafana       | `12.4.3`       | Docker Hub: `grafana/grafana`   |
| Alloy         | `v1.15.1`      | Docker Hub: `grafana/alloy`     |
| cAdvisor      | `0.56.2`       | GHCR: `ghcr.io/google/cadvisor` |
| node_exporter | `v1.11.1`      | GitHub releases binary          |

A note on tag conventions, since they vary per project: Prometheus and Alloy use a `v` prefix on their tags, Grafana, Loki, and cAdvisor don't.
node_exporter uses `v` in the GitHub release tag but the binary archive doesn't.
Always verify against the actual registry page or release page, not the upstream Git release page, to avoid pulling a tag that doesn't exist.

## Per-component upgrade procedures

### Prometheus

**Current pin:** `v3.11.2`.

**Why this version:** Latest stable at deployment time, includes the fix for CVE-2026-40179 (stored XSS via crafted metric names and label values).
Prometheus 3.x is API-stable from the 2.x line, but the migration involved a TSDB format change that's already complete in this stack.

**Upgrade procedure.**

Find the new version on <https://github.com/prometheus/prometheus/releases>.
Skim the release notes for breaking changes.
Patch releases (e.g. `v3.11.2 → v3.11.3`) are safe — bug fixes and security patches only.
Minor releases (e.g. `v3.11.x → v3.12.x`) may have feature additions but stay backward-compatible.
Major releases (e.g. `v3.x → v4.x`) require reading the migration guide carefully.

Edit `monitoring/server/docker-compose.yml`:

```yaml
services:
  prometheus:
    image: prom/prometheus:v3.11.3 # change version here
```

Apply on `prod-mon-0`:

```bash
# scp the updated docker-compose.yml using the same pattern as in
# server/README.md, then on prod-mon-0:

cd /opt/monitoring
sudo docker compose pull prometheus
sudo docker compose up -d prometheus
```

The `pull` step downloads the new image; `up -d prometheus` recreates only the Prometheus container, leaving everything else running.

**Verification.**

```bash
# Container should be up and healthy
docker compose ps prometheus

# Targets endpoint should return all UP
curl -s http://localhost:9090/api/v1/targets | jq \
  '.data.activeTargets[] | {job, instance, health}'

# Version metric reflects the new version
curl -s http://localhost:9090/api/v1/query?query=prometheus_build_info | jq
```

**Rollback.**

Edit the compose file back to the prior version, run `pull` and `up -d` again.
Prometheus stores its TSDB in an upgrade-safe format within a major version, so rolling back a patch or minor release is safe.
Rolling back across a major release (`v4.x → v3.x`) requires the data directory to remain untouched by the newer version, which isn't guaranteed.

### Loki

**Current pin:** `3.7.1`.

**Why this version:** Latest stable in the 3.7.x line.
The schema is set to v13, the recommended schema for Loki 3.x deployments.

**Upgrade procedure.**

Find the new version on <https://github.com/grafana/loki/releases>.
**Critical:** check whether the new version requires a schema migration.

Loki schema migrations are one-way.
A schema declaration like `schema: v13` in `loki.yml` tells Loki how to write new chunks; older chunks remain in their original schema until they age out of retention.
Upgrading Loki itself is usually fine, but changing the schema declaration is a one-way decision that affects all writes from that point forward.

For patch releases (e.g. `3.7.1 → 3.7.2`) and minor releases within the same schema (`3.7.x → 3.8.x` if both are schema v13), the upgrade is just an image bump.

Edit `monitoring/server/docker-compose.yml`:

```yaml
services:
  loki:
    image: grafana/loki:3.7.2 # change version here
```

Apply:

```bash
cd /opt/monitoring
sudo docker compose pull loki
sudo docker compose up -d loki
```

**Verification.**

```bash
# Loki ready endpoint
curl -s http://localhost:3100/ready
# Should return: ready

# Buildinfo endpoint shows the running version
curl -s http://localhost:3100/loki/api/v1/status/buildinfo | jq

# Verify recent logs are still flowing in
curl -G -s 'http://localhost:3100/loki/api/v1/labels' | jq
# Should still list "host" and other labels
```

**Rollback.**

Same procedure in reverse: edit compose, `pull`, `up -d`.
Safe within a single schema version.
If a schema change has been applied (rare), rollback is more involved and may require restoring chunks from backup.

### Grafana

**Current pin:** `12.4.3`.

**Why this version:** Grafana 13.0 was withdrawn shortly after release due to issues with v2 dashboard schema imports.
Grafana 13.0.1 fixed those issues but introduces several breaking changes that need consideration before upgrading.
12.4.3 is the last 12.x release and remains supported.

**Upgrade procedure.**

For patch releases within 12.x, the upgrade is straightforward.
For 12.x → 13.x, read <https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v13.0/> before upgrading.
Notable breaking changes in 13.0:

- **Image Renderer plugin support removed** — must be deployed as a separate service if PDF/screenshot rendering is needed.
- **`/api` path deprecated** in favor of `/apis` — affects integrations that hit Grafana's HTTP API directly.
- **Numeric data source IDs disabled by default** — must use UIDs.
- **RBAC enforcement tightened** for custom roles.
- **Scenes-powered dashboards** are now mandatory (no opt-out).

For this homelab specifically, none of those changes affect the running stack — there's no PDF rendering, no external integrations using the API, no custom RBAC.
The 13.x upgrade is mostly safe here, but read the breaking changes anyway.

Edit `monitoring/server/docker-compose.yml`:

```yaml
services:
  grafana:
    image: grafana/grafana:12.4.4   # patch within 12.x
    # OR
    image: grafana/grafana:13.0.1   # major upgrade after reading the guide
```

Apply:

```bash
cd /opt/monitoring
sudo docker compose pull grafana
sudo docker compose up -d grafana
```

**Verification.**

```bash
# Grafana health endpoint
curl -s http://localhost:3000/api/health | jq

# Login via browser at http://prod-mon-0.home.arpa:3000

# Verify dashboards still load and queries return data
# Check both Node Exporter Full and cAdvisor Exporter dashboards
```

If the dashboards show "Data source not found" after the upgrade, hard-refresh the browser (`Ctrl+Shift+R`).
This is the browser cache gotcha from [gotchas.md](gotchas.md).

**Rollback.**

Edit compose back to the prior version.
Grafana stores its state in a SQLite database under `/opt/monitoring/grafana/data/grafana.db`.
Within a major version, the database is forward-and-backward compatible.
Across major versions, there can be schema migrations that aren't reversible — rolling back from 13.x to 12.x after the database has been migrated isn't straightforward.

Best practice: snapshot `/opt/monitoring/grafana/data/` before any major upgrade, so a rollback can restore the pre-upgrade database state.

### Alloy

**Current pin:** `v1.15.1`.

**Why this version:** Stable release in the 1.15.x line.
Avoided v1.11.3 specifically due to a regression in the tracing pipeline.
Versions in the 1.15.x and 1.16.x lines are both stable.

**Upgrade procedure.**

Alloy releases on a 3-week cadence (minor versions) with patch releases as needed.
Read <https://grafana.com/docs/alloy/latest/release-notes/> before upgrading.
Pay attention to:

- **Component renames or removals** — Alloy occasionally renames components between minor versions. The release notes call these out as breaking changes.
- **OpenTelemetry Collector dependency updates** — Alloy bundles a version of the OTel Collector. Upstream OTel changes can affect Alloy's behavior even if the Alloy syntax doesn't change.

The Alloy on `prod-mon-0` and `prod-git-0` runs as a container. Edit the relevant compose file:

```yaml
services:
  alloy:
    image: grafana/alloy:v1.16.1 # change version here
```

Apply:

```bash
# On the host (prod-mon-0 or prod-git-0)
cd /opt/monitoring  # or /opt/monitoring-agents/ on prod-git-0
sudo docker compose pull alloy
sudo docker compose up -d alloy
```

The Alloy on `prod-ipa-0` is a native systemd service.
The upgrade is different: download the new binary, replace the old one, restart the service.

**On `prod-ipa-0`:**

```bash
# Download new version
cd /tmp
curl -LO https://github.com/grafana/alloy/releases/download/v1.16.1/alloy-linux-amd64.zip
unzip alloy-linux-amd64.zip

# Stop Alloy before replacing the binary
sudo systemctl stop alloy

# Replace the binary using install (preserves SELinux context)
sudo install -m 0755 -o alloy -g alloy \
  alloy-linux-amd64 \
  /usr/local/bin/alloy

# Start Alloy
sudo systemctl start alloy
```

**Verification.**

```bash
# Container or systemd status
docker compose ps alloy
# OR
systemctl status alloy

# Alloy ready endpoint
curl -s http://localhost:12345/-/ready

# Check that logs are flowing into Loki
# (run this on prod-mon-0)
curl -G -s 'http://localhost:3100/loki/api/v1/labels' | jq
# Should still list all hosts

# In Grafana, query {host="<host>"} for recent logs
```

**Rollback.**

Same procedure with the prior version.
Alloy has no persistent state worth preserving — its positions file (where it left off in each log source) just resets to "tail from current time" on a restart.

### cAdvisor

**Current pin:** `0.56.2`.

**Why this version:** Latest stable.
cAdvisor v0.54+ is required for compatibility with Docker's containerd snapshotter (the default in Docker 29+).
The image registry moved from `gcr.io` to `ghcr.io` in v0.54, and the tag format dropped the `v` prefix on the new registry.
See [gotchas.md](gotchas.md) for the full story.

**Upgrade procedure.**

cAdvisor releases roughly every 1-2 months.
Find the new version on <https://github.com/google/cadvisor/releases>.
The full image reference is `ghcr.io/google/cadvisor:<version>` (no `v` prefix).

Edit the compose file (in `/opt/monitoring/` or `/opt/monitoring-agents/`):

```yaml
services:
  cadvisor:
    image: ghcr.io/google/cadvisor:0.57.0 # change version here
```

Apply:

```bash
cd /opt/monitoring  # or /opt/monitoring-agents/
sudo docker compose pull cadvisor
sudo docker compose up -d cadvisor
```

**Verification.**

```bash
# cAdvisor metrics endpoint
curl -s http://localhost:8080/metrics | head

# Verify dockerVersion is populated (this is the test for whether cAdvisor
# is correctly reading container metadata)
curl -s http://localhost:8080/metrics | grep cadvisor_version_info
# dockerVersion should be a non-empty string
```

If `dockerVersion` is empty after the upgrade, cAdvisor is running but can't read Docker's container metadata.
This usually means a containerd socket mount is missing or the version is too old.
See [gotchas.md](gotchas.md).

**Rollback.**

Same procedure in reverse.
cAdvisor is stateless — no rollback complications.

### node_exporter

**Current pin:** `v1.11.1`.

**Why this version:** Latest stable.
node_exporter has been API-stable for years; upgrades are typically uneventful.

**Upgrade procedure.**

node_exporter is installed as a native binary on every host, including `prod-mon-0`, `prod-git-0`, and `prod-ipa-0`.
The procedure is the same on all of them, with one wrinkle on RHEL hosts (SELinux context).

Find the new version at <https://github.com/prometheus/node_exporter/releases>.

**On the target host:**

```bash
cd /tmp
NEW_VERSION="1.11.2"   # set the new version

curl -LO https://github.com/prometheus/node_exporter/releases/download/v${NEW_VERSION}/node_exporter-${NEW_VERSION}.linux-amd64.tar.gz
tar xzf node_exporter-${NEW_VERSION}.linux-amd64.tar.gz

# Stop the service before replacing the binary
sudo systemctl stop node_exporter

# Replace the binary using install (preserves SELinux context on RHEL)
sudo install -m 0755 -o node_exporter -g node_exporter \
  node_exporter-${NEW_VERSION}.linux-amd64/node_exporter \
  /usr/local/bin/node_exporter

# Start the service
sudo systemctl start node_exporter
```

**Verification.**

```bash
# Service status
systemctl status node_exporter

# Metrics endpoint
curl -s http://localhost:9100/metrics | head

# Verify version metric
curl -s http://localhost:9100/metrics | grep node_exporter_build_info
```

**Rollback.**

Same procedure with the prior version's binary.
node_exporter has no state.

## Cross-cutting concerns

A few things that affect the whole stack rather than any single component.

### Security advisories

Subscribe to GitHub release notifications for each project.
Or check periodically:

- <https://github.com/prometheus/prometheus/security/advisories>
- <https://github.com/grafana/grafana/security/advisories>
- <https://github.com/grafana/loki/security/advisories>
- <https://github.com/grafana/alloy/security/advisories>

For a homelab on a private network, security CVEs are lower-priority than for internet-facing deployments — but stored XSS and remote-execution issues should still be patched promptly.

### Upgrading the host OS

When `prod-mon-0`, `prod-git-0`, or `prod-ipa-0` get a major OS upgrade (e.g. Debian 13 → 14, Rocky 9 → 10), the monitoring stack mostly doesn't care.
The agents are statically linked binaries or containerized.
The exception is Docker on the Debian hosts: Docker's package may upgrade as part of a distro upgrade, which can pull in a new containerd version, which (rarely) affects cAdvisor.
If anything monitoring-related breaks after a host OS upgrade, cAdvisor is the most likely suspect.

### Upgrading multiple components together

Don't.
Upgrade one component at a time, verify, then move to the next.
Multi-component upgrades make problems much harder to attribute.
The full stack restart at the end is fine; the changes leading up to it should be sequential.

The exception is when two components have a known compatibility requirement (e.g. a Loki schema change might require a matching Alloy version).
In those cases, read the migration notes from both projects and plan the upgrade order carefully.

### Cadence

A reasonable upgrade cadence for this homelab is:

- **Weekly:** check for security advisories on any component
- **Monthly:** patch upgrades (e.g. `v3.11.2 → v3.11.3`)
- **Quarterly:** minor upgrades (e.g. `v3.11.x → v3.12.x`)
- **Per-major-release, on demand:** major upgrades, after reading migration notes

This is a guideline, not a rule.
The homelab doesn't have an SLA, and being a few weeks behind on patches isn't a problem.
What matters is not letting the stack drift so far behind that catching up requires multiple major upgrades chained together.
