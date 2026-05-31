## Host

|                  |                                                |
| ---------------- | ---------------------------------------------- |
| Hardware         | Virtual Machine on Proxmox (blackwall)           |
| Machine Type     | q35                                            |
| Sockets          | 1                                              |
| Cores            | 2                                              |
| CPU Type         | host (physical CPU passthrough)                |
| RAM              | 4096 MB                                        |
| Disk             | 100GB qcow2 (VirtIO SCSI, iothread enabled)    |
| Network          | VirtIO, bridge vmbr0, Proxmox firewall enabled |
| OS               | Debian 13.3 (Trixie)                           |
| IP               | 10.33.111.102                                  |
| Hostname         | netwatch.home.arpa                           |
| Start on Boot    | Yes                                            |
| QEMU Guest Agent | Enabled                                        |

## Overview

Centralized observability stack for the home.arpa lab.
A PLG stack (Prometheus, Loki, Grafana) collects metrics, stores logs, and renders both in dashboards.
Prometheus handles metrics, Loki handles logs.
Traces are not part of the stack today.

The architecture is hub-and-spoke.
The hub runs on `netwatch` and holds the storage and visualization layer.
Every other host runs lightweight agents that push metrics and logs to the hub.
The setup is single-tenant and monolithic, sized for tens of hosts and 90 days of retention.

## Architecture

A single host (`netwatch`) runs the storage and visualization layer:

- **Prometheus** — pulls metrics from agents on every host
- **Loki** — receives logs pushed by agents on every host
- **Grafana** — queries both and renders dashboards
- **cAdvisor** — exposes container metrics for the local host
- **Alloy** — ships local container logs to Loki
- **node_exporter** — exposes local host metrics for Prometheus

Every other host runs a subset of those agents:

- **node_exporter** — host-level metrics, native binary on every host
- **cAdvisor** — container metrics, only on hosts running Docker
- **Alloy** — log shipping, configuration varies by OS family

Agents send to the central server over the home.arpa network.
The relationship is one-way: agents push to (or are pulled by) the central server.
Hosts are unaware of each other.

## Repository layout

```
monitoring/
├── server/                     # central host (netwatch)
│   ├── docker-compose.yml      # all stack services
│   ├── prometheus/             # scrape config
│   ├── loki/                   # log storage config
│   ├── alloy/                  # local agent config
│   └── grafana/                # provisioning (datasources + dashboards)
├── agents/                     # everything that runs on monitored hosts
│   ├── debian/                 # Docker-based agent stack
│   └── rhel/                   # systemd-based agent stack
└── docs/
    ├── architecture.md         # detailed component breakdown
    ├── decisions.md            # design choices and tradeoffs
    ├── gotchas.md              # painful lessons from the build
    └── upgrading.md            # version pin rationale + upgrade procedures
```

## Where to start

**Standing up the central server from scratch:** see
[server/README.md](server/README.md).

**Adding a new Debian host:** see
[agents/debian/README.md](agents/debian/README.md). Applies to any host running Docker.

**Adding a new RHEL/Rocky host:** see
[agents/rhel/README.md](agents/rhel/README.md). Native systemd services, journald log source.

**Wondering why something looks the way it does:** see
[docs/decisions.md](docs/decisions.md) for design rationale & [docs/gotchas.md](docs/gotchas.md) for the painful lessons.

## Current deployment

| Host         | OS        | Role                      | Agents                                         |
| ------------ | --------- | ------------------------- | ---------------------------------------------- |
| `netwatch` | Debian 13 | Central monitoring server | node_exporter, cAdvisor, Alloy (containerized) |
| `soulkiller` | Debian 13 | Gitea host                | node_exporter, cAdvisor, Alloy (containerized) |
| `mikoshi` | Rocky 9.7 | FreeIPA server            | node_exporter, Alloy (systemd)                 |

Logs and metrics from all three hosts are queryable from the central Grafana instance at `http://netwatch.home.arpa:3000`.

> Additional deployments and detailed architectural breakdowns will be documented in [docs/architecture.md](docs/architecture.md) as the fleet grows.
