# WireGuard

## Host

|          |                                                                 |
| -------- | --------------------------------------------------------------- |
| Hardware | Raspberry Pi 4B, 8GB RAM, SanDisk 256GB MicroSD, Argon NEO Case |
| OS       | Raspberry Pi OS Lite (based on Debian 13 Trixie)                |
| IP       | 10.33.111.141                                                   |
| Hostname | netrunner                                                   |

## Overview

WireGuard VPN server providing an encrypted tunnel between remote devices and the home network.
Allows access to all homelab services, VMs, Proxmox, Pi-hole, and the NAS from outside the network.

WireGuard is built into the Linux kernel since 5.6.
No external packages are required beyond `wireguard-tools`.
Running on kernel `6.12.62+rpt-rpi-v8`.

Home IP is dynamic.
A Cloudflare DDNS client keeps a subdomain pointed at the current public IP so peers always have a stable endpoint to connect to.
See [cloudflare-ddns](https://codeberg.org/arpatek/cloudflare-ddns) for implementation details.

## Repository layout

```
wireguard/
├── README.md                   # this file — host reference and config guide
├── wg0.conf.example            # server config with private key removed
├── rules.v4                    # iptables-persistent rules (filter + nat tables)
├── 99-wireguard.conf           # sysctl: net.ipv4.ip_forward=1
└── docs/
    ├── architecture.md         # tunnel topology and traffic flow
    ├── decisions.md            # design choices and rationale
    ├── gotchas.md              # issues encountered during setup
    └── upgrading.md            # kernel and OS upgrade considerations
```

## Installation

```bash
sudo apt install wireguard iptables-persistent
```

Managed via `wg-quick` and systemd, enabled at boot:

```bash
sudo systemctl enable --now wg-quick@wg0
```

IP forwarding enabled via sysctl so the kernel routes packets between `wg0` and `eth0`:

```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system
```

## Network topology

```
Internet
    │
    │ UDP 55055
    ▼
Netgear Gateway (10.33.111.1)
    │
    │ Port forward → 10.33.111.141:55055
    ▼
netrunner (10.33.111.141) ← WireGuard server (10.10.10.1)
    │
    ├── wg-darwin    (10.10.10.10) — MacBook Air (macOS)
    ├── wg-uplink    (10.10.10.11) — iPhone
    └── wg-dataslab  (10.10.10.12) — iPad Mini
```

## Configuration

### Interface

| Setting           | Value                                          |
| ----------------- | ---------------------------------------------- |
| Interface         | `wg0`                                          |
| Server address    | `10.10.10.1/24`                                |
| Listen port       | `55055`                                        |
| MTU               | `1380`                                         |
| Server public key | `IOqqhFIWdAm+PkkCuN5/oy73cJsonykXelWKMjWQ81Q=` |

The private key is stored only in `/etc/wireguard/wg0.conf` on `netrunner` and is never committed to this repo.

### MTU tuning

Default WireGuard MTU is `1420` (standard Ethernet `1500` minus ~`60` bytes of WireGuard overhead).
Set to `1380` for stability due to additional ISP overhead causing fragmentation above this value.

```
Standard Ethernet MTU:    1500
WireGuard overhead:        ~60
Theoretical safe MTU:     1440
Configured MTU:           1380 (conservative, stable under load)
```


### NAT and forwarding rules

WireGuard client traffic is masqueraded behind the Pi's LAN IP so that LAN devices receive traffic from a known address and can route responses back correctly.

Rules are managed via `iptables-persistent` and loaded at boot independently of WireGuard:

```
# NAT — masquerade WireGuard subnet behind Pi's LAN IP
-A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE

# FORWARD — allow WireGuard clients to reach LAN
-A FORWARD -i wg0 -o eth0 -j ACCEPT

# FORWARD — allow return traffic for established connections
-A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

### Peers

| Name       | Device      | WireGuard IP  | Public Key                                     |
| ---------- | ----------- | ------------- | ---------------------------------------------- |
| wg-darwin    | MacBook Air (macOS)         | `10.10.10.10` | `RmVAFWfPghKVxOYlINTn7PTI8MWHSVEE/Z+3wRtqzms=` |
| wg-uplink    | iPhone                      | `10.10.10.11` | `ISlUsgd4duK+8tdbb14SF/xmr3ioIhjhZx3o9wDkJQQ=` |
| wg-dataslab  | iPad Mini                   | `10.10.10.12` | `2xDml5jGVj1n/sXgF7obW5XoaFohbXft54+ua5fks3U=` |

### Port forwarding

Configured on Netgear gateway:

| Rule      | Protocol | External port | Internal IP   | Internal port |
| --------- | -------- | ------------- | ------------- | ------------- |
| WIREGUARD | UDP      | 55055         | 10.33.111.141 | 55055         |

## DNS

WireGuard clients use Pi-hole (`10.33.111.141`) for DNS resolution.
The `10.10.10.0/24` tunnel subnet routes through the LAN via NAT, so DNS queries from connected clients reach Pi-hole the same way LAN devices do.
Firewall managed via iptables and iptables-persistent.
UFW is not installed.
