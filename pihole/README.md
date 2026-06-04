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
Non-enrolled devices (phones, laptops, IoT) use Pi-hole as their sole DNS server.

`home.arpa` is reserved for private local network use per [RFC 8375](https://datatracker.ietf.org/doc/html/rfc8375).

## Repository layout

```
pihole/
├── README.md                   # this file — config reference and DNS record inventory
├── pihole.toml                 # Pi-hole v6 configuration (non-default values marked ### CHANGED)
└── docs/
    ├── architecture.md         # DNS resolution flow and network role
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

| Setting       | Value                          |
| ------------- | ------------------------------ |
| Range         | `10.33.111.2` – `10.33.111.254` |
| Gateway       | `10.33.111.1`                  |
| Lease time    | `24h`                          |
| Local domain  | `home.arpa`                    |

### Upstream DNS

| Server    | Provider               |
| --------- | ---------------------- |
| `1.1.1.1` | Cloudflare (primary)   |
| `1.0.0.1` | Cloudflare (secondary) |

### DNS settings

- Local domain: `home.arpa` — never forwarded upstream
- Private reverse lookups not forwarded upstream (`bogusPriv`)
- Reverse DNS for both `10.33.111.0/24` and `10.10.10.0/24` answered directly by Pi-hole using its local DNS records
- Listening mode: `ALL` — serves both LAN and WireGuard clients on `10.10.10.0/24`
- NTP: `us.pool.ntp.org`

### Web interface

Accessible at `https://netrunner.home.arpa/admin/` on port 443.

### Blocklists

| List                                                                                          | Purpose                |
| --------------------------------------------------------------------------------------------- | ---------------------- |
| [StevenBlack/hosts](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts)         | Basic ad blocking      |
| [Hagezi Pro](https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/pro.txt)      | Extended blocking      |
| [Hagezi NSFW](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/nsfw.txt)  | NSFW content filtering |

### Local DNS records

Static DNS records defined in Pi-hole for all lab hosts.
These back-fill coverage for non-enrolled devices that don't use FreeIPA's BIND.

| Hostname                    | IP              |
| --------------------------- | --------------- |
| `gateway.home.arpa`         | `10.33.111.1`   |
| `blackwall.home.arpa`         | `10.33.111.44`  |
| `mikoshi.home.arpa`      | `10.33.111.100` |
| `soulkiller.home.arpa`      | `10.33.111.101` |
| `netwatch.home.arpa`      | `10.33.111.102` |
| `erebus.home.arpa` | `10.33.111.103` |
| `sandevistan.home.arpa` | `10.33.111.104` |
| `kerenzikov.home.arpa` | `10.33.111.105` |
| `ctrl-node.home.arpa`       | `10.33.111.20`  |
| `mizutani.home.arpa       | `10.33.111.22``  |
| `malorian.home.arpa       | `10.33.111.11``  |
| `gonk-01.home.arpa`       | `10.33.111.200` |
| `gonk-02.home.arpa`       | `10.33.111.201` |
| `wg-malorian.home.arpa    | `10.10.10.10``   |
| `wg-uplink.home.arpa      | `10.10.10.11``   |
| `wg-dataslab.home.arpa    | `10.10.10.12``   |
| `_kerberos._tcp.home.arpa`  | `10.33.111.100` |
| `_ldap._tcp.home.arpa`      | `10.33.111.100` |
