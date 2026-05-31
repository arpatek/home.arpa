# Gitea

## Host

|                  |                                                |
| ---------------- | ---------------------------------------------- |
| Hardware         | Virtual Machine on Proxmox (blackwall)           |
| Machine Type     | q35                                            |
| Sockets          | 1                                              |
| Cores            | 4                                              |
| CPU Type         | host (physical CPU passthrough)                |
| RAM              | 4096 MB                                        |
| Disk             | 80GB LVM thin (VirtIO SCSI, iothread enabled)  |
| Network          | VirtIO, bridge vmbr0, Proxmox firewall enabled |
| OS               | Debian 13.3 (Trixie)                           |
| IP               | 10.33.111.101                                  |
| Hostname         | soulkiller.home.arpa                           |
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

## Deployment

How to stand up the Gitea stack from scratch on a fresh Debian 13 host.

### Prerequisites

Before starting, the host needs:

- Debian 13 (Trixie) installed and reachable on the `home.arpa` network
- DNS resolution working — `getent hosts soulkiller.home.arpa` should return `10.33.111.101`
- IPA client enrolled so SSH and sudo work for `arpatek`
- Outbound internet access to pull Docker images

Install Docker using the official upstream repository (the Debian-packaged `docker.io` is older):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add your admin user to the docker group:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### Deploy the stack

Create the directory layout on `soulkiller`:

```bash
sudo mkdir -p /opt/gitea/{data,config,postgres,runner}
```

Copy the configs from the local repo clone:

```bash
scp gitea/docker-compose.yml soulkiller.home.arpa:/tmp/
```

Move the file into place on `soulkiller`:

```bash
sudo mv /tmp/docker-compose.yml /opt/gitea/
```

Create the `.env` file from the example:

```bash
scp gitea/.env.example soulkiller.home.arpa:/tmp/
```

On `soulkiller`:

```bash
sudo mv /tmp/.env.example /opt/gitea/.env
sudo chmod 600 /opt/gitea/.env
sudo vim /opt/gitea/.env   # fill in POSTGRES_PASSWORD, GITEA_DB_PASSWORD
```

`GITEA_RUNNER_TOKEN` is obtained from the Gitea web UI after the first startup.
Leave it empty for now and come back to it after Gitea is running.

Bring up the database and Gitea first:

```bash
cd /opt/gitea
sudo docker compose up -d db gitea
```

### First-run configuration

Visit `http://soulkiller.home.arpa:3000` in a browser.
Gitea shows a one-time install wizard on the first run.
The database settings are pre-populated from the environment variables — confirm them but do not change them.
Set the admin user account.

After the wizard completes, generate a runner registration token:

- Go to **Site Administration > Actions > Runners**
- Click **Create new Runner** and copy the token

Set the token in `/opt/gitea/.env` on `soulkiller`:

```bash
sudo vim /opt/gitea/.env   # set GITEA_RUNNER_TOKEN
```

Start the runner:

```bash
cd /opt/gitea
sudo docker compose up -d runner
```

### Verification

Check all containers are running:

```bash
docker compose ps
```

All three services (`gitea-db`, `gitea`, `gitea-runner`) should show `Up`.

Verify the runner registered:

```bash
docker compose logs runner --tail 20
# Should contain: "declare successfully"
```

Verify Gitea is reachable and reports its version:

```bash
curl -s http://soulkiller.home.arpa:3000/api/v1/version | jq
```

## Operational notes

**Restart a service:**

```bash
cd /opt/gitea
docker compose restart gitea   # or db, runner
```

**View logs:**

```bash
docker compose logs -f gitea
docker compose logs -f runner
```

**Stop the stack cleanly:**

```bash
cd /opt/gitea
docker compose down
```

Data persists across `down`/`up` because all state is in bind-mounted directories, not Docker-managed volumes.

**Database backup:**

```bash
docker exec gitea-db pg_dump -U gitea gitea > gitea_backup_$(date +%Y%m%d).sql
```

Run before any Gitea upgrade.
See [docs/upgrading.md](docs/upgrading.md) for full upgrade procedures.

## Current deployment

| Service    | Image                   |
| ---------- | ----------------------- |
| Gitea      | `gitea/gitea:1.26.1`    |
| PostgreSQL | `postgres:16.13`        |
| Runner     | `gitea/runner:0.6.1`    |

Gitea 1.26.1 includes the fix for CVE-2026-27780 (branch protection bypass).
The runner image was renamed from `gitea/act_runner` to `gitea/runner` as of the 0.6.x series.
