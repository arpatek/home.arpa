# Upgrading

Procedures for upgrading the components of this Gitea stack.

This doc covers what's pinned, why those specific versions were chosen, and how to upgrade each component.
For the "why pin at all" reasoning, see [decisions.md](decisions.md).

## Version pin philosophy

Every image in this stack is pinned to a specific version.
No `:latest` tags, no floating versions.
Upgrades are deliberate: read the changelog, change the version number, apply, verify.

The cost is occasional manual upgrade work.
The benefit is that nothing changes underneath the stack without consent.

Pinned stacks accumulate drift over time.
A reasonable cadence: check for security advisories monthly, apply patch upgrades monthly, evaluate minor upgrades quarterly.

## Currently pinned versions

| Component  | Pinned version | Image            |
| ---------- | -------------- | ---------------- |
| Gitea      | `1.26.1`       | `gitea/gitea`    |
| PostgreSQL | `16.13`        | `postgres`       |
| Runner     | `0.6.1`        | `gitea/runner`   |

Note on the runner image: the image was `gitea/act_runner` through the 0.x series and was renamed to `gitea/runner` starting with 0.6.x.
The old image is deprecated on Docker Hub.
All future upgrades use `gitea/runner`.

A `v1.0.x` series was released on 2026-05-08 but had not landed on Docker Hub at pin time.
The next runner upgrade should target `gitea/runner:1.0.x` once it's available.

## Per-component upgrade procedures

### Gitea

**Current pin:** `1.26.1`.

**Why this version:** 1.26.0 was the first release to patch CVE-2026-27780 (branch protection bypass).
1.26.1 includes additional stability fixes within the 1.26.x line.

**Upgrade procedure.**

Check <https://github.com/go-gitea/gitea/releases> for new releases.
Gitea requires upgrading through minor versions sequentially — don't skip from 1.25.x to 1.27.x without passing through 1.26.x.
Patch releases within a minor (e.g. `1.26.1 → 1.26.2`) are safe and can be applied directly.
Minor upgrades (e.g. `1.26.x → 1.27.x`) may include database migrations; Gitea runs these automatically on startup.

Before any minor version upgrade, take a database snapshot:

```bash
docker exec gitea-db pg_dump -U gitea gitea > gitea_backup_$(date +%Y%m%d).sql
```

Edit `gitea/docker-compose.yml` in the repo:

```yaml
services:
  gitea:
    image: gitea/gitea:1.26.2  # new version here
```

Copy and apply on `soulkiller`:

```bash
scp gitea/docker-compose.yml soulkiller.home.arpa:/opt/gitea/
ssh soulkiller.home.arpa "cd /opt/gitea && sudo docker compose pull gitea && sudo docker compose up -d gitea"
```

**Verification.**

```bash
# Container status
docker compose ps gitea

# Running version via API
curl -s http://soulkiller.home.arpa:3000/api/v1/version | jq
```

**Rollback.**

Edit the compose file back to the prior version and redeploy.
Database migrations applied during startup are not automatically reversed.
If a rollback is needed after a migration has run, restore from the pre-upgrade `pg_dump`.

### PostgreSQL

**Current pin:** `16.13`.

**Why this version:** Latest patch release in the PostgreSQL 16 major version line at pin time.

**Upgrade procedure.**

Patch upgrades within a major version (e.g. `16.13 → 16.14`) never require a dump/restore.
Edit the tag, pull, and recreate:

```bash
# In docker-compose.yml
image: postgres:16.14

# Apply
scp gitea/docker-compose.yml soulkiller.home.arpa:/opt/gitea/
ssh soulkiller.home.arpa "cd /opt/gitea && sudo docker compose pull db && sudo docker compose up -d db"
```

Major version upgrades (e.g. `16.x → 17.x`) require a dump/restore.
PostgreSQL's data directory format changes between major versions and is not forward-compatible:

```bash
# Dump before touching anything
docker exec gitea-db pg_dump -U gitea gitea > gitea_pg_backup.sql

# Stop Gitea (leave db running for the dump)
docker compose stop gitea runner

# Clear the data directory — the new major version won't start against old-format data
sudo rm -rf /opt/gitea/postgres/*

# Update the image tag in docker-compose.yml, then pull and start
docker compose pull db
docker compose up -d db

# Restore the dump
cat gitea_pg_backup.sql | docker exec -i gitea-db psql -U gitea gitea

# Start the rest
docker compose up -d
```

**Verification.**

```bash
docker exec gitea-db psql -U gitea -c "SELECT version();"
docker compose ps db
```

**Rollback.**

For patch upgrades: revert the tag, `pull`, `up -d`.
No data concerns within a major version.
For major upgrades: restore the pre-upgrade dump into the previous image version.

### Runner

**Current pin:** `0.6.1` (`gitea/runner`).

**Why this version:** Latest available on Docker Hub from the renamed `gitea/runner` image at pin time.
The `gitea/act_runner` image is deprecated; `gitea/runner` is the successor.

**Next upgrade target:** `gitea/runner:1.0.x` — a `v1.0.2` release landed on 2026-05-08 but was not yet on Docker Hub at pin time.
Check <https://hub.docker.com/r/gitea/runner/tags> and <https://gitea.com/gitea/runner/releases> before upgrading.

**Upgrade procedure.**

Edit `gitea/docker-compose.yml`:

```yaml
services:
  runner:
    image: gitea/runner:1.0.2  # new version here
```

Apply:

```bash
scp gitea/docker-compose.yml soulkiller.home.arpa:/opt/gitea/
ssh soulkiller.home.arpa "cd /opt/gitea && sudo docker compose pull runner && sudo docker compose up -d runner"
```

**Verification.**

```bash
docker compose ps runner
docker compose logs runner --tail 20
# Should see "declare successfully" within a few seconds of startup
```

**Rollback.**

The runner is stateless between jobs.
Rollback is an image tag change plus `up -d`.
Runner registration state in `/opt/gitea/runner/` persists across upgrades and rollbacks.

## Cross-cutting concerns

### Security advisories

Monitor:

- <https://github.com/go-gitea/gitea/security/advisories>
- <https://www.postgresql.org/support/security/>

CVE-2026-27780 (branch protection bypass in Gitea < 1.26.0) was the trigger for the current version pins.
Apply security releases outside the normal cadence — don't wait for the next quarterly review.

### Upgrading multiple components

Upgrade one component at a time, verify, then move to the next.
Multi-component upgrades make problems much harder to attribute.

Check Gitea's release notes for any stated minimum PostgreSQL version requirement before a minor Gitea upgrade.

### Cadence

- **Monthly:** check for security advisories, apply patch upgrades
- **Quarterly:** evaluate minor upgrades after reading changelogs
- **Per-major, on demand:** major upgrades after reading migration guides
