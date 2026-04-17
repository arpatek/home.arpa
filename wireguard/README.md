# WireGuard

## Host

|          |                                                                 |
| -------- | --------------------------------------------------------------- |
| Hardware | Raspberry Pi 4B, 8GB RAM, SanDisk 256GB MicroSD, Argon NEO Case |
| OS       | Raspberry Pi OS Lite (based on Debian 13 Trixie)                |
| IP       | 10.33.111.141                                                   |
| Hostname | netrunner-rpi                                                   |

## Overview

WireGuard VPN server providing an encrypted tunnel between remote devices and the home network. Allows access to all homelab services, VMs, Proxmox, Pi-hole, and the NAS from outside the network.

WireGuard is built into the Linux kernel since 5.6 — no external packages required beyond `wireguard-tools`.
Running on kernel `6.12.62+rpt-rpi-v8`.

## Installation

```bash
sudo apt install wireguard iptables-persistent
```

Managed via `wg-quick` and systemd. Enabled at boot:

```bash
sudo systemctl enable --now wg-quick@wg0
```

## Network Topology

```
Internet
    │
    │ UDP 55055
    ▼
Netgear Gateway (10.33.111.1)
    │
    │ Port forward → 10.33.111.141:55055
    ▼
netrunner-rpi (10.33.111.141) ← WireGuard server (10.10.10.1)
    │
    ├── node-zero  (10.10.10.10) — MacBook Air
    ├── deck-alpha (10.10.10.11) — iPhone
    └── deck-gamma (10.10.10.12) — iPad Mini
```

## Configuration

### Interface

| Setting           | Value                                          |
| ----------------- | ---------------------------------------------- |
| Interface         | `wg0`                                          |
| Server Address    | `10.10.10.1/24`                                |
| Listen Port       | `55055`                                        |
| MTU               | `1380`                                         |
| Server Public Key | `IOqqhFIWdAm+PkkCuN5/oy73cJsonykXelWKMjWQ81Q=` |

### MTU Tuning

Default WireGuard MTU is `1420` (standard Ethernet `1500` minus ~`60` bytes of WireGuard encryption overhead).
Set to `1380` for stability due to additional ISP overhead causing packet fragmentation above this value.

```
Standard Ethernet MTU:    1500
WireGuard overhead:        ~60
Theoretical safe MTU:     1440
Configured MTU:           1380 (conservative, stable under load)
```

TCP MSS is also clamped to `1320` via iptables to prevent TCP connections from negotiating segment sizes too large for the tunnel.

### IP Forwarding

Enabled via sysctl so the kernel routes packets between `wg0` and `eth0`:

```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system
```

### NAT and Forwarding Rules

WireGuard client traffic is masqueraded behind the Pi's LAN IP so that LAN devices receive traffic from a known address and can route responses back correctly.

PostUp/PostDown hooks in `wg0.conf` apply and remove NAT rules automatically when the WireGuard interface comes up or goes down:

```
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
```

Persistent iptables rules saved via `iptables-persistent`:

```
# NAT - masquerade WireGuard subnet behind Pi's LAN IP
-A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE

# FORWARD - allow WireGuard clients to reach LAN
-A FORWARD -i wg0 -o eth0 -j ACCEPT

# FORWARD - allow return traffic for established connections
-A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# TCPMSS clamping - prevent TCP fragmentation through tunnel
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1320
```

### Peers

| Name       | Device      | WireGuard IP  | Public Key                                     |
| ---------- | ----------- | ------------- | ---------------------------------------------- |
| node-zero  | MacBook Air | `10.10.10.10` | `RmVAFWfPghKVxOYlINTn7PTI8MWHSVEE/Z+3wRtqzms=` |
| deck-alpha | iPhone      | `10.10.10.11` | `ch7E8s+mtl3+m1vKf4UCJqokzs6rAc1Ax2QGVmd64DQ=` |
| deck-gamma | iPad Mini   | `10.10.10.12` | `m20JP1PK3hSBT5cbyaf/ZCB+lPUcbJX/zEVQPdTnrX0=` |

### Port Forwarding

Configured on Netgear gateway:

| Rule      | Protocol | External Port | Internal IP   | Internal Port |
| --------- | -------- | ------------- | ------------- | ------------- |
| WIREGUARD | UDP      | 55055         | 10.33.111.141 | 55055         |

## Dynamic DNS

Home IP is dynamic — a Cloudflare DDNS client keeps a subdomain pointed at the current public IP so WireGuard peers always have a stable endpoint to connect to. See [cloudflare-ddns](https://codeberg.org/arpatek/cloudflare-ddns) for implementation details.

## Notes

- Private key is stored only in `/etc/wireguard/wg0.conf` on `netrunner-rpi` — never committed to this repo
- WireGuard subnet `10.10.10.0/24` is served by Pi-hole for DNS and DHCP
- Reverse DNS for the WireGuard subnet is handled by Pi-hole on port `55055`
- Firewall managed via iptables and iptables-persistent — UFW is not installed
- See [RFC 1918](https://datatracker.ietf.org/doc/html/rfc1918) for private address space
