# home.arpa

Homelab infrastructure-as-code documentation.
A single Proxmox VE host (`blackwall`) runs all lab services as virtual machines.

## Services

| Directory | Host | IP | Purpose |
| --------- | ---- | -- | ------- |
| [proxmox/](proxmox/) | `blackwall` | `10.33.111.44` | Proxmox hypervisor — all VMs live here |
| [ipa/](ipa/) | `mikoshi` | `10.33.111.100` | FreeIPA — identity, Kerberos, DNS authority for `home.arpa` |
| [gitea/](gitea/) | `soulkiller` | `10.33.111.101` | Gitea — Git hosting, container registry, CI via act_runner |
| [monitoring/](monitoring/) | `netwatch` | `10.33.111.102` | PLG observability stack — Prometheus, Loki, Grafana |
| [k3s/](k3s/) | `erebus`, `sandevistan`, `kerenzikov` | `10.33.111.103–105` | k3s cluster — runs `arpatek.dev` |
| [pihole/](pihole/) | `netrunner`, `edgerunner` | `10.33.111.141`, `10.33.111.142` | Pi-hole — DNS resolution, DHCP, ad blocking (HA pair) |
| [wireguard/](wireguard/) | `netrunner` | `10.33.111.141` | WireGuard VPN — remote access to the lab |
| [nas/](nas/) | `netrunner`, `edgerunner` | `10.33.111.141`, `10.33.111.142` | SMB storage — RAID1 `tank`, plus `nas` and `stor` shares |

## Lab docs

- [docs/architecture.md](docs/architecture.md) — overall topology, service dependencies, state layout
- [docs/network.md](docs/network.md) — IP assignments, DNS hierarchy, VPN, public exposure
