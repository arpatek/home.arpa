# Pi-hole

## Host

|          |                                                                  |
| -------- | ---------------------------------------------------------------- |
| Hardware | Raspberry Pi 4B, 8GB RAM, SanDisk 256GB MicroSD, Argon NEO Case |
| OS       | Raspberry Pi OS Lite (based on Debian 13 Trixie)                 |
| IP       | 10.33.111.141                                                    |
| Hostname | netrunner                                                    |

## Overview

Pi-hole v6 running on `netrunner`, serving as the network's DNS resolver, DHCP server, and content blocker.
It handles ad blocking and NSFW filtering for all devices on the `10.33.111.0/24` network and the WireGuard `10.10.10.0/24` subnet.

FreeIPA (`mikoshi`) is the primary DNS authority for the `home.arpa` domain.
Pi-hole handles upstream resolution to Cloudflare and content filtering for all devices.
Non-enrolled devices (phones, laptops, IoT) use Pi-hole for DNS — both instances are advertised, see [High availability](#high-availability).

`home.arpa` is reserved for private local network use per [RFC 8375](https://datatracker.ietf.org/doc/html/rfc8375).

## High availability

A second Pi-hole runs on `edgerunner` (`10.33.111.142`) as a redundant resolver. The two are independent standalone Pi-hole v6 instances kept configuration-identical by `nebula-sync` — not a cluster.

| Instance     | IP              | Role                                              |
| ------------ | --------------- | ------------------------------------------------- |
| `netrunner`  | `10.33.111.141` | Primary — config source of truth, sole DHCP server |
| `edgerunner` | `10.33.111.142` | Replica — DNS only, DHCP off                       |

Clients receive both addresses as DNS servers via DHCP option 6 (`netrunner` first, `edgerunner` second). Failover happens at the client resolver: if one instance is down, clients roll to the other — no VIP, no failover daemon.

`nebula-sync` pushes `netrunner`'s configuration to `edgerunner` hourly via a `systemd` timer, enforcing identical blocklists, upstreams, and DNS settings while **excluding DHCP** (only `netrunner` serves DHCP). See [docs/architecture.md](docs/architecture.md) for the sync model, [docs/decisions.md](docs/decisions.md) for why nebula-sync over keepalived, and [nebula-sync/](nebula-sync/) for the unit files.

## Repository layout

```
pihole/
├── README.md                   # this file — config reference and DNS record inventory
├── pihole.toml.example         # Pi-hole v6 configuration (non-default values marked ### CHANGED)
├── nebula-sync/                # config replication to the edgerunner replica
│   ├── nebula-sync.service     # oneshot systemd unit (runs on netrunner)
│   ├── nebula-sync.timer       # hourly timer
│   └── nebula-sync.env.example # env file template (secrets redacted)
└── docs/
    ├── architecture.md         # DNS resolution flow, network role, HA sync model
    ├── decisions.md            # design choices and rationale
    ├── gotchas.md              # issues encountered during setup
    └── upgrading.md            # Pi-hole upgrade procedures
```

## Installation

Installed bare metal using the official Pi-hole one-line installer on Raspberry Pi OS Lite (Debian 13 Trixie):

```bash
curl -sSL https://install.pi-hole.net | bash
```

## Configuration

### DHCP

Pi-hole serves DHCP for the `10.33.111.0/24` network via the `eth0` interface.
All devices on the network receive an IP — unknown clients are not ignored.

| Setting        | Value                                        |
| -------------- | -------------------------------------------- |
| Range          | `10.33.111.2` – `10.33.111.254`              |
| Gateway        | `10.33.111.1`                                |
| Lease time     | `24h`                                        |
| Local domain   | `home.arpa`                                  |
| DNS advertised | `10.33.111.141`, `10.33.111.142` (option 6)  |

DHCP runs only on `netrunner`. Both Pi-hole IPs are advertised to clients via a `dhcp-option=6` line in `misc.dnsmasq_lines` (see [High availability](#high-availability) and [docs/gotchas.md](docs/gotchas.md)).

### Upstream DNS

| Server    | Provider               |
| --------- | ---------------------- |
| `1.1.1.1` | Cloudflare (primary)   |
| `1.0.0.1` | Cloudflare (secondary) |

### DNS settings

- `home.arpa` forward queries and `10.33.111.0/24` reverse lookups delegated to FreeIPA (`10.33.111.100`) via `dns.revServers`
- `10.10.10.0/24` (WireGuard) reverse lookups answered locally
- Private reverse lookups not forwarded upstream (`bogusPriv`)
- `misc.dnsmasq_lines` holds two entries:
  - `local=/local/` — mDNS domain answered immediately (prevents 5–20s upstream timeout)
  - `dhcp-option=6,10.33.111.141,10.33.111.142` — advertises both Pi-hole instances as DNS servers via DHCP
- `dhcp.multiDNS = false` — mDNS DHCP registration disabled (must stay `false`; enabling it injects a duplicate option 6 — see [docs/gotchas.md](docs/gotchas.md))
- Listening mode: `ALL` — serves both LAN and WireGuard clients on `10.10.10.0/24`
- NTP: `us.pool.ntp.org`

### Web interface

Accessible at `https://netrunner.home.arpa/admin/` on port 443.

### Blocklists

| List                                                                                                  | Purpose                   |
| ----------------------------------------------------------------------------------------------------- | ------------------------- |
| [Hagezi Pro](https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/pro.txt)             | Ad and tracker blocking   |
| [Hagezi NSFW](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/nsfw.txt)         | NSFW content filtering    |
| [Hagezi TIF](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt)           | Threat intelligence feeds |

### Local DNS records

Pi-hole no longer holds `home.arpa` records.
All forward and reverse lookups for the local domain are delegated to FreeIPA via `dns.revServers`.

The only local records in `dns.hosts` are six `arpatek.dev` split-horizon entries that resolve public subdomains to the internal k3s worker IP (`10.33.111.104`) rather than the public address.

| Hostname            | IP              |
| ------------------- | --------------- |
| `git.arpatek.dev`   | `10.33.111.104` |
| `man.arpatek.dev`   | `10.33.111.104` |
| `gf.arpatek.dev`    | `10.33.111.104` |
| `pm.arpatek.dev`    | `10.33.111.104` |
| `pi.arpatek.dev`    | `10.33.111.104` |
| `pve.arpatek.dev`   | `10.33.111.104` |
