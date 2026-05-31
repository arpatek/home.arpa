# Agents

Monitoring agents that run on every host the central server tracks.
The agents do two things: expose host-level metrics for Prometheus to scrape, and ship logs to Loki.

## Two patterns, one per OS family

The agent stack looks different depending on what the host is.
Hosts that already run Docker get the agents as containers.
Hosts that don't run Docker get the agents as native systemd services.

[debian/](debian/) — containerized agents, deployed via Docker Compose.
Applies to any Debian-family host (Debian, Ubuntu) running Docker.
Currently used on `prod-git-0`.

[rhel/](rhel/) — native systemd agents, binaries installed under `/usr/local/bin/`.
Applies to RHEL-family hosts (RHEL, Rocky Linux, AlmaLinux).
Currently used on `prod-ipa-0`.

[rpi/](rpi/) — native systemd agents, ARM64 binaries, no Docker.
Applies to Raspberry Pi OS (Debian-based, ARM64) hosts that don't run Docker.
Currently used on `netrunner-rpi`.

## What each pattern includes

|                 | Debian                        | RHEL                           | RPi                            |
| --------------- | ----------------------------- | ------------------------------ | ------------------------------ |
| node_exporter   | native systemd                | native systemd                 | native systemd                 |
| cAdvisor        | container (Docker hosts only) | not included                   | not included                   |
| Alloy           | container                     | native systemd                 | native systemd                 |
| Log source      | Docker container stdout       | journald                       | journald                       |
| Firewall config | not needed (Debian default)   | firewalld rules required       | not needed (iptables-managed)  |
| SELinux         | not applicable                | requires context-aware install | not applicable                 |
| Architecture    | amd64                         | amd64                          | arm64                          |

The two patterns are deliberately different because the OS conventions are different.
For the reasoning behind the dual-runtime decision, see [../docs/decisions.md](../docs/decisions.md).

## Adding a new host

Pick the pattern that matches the host's OS family.
Follow the README in that subdirectory.
The pattern works for any host of the matching family — there's nothing host-specific in the deployment procedure.

The only thing that varies per-host is the `host` label value in the Alloy configuration.
Each agent's logs need to be uniquely identifiable in Loki, so the label is set to the short hostname (e.g. `prod-git-0`, `prod-ipa-0`).
This is the only line in `config.alloy` that should differ between two hosts of the same OS family.
