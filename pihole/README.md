# Pi-hole

## Host

|          |                                                                 |
| -------- | --------------------------------------------------------------- |
| Hardware | Raspberry Pi 4B, 8GB RAM, SanDisk 256GB MicroSD, Argon NEO Case |
| OS       | Raspberry Pi OS Lite (based on Debian 13 Trixie)                |
| IP       | 10.33.111.141                                                   |
| Hostname | netrunner-rpi                                                   |

## Overview

netrunner-rpi serves as the network's DHCP server, local DNS resolver, and
content blocker. It handles ad blocking and NSFW filtering for all devices
on the 10.33.111.0/24 network and the WireGuard 10.10.10.0/24 subnet.

## Installation

Installed bare metal using the official Pi-hole one-line installer on
Raspberry Pi OS Lite (Debian 13 Trixie).

## Configuration

### DHCP

Pi-hole serves DHCP for the 10.33.111.0/24 network via the `eth0` interface.
Unknown clients are not ignored — all devices on the network receive an IP.

### Upstream DNS

| Server  | Provider               |
| ------- | ---------------------- |
| 1.1.1.1 | Cloudflare (primary)   |
| 1.0.0.1 | Cloudflare (secondary) |

### DNS Settings

- Local domain queries (`home.arpa`) are never forwarded upstream
- Private reverse lookups are not forwarded upstream (`bogusPriv`)
- NTP synced via `us.pool.ntp.org`

### Web Interface

Accessible at `https://netrunner-rpi.home.arpa/admin/` on port 443

### Blocklists

| List                                                                                         | Purpose                |
| -------------------------------------------------------------------------------------------- | ---------------------- |
| [StevenBlack/hosts](https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts)        | Basic ad blocking      |
| [Hagezi Pro](https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/adblock/pro.txt)     | Extended blocking      |
| [Hagezi NSFW](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/nsfw.txt) | NSFW content filtering |

### Local DNS Records

> [RFC 1918](https://datatracker.ietf.org/doc/html/rfc1918) private addresses, non-routable outside the local network.

| Hostname                    | IP            |
| --------------------------- | ------------- |
| \_kerberos.\_tcp.home.arpa  | 10.33.111.100 |
| \_ldap.\_tcp.home.arpa      | 10.33.111.100 |
| ctrl-node.home.arpa         | 10.33.111.20  |
| deck-alpha.home.arpa        | 10.10.10.11   |
| deck-gamma.home.arpa        | 10.10.10.12   |
| dev-rhel-0.home.arpa        | 10.33.111.200 |
| dev-ubuntu-0.home.arpa      | 10.33.111.201 |
| devstem.home.arpa           | 10.33.111.44  |
| gateway.home.arpa           | 10.33.111.1   |
| node-one.home.arpa          | 10.33.111.22  |
| node-zero.home.arpa         | 10.10.10.10   |
| node-zero.home.arpa         | 10.33.111.11  |
| prod-git-0.home.arpa        | 10.33.111.101 |
| prod-ipa-0.home.arpa        | 10.33.111.100 |
| prod-k3s-master-0.home.arpa | 10.33.111.103 |
| prod-k3s-worker-0.home.arpa | 10.33.111.104 |
| prod-k3s-worker-1.home.arpa | 10.33.111.105 |
| prod-mon-0.home.arpa        | 10.33.111.102 |

## Role in Network DNS Architecture

Pi-hole acts as the fallback DNS for the 10.33.111.0/24 network.
FreeIPA (prod-ipa-0) is the primary DNS authority for the home.arpa
domain. Pi-hole handles upstream resolution to Cloudflare and content
filtering for all devices.

## Notes

- Also serves as DNS and DHCP for the WireGuard 10.10.10.0/24 subnet
- `home.arpa` is reserved for local network use per [RFC 8375](https://datatracker.ietf.org/doc/html/rfc8375), making it a safe and standards-compliant choice for private homelab DNS
