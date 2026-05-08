# Decisions

The design choices made while building this Gitea stack.
This file captures the "why" behind decisions that aren't obvious from the configs.

Most choices here are straightforward and get paragraph treatment.
The database backend and CI runner choices get fuller discussion because they had real alternatives worth weighing.

## PostgreSQL over SQLite

**Decision.** Gitea is backed by PostgreSQL 16.

**Alternatives considered.**

_SQLite._ Gitea's default and simplest option — a single file, zero additional services.
Works well for personal use and small teams.
The Gitea project itself recommends PostgreSQL for production over SQLite, citing SQLite's single-writer model as a limitation under concurrent load.

**Why PostgreSQL.**

SQLite is a single-writer database.
Under concurrent load — multiple users pushing simultaneously, act_runner writing CI results while Gitea handles web requests — SQLite serializes writes and can cause contention.
That's unlikely to matter at lab scale, but it's an unnecessary constraint to build in from the start.

Backup tooling is better.
`pg_dump` produces a consistent snapshot regardless of what Gitea is doing at the time.
Snapshotting SQLite safely requires either stopping Gitea or using SQLite's own backup API.
For a homelab where backups are already manual, `pg_dump` is the simpler option.

PostgreSQL is the right habit to build.
It's what production Gitea deployments use and what I'll reach for if this ever needs to migrate or scale.
Starting with SQLite and migrating later is a supported but manual process; starting with PostgreSQL avoids it entirely.

**Decision to revisit.**

The trigger would be: simplifying the stack to reduce the service count, at a point where the PostgreSQL dependency adds more friction than it's worth.
That scenario doesn't exist right now.

## act_runner over hosted CI

**Decision.** CI pipelines run on a self-hosted act_runner, not on an external service.

**Alternatives considered.**

_Woodpecker CI._ Codeberg's native CI, well-integrated and lighter than act_runner.
The right choice if Codeberg were the primary CI target.
Here, Gitea is the CI target, so act_runner is the native fit.

_GitHub Actions (via mirroring)._ Using a hosted runner means zero infrastructure to operate.
But it creates an external dependency and doesn't serve the goal of learning CI/CD infrastructure hands-on.

**Why act_runner.**

It is native to Gitea.
Gitea Actions uses a workflow syntax compatible with GitHub Actions, and act_runner is the reference implementation for executing those workflows.
There is no glue layer or format translation.

The goal is to learn CI/CD infrastructure, not to consume it.
Running act_runner means managing registration tokens, understanding how the runner polls for jobs, and seeing what happens when a job container fails mid-step.
A hosted runner abstracts all of that away.

It will connect to k3s when that cluster is built.
The planned capstone is a FastAPI deployment pipeline that builds, tests, and deploys to the k3s cluster.
act_runner, running on the same host network as the rest of the lab, can reach the k3s API directly without network exposure.

**Decision to revisit.**

If the lab needs parallel CI capacity that `prod-git-0` cannot provide, the scaling path is adding more registered runners, not replacing act_runner.
The architecture stays the same; only the runner count changes.

## Smaller decisions

**"Personal mirror + CI playground," not primary VCS.** Codeberg is the primary VCS for this project and other personal repos. Gitea hosts mirrors for local availability and provides a CI target for act_runner experimentation. This framing was deliberate: it keeps the pressure off Gitea's uptime. If `prod-git-0` goes down, no work is lost because Codeberg is the source of truth.

**Docker Compose over bare Gitea binary.** Gitea ships as a single static binary and can run under systemd without Docker. The decision to use Docker Compose matches the rest of the lab: other services on `prod-git-0` already run as Compose stacks, so Gitea fits the existing operational model. Same commands, same log access, same mental model.

**Version pinning.** The `:latest` tags currently in `docker-compose.yml` are a known anti-pattern. They will be replaced with explicit version pins alongside the CVE-2026-27780 patch. The pin rationale and upgrade procedures are documented in `docs/upgrading.md`.
