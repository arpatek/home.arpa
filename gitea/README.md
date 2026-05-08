# Gitea

## Host

|                  |                                                |
| ---------------- | ---------------------------------------------- |
| Hardware         | Virtual Machine on Proxmox (devstem)           |
| Machine Type     | q35                                            |
| Sockets          | 1                                              |
| Cores            | 4                                              |
| CPU Type         | host (physical CPU passthrough)                |
| RAM              | 4096 MB                                        |
| Disk             | 80GB LVM thin (VirtIO SCSI, iothread enabled)  |
| Network          | VirtIO, bridge vmbr0, Proxmox firewall enabled |
| OS               | Debian 13.3 (Trixie)                           |
| IP               | 10.33.111.101                                  |
| Hostname         | prod-git-0.home.arpa                           |
| Start on Boot    | Yes                                            |
| QEMU Guest Agent | Enabled                                        |

## Overview

Self-hosted Git service for the home.arpa lab.
Gitea is not the primary VCS here — that role belongs to Codeberg.
Its purpose in this lab is twofold: mirroring repos from Codeberg for local availability, and serving as a CI/CD target for act_runner pipeline experimentation.

The CI work is practice-oriented and points toward a specific goal.
The planned capstone is running Gitea Actions pipelines against a FastAPI project deployed to the k3s cluster.
Until k3s is built, act_runner is present but lightly exercised.

## Stack

Three services run together via Docker Compose at `/opt/gitea/`:

- **Gitea** — Git host and web UI, exposed on port 3000 (HTTP) and 2222 (SSH)
- **PostgreSQL 16** — relational backend for Gitea's data store
- **act_runner** — Gitea's native CI runner; executes Gitea Actions pipelines in Docker containers

All three share a dedicated bridge network (`gitea-net`).
Persistent data lives under `/opt/gitea/{data,config,postgres,runner}` as bind mounts on the host.

## Repository layout

```
gitea/
├── docker-compose.yml          # service definitions for all three components
├── .env.example                # required environment variables with placeholder values
└── docs/
    ├── architecture.md         # component breakdown and data flow
    ├── decisions.md            # PostgreSQL vs SQLite, act_runner vs hosted CI
    ├── gotchas.md              # issues encountered during the initial build
    └── upgrading.md            # version pin rationale and upgrade procedures
```

## Current deployment

| Service    | Image                     | Note                                       |
| ---------- | ------------------------- | ------------------------------------------ |
| Gitea      | `gitea/gitea:latest`      | Needs pin to 1.26.x+ (CVE-2026-27780 fix) |
| PostgreSQL | `postgres:16`             | Major version pinned; patch version is not |
| act_runner | `gitea/act_runner:latest` | Needs pin to 0.4.1                         |

The `:latest` tags on Gitea and act_runner are a known anti-pattern.
They will be replaced with explicit version pins in a dedicated session alongside the CVE-2026-27780 patch (branch protection bypass, fixed in Gitea 1.26.0).
