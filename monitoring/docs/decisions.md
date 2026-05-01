# Decisions

The deliberate design choices made while building this monitoring stack.
Each entry names the decision, the alternatives I considered, what I chose, and why.

This doc exists because "why" tends to fade fastest from memory.
The configs themselves show _what_ the system does.
This file shows what the alternatives were and what made me pick this path.

Major decisions get a full treatment.
Smaller decisions are listed as paragraphs at the end.

## Hub-and-spoke topology with a single central server

**Decision.** One central host (`prod-mon-0`) runs Prometheus, Loki, and Grafana.
Every other host runs lightweight agents that report into the central server.
There is one source of truth, queried from one Grafana instance.

**Alternatives considered.**

_Per-host stacks._ Each host runs its own Prometheus and Grafana, queries are local.
This is simpler per-host but creates N copies of everything.
Cross-host queries become impossible without federation.
Backups multiply.

_Federation._ Multiple Prometheus instances scrape locally and a top-level Prometheus federates from all of them.
Standard at large scale, useful when network boundaries or scrape volumes demand it.
Overkill for a homelab with sub-100 metric series per host.

_Push gateway centralization._ Hosts push to a central Pushgateway, Prometheus scrapes the gateway.
Sometimes used to capture metrics from short-lived jobs.
Doesn't apply here — all my targets are long-running services.

**Why hub-and-spoke.**

Single source of truth.
Every metric, every log, every dashboard query goes through one Grafana.
There's no "which Prometheus has the data I want" decision to make at query time.

Backup is simpler.
One host's data directories cover the whole observability state.
A snapshot of `/opt/monitoring/` on `prod-mon-0` captures everything.

It scales fine for the target.
Tens of hosts, sub-thousands of metric series each, 90 days retention — comfortably within what a single 4GB-RAM VM can handle.
The pain points of a centralized stack (TSDB churn, query load, ingest backpressure) all kick in at scales much larger than this.

The decision to revisit would be: at the point where `prod-mon-0` is consistently at 80%+ memory or query latency exceeds a few seconds, federation becomes worth the complexity.
For this homelab, that's a future-state problem, not a current-state one.

## Alloy over Promtail for log shipping

**Decision.** All log shipping uses Grafana Alloy.
Promtail, the historical default for shipping logs to Loki, is not used anywhere in this stack.

**Alternatives considered.**

_Promtail._ The original Loki agent, mature, well-documented, exactly one job (read files, ship to Loki).
Many existing tutorials and dashboards assume it.

_Vector._ A different log shipper (and metrics, and traces) from a different vendor.
More general-purpose than either Promtail or Alloy.
Strong tool, but a third ecosystem to learn.

_Filebeat._ Elastic's log shipper.
Common in ELK-stack environments.
Misaligned with a Grafana-centered observability stack.

**Why Alloy.**

Promtail support ended February 28, 2026.
Grafana Labs has consolidated their agent strategy around Alloy, which is a single binary that handles metrics scraping, log shipping, and trace forwarding in one process.
Promtail still works today, but it's not getting bug fixes or features going forward.
Building a new stack on a deprecated agent is a deliberate choice to take on future migration work.

Alloy is a superset of Promtail's capabilities.
Anything Promtail does, Alloy does, with the same Loki client behavior.
The config format is different (Alloy uses a typed configuration language; Promtail uses YAML), but the underlying primitives map cleanly.

The same agent works across roles.
On the central server, Alloy ships local container logs to Loki.
On Debian hosts, Alloy runs containerized and ships container logs.
On RHEL hosts, Alloy runs as a native systemd service and reads from journald.
One agent to learn, three deployment patterns.
If I'd picked Promtail, the journald scenario would have needed a separate tool anyway because Promtail's journald support is limited.

**Why not Vector or Filebeat.**

Both are good tools.
Both are answering a slightly different question — "ship logs anywhere" rather than "ship logs to Loki specifically."
For a Grafana-centered stack, the path of least resistance is the agent that the Loki maintainers themselves recommend, which is Alloy.

If this stack ever grew to ship to multiple destinations (Loki plus Splunk plus S3, for example), Vector would become more attractive.
Right now there's one destination, and Alloy fits it well.

**Decision to revisit.**

The trigger to reconsider would be: log destinations expand beyond Loki, or Alloy's deployment story turns out to be heavier than anticipated.
The first is a real possibility long-term.
The second hasn't shown up yet — Alloy is a single binary like Promtail was, and the operational burden has been the same.

## Monolithic Loki over SSD/microservices deployment

**Decision.** Loki runs as a single process in monolithic mode.
All components — distributor, ingester, querier, compactor, ruler — live inside one container, talking to a local filesystem for chunk and index storage.

**Alternatives considered.**

_Simple Scalable Deployment (SSD)._ Loki's middle-tier topology, splitting components into "read path," "write path," and "backend" services.
Designed for setups too large for monolithic but not large enough to justify full microservices.
Requires object storage (S3, MinIO) instead of local filesystem.

_Microservices._ Each Loki component runs as its own service, independently scalable.
This is what Grafana Cloud runs internally.
Designed for ingestion volumes in the terabytes-per-day range and query loads that benefit from independent component scaling.
Requires object storage, plus a memberlist or consul ring for component coordination.

**Why monolithic.**

Scale matches deployment.
Monolithic Loki is documented as appropriate for "up to approximately 20GB per day" of log ingestion.
This homelab generates a tiny fraction of that — a few MB per day across all hosts combined, almost all of it Docker container stdout.
SSD or microservices would be solving a problem that doesn't exist here.

Local filesystem storage is simpler.
SSD and microservices both require object storage, which means either standing up MinIO (another service to operate) or sending data to a cloud provider (cost, network dependency, not appropriate for a homelab).
Local filesystem under `/opt/monitoring/loki/data` is one bind mount and one backup target.

Single process is easier to reason about.
When something goes wrong with Loki, the question "which component is at fault?" doesn't exist — there's only one component.
Logs come from one place.
A restart bounces everything together.

The operational cost of monolithic at this scale is genuinely zero.
There's no scenario in the next year where this homelab generates enough logs to make monolithic struggle.
Adopting SSD now would be premature optimization with real ongoing complexity cost and no current benefit.

**The migration path is real if needed.**

If log volume ever grows to where monolithic struggles, the migration to SSD is well-documented.
The schema (v13) and the chunk format are the same across all three deployment modes.
What changes is the config and the storage backend.
This means the choice of monolithic isn't locking in a future where I have to rebuild from scratch — it's deferring complexity until it's earned.

**Decision to revisit.**

The trigger to reconsider would be: ingestion approaching 10GB/day sustained, or query latency on multi-day ranges exceeding a few seconds.
Neither is on the horizon for this stack.
If the homelab ever grows to include high-volume application logs (a busy web service, a chatty Kubernetes cluster), this entry gets revisited.

## Containerized agents on Docker hosts, native systemd Alloy on RHEL

**Decision.** On hosts that already run Docker (`prod-mon-0`, `prod-git-0`), the monitoring agents — node_exporter, cAdvisor, Alloy — run as containers, defined in a docker-compose.yml.
On `prod-ipa-0` (Rocky Linux, no Docker), node_exporter and Alloy run as native systemd services with the binaries installed under `/usr/local/bin`.

**Alternatives considered.**

_All native systemd, everywhere._ Install the agent binaries directly on every host as systemd services, regardless of OS.
Consistent across the fleet.
But it skips the orchestration layer that Docker hosts already have, and pulls in three more systemd units per Docker host on top of the existing Compose stack.

_All containerized, everywhere — install Docker on RHEL._ Run the agents in containers on RHEL too.
Adds Docker to a host that doesn't otherwise need it, just to support monitoring.
On `prod-ipa-0` specifically, Docker would compete with FreeIPA for resources and add an attack surface to a host that's deliberately kept minimal.

_Different agents per host class._ Use one set of tools for Docker hosts and a different set for non-Docker hosts.
Doubles the learning surface.
Rejected immediately.

**Why dual runtime.**

The runtime fits what the host already does.
Docker hosts run Compose stacks for everything else — Gitea, the monitoring server, future workloads.
Adding the agents to a parallel Compose project (`/opt/monitoring-agents/`) means they live in the same operational world as the other services on that host.
Same `docker compose` commands to start, stop, view logs, upgrade.

RHEL hosts run native services for everything else — FreeIPA, BIND, SSSD, NetworkManager.
Adding the agents as native systemd services means they live in the same operational world as the rest of the host.
Same `systemctl` commands to start, stop, view logs.

The mental model on each host stays consistent.
A future-me debugging on `prod-ipa-0` doesn't have to context-switch between "is this a Docker thing or a systemd thing?"
Everything on that host is a systemd thing.

The agents themselves don't care.
node_exporter and Alloy run identically as binaries or as containers — the configuration is the same, the metrics output is the same, the resource footprint is the same.
What changes is the deployment mechanism.

**Why not install Docker on RHEL just for consistency.**

This came up during the build and I rejected it deliberately.
RHEL 9's recommended container path is Podman, not Docker.
Installing Docker on `prod-ipa-0` would mean either using the upstream `docker-ce` repo (going off the Red Hat path) or using Podman with `podman-compose` (a different tool that's not 1:1 compatible with Docker Compose).
Both options add complexity to a host whose entire purpose is to be the most boring possible identity server.

The cost of the dual-runtime decision is that two patterns exist in the repo.
The benefit is that each host stays appropriate to its OS.
For a fleet of three hosts, the cost is genuinely small.

**Decision to revisit.**

If `prod-ipa-0` ever grows to need containers — say, for a tool that only ships as an OCI image — the right runtime on RHEL is Podman, not Docker.
Podman is what Red Hat recommends, integrates cleanly with systemd via quadlet units, and doesn't require a daemon.
At that point I'd reconsider whether the agents move into containers too, but the answer probably stays the same: native systemd Alloy and node_exporter blend in with the rest of the host's services, while Podman containers would be a parallel system to manage.

The k3s cluster, when it gets built, runs containerd natively and isn't covered by this decision either way.

## Smaller decisions

The following choices were deliberate but didn't have alternatives weighty enough to merit full treatment.
Documented as paragraphs because the reasoning is short.

**Push to Loki, pull from Prometheus.** Loki and Prometheus have opposite default models — Loki receives pushed data, Prometheus actively scrapes. This stack uses both defaults rather than running a Pushgateway in front of Prometheus or a Loki agent that pulls. The push/pull split reflects what each tool is good at: Prometheus's scrape model gives precise control over collection timing and target discovery; Loki's push model lets agents apply local relabeling and filtering before logs leave the source host. Fighting either default would add complexity for no real benefit at this scale.

**Manual binary install over package manager for node_exporter.** Both Debian and RHEL ship node_exporter packages, but the versions in distro repos lag upstream by months. The agent binaries are installed manually under `/usr/local/bin` with custom systemd units. This matches the version-pinning philosophy used for the container images: I choose when to update, not the package manager. The cost is that updates aren't automatic. The benefit is that an `apt upgrade` or `dnf update` won't surprise me by changing a monitoring component.

**Schema v13 for Loki.** Loki has had multiple schema versions over the years (v9 through v13). The current docs recommend v13 for new installs, with `tsdb` index type and `filesystem` object store. Older schemas still work but are deprecated for new deployments. Schema migrations are one-way and require careful handling, so picking the right schema upfront avoids future migration work.

**Separate `/opt/monitoring-agents/` compose project on non-server hosts.** On `prod-git-0`, the monitoring agents live in their own compose project rather than being added to `/opt/gitea/docker-compose.yml`. The reasoning is that monitoring is a secondary function on that host — the host's job is running Gitea. Restarting Gitea (for an upgrade, a config change, anything) shouldn't bounce the monitoring agents. Two separate compose projects mean each is operated independently. The `-agents` suffix in the directory name distinguishes "this host runs monitoring agents" from "this host runs the monitoring stack."

**Bind mounts under `/opt/<service>/{config,data}` with config read-only.** Docker offers two persistence options: named volumes (managed by Docker, stored under `/var/lib/docker/volumes/`) and bind mounts (mapped to host directories I control). This stack uses bind mounts everywhere. They're easier to back up (just `tar` the host directory), easier to inspect (`ls` works), and easier to reason about ownership-wise. Configs are mounted `:ro` so a compromised container can't rewrite its own config. Data directories are read-write because the services need to persist state.

**Short `host` label on logs (`prod-mon-0`, not the FQDN).** Loki labels carry a `host` value that identifies which machine the logs came from. I used the short hostname rather than the FQDN. The reasoning is that the FQDN domain (`home.arpa`) is the same for every host in this stack, so it adds noise to every log query without disambiguating anything. If this stack ever spans multiple domains, the label gets reconsidered.

**Version pinning over `:latest` tags.** Every image reference in every compose file is pinned to a specific version. No `:latest`, no floating tags. This makes the stack reproducible — the same compose file today produces the same containers next year. Upgrades happen deliberately: I read the changelog, change the version number, apply, verify. The cost is occasional manual upgrade work. The benefit is that nothing changes underneath me without my consent.

**Provisioning over UI configuration in Grafana.** Grafana datasources and dashboards are defined in YAML and JSON files under `grafana/provisioning/`, not configured through the UI. The provisioned objects have `editable: false` to prevent UI drift. The reason is the same as version pinning: the stack should be reproducible from the files in the repo. UI-based configuration creates state that's only visible by logging into Grafana, which means rebuilding the host requires remembering what was clicked through. Provisioning makes the configs source-of-truth.

**90-day retention for both metrics and logs.** Prometheus retention is set with `--storage.tsdb.retention.time=90d`. Loki retention is set with `retention_period: 2160h` (90 days in hours, since Loki wants the duration in `h`). Could have been 30 days (the most common default) or 180 days. 90 was chosen because it's long enough to catch monthly patterns and quarterly comparisons, the disk has room for it, and it's a round number. If retention ever needs adjusting, both flags are documented in `docs/architecture.md` so the change is one place per service.
