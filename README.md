# home.arpa

Homelab infrastructure-as-code documentation.
A single Proxmox VE host (`devstem`) runs all lab services as virtual machines.

## Services

| Directory | Host | IP | Purpose |
| --------- | ---- | -- | ------- |
| [proxmox/](proxmox/) | `devstem` | `10.33.111.44` | Proxmox hypervisor — all VMs live here |
| [ipa/](ipa/) | `prod-ipa-0` | `10.33.111.100` | FreeIPA — identity, Kerberos, DNS authority for `home.arpa` |
| [gitea/](gitea/) | `prod-git-0` | `10.33.111.101` | Gitea — Git hosting, container registry, CI via act_runner |
| [monitoring/](monitoring/) | `prod-mon-0` | `10.33.111.102` | PLG observability stack — Prometheus, Loki, Grafana |
| [k3s/](k3s/) | `prod-k3s-*` | `10.33.111.103–105` | k3s cluster — runs `arpatek.dev` |
| [pihole/](pihole/) | `netrunner-rpi` | `10.33.111.141` | Pi-hole — DNS resolution, DHCP, ad blocking |
| [wireguard/](wireguard/) | `netrunner-rpi` | `10.33.111.141` | WireGuard VPN — remote access to the lab |

## Lab docs

- [docs/architecture.md](docs/architecture.md) — overall topology, service dependencies, state layout
- [docs/network.md](docs/network.md) — IP assignments, DNS hierarchy, VPN, public exposure
