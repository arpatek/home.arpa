# Network

## LAN

**Subnet:** `10.33.111.0/24`
**Gateway:** `10.33.111.1` (home router)
**DHCP server:** Pi-hole on `netrunner-rpi` (`10.33.111.141`), range `10.33.111.2–254`

## Host IP assignments

| Host | IP | Notes |
| ---- | -- | ----- |
| `devstem` | `10.33.111.44` | Proxmox hypervisor, static |
| `prod-ipa-0` | `10.33.111.100` | static |
| `prod-git-0` | `10.33.111.101` | static |
| `prod-mon-0` | `10.33.111.102` | static |
| `prod-k3s-master-0` | `10.33.111.103` | static, set via cloud-init |
| `prod-k3s-worker-0` | `10.33.111.104` | static, set via cloud-init |
| `prod-k3s-worker-1` | `10.33.111.105` | static, set via cloud-init |
| `netrunner-rpi` | `10.33.111.141` | static |
| `dev-rhel-0` | `10.33.111.200` | DHCP reservation, VM normally stopped |
| `dev-ubuntu-0` | `10.33.111.201` | DHCP reservation, VM normally stopped |

## DNS

The lab uses a two-tier DNS system.

**FreeIPA BIND** (`prod-ipa-0`, `10.33.111.100`) is the authoritative DNS server for `home.arpa`.
All IPA-enrolled VMs point their resolver at `prod-ipa-0`.
FreeIPA BIND answers `home.arpa` queries authoritatively and forwards everything else upstream to Pi-hole.

**Pi-hole** (`netrunner-rpi`, `10.33.111.141`) is the recursive resolver and content filter for the rest of the network.
Non-enrolled devices (laptops, phones, IoT) use Pi-hole as their only DNS server.
WireGuard clients use Pi-hole via the tunnel.
FreeIPA-enrolled VMs also reach Pi-hole indirectly — BIND forwards non-`home.arpa` queries to it.

The result: every DNS query that leaves the lab, regardless of client type, passes through Pi-hole's blocklist.

## VPN

WireGuard runs on `netrunner-rpi`, listening on UDP port `55055`.
The tunnel subnet is `10.10.10.0/24`.

| Role | WireGuard IP |
| ---- | ------------ |
| `netrunner-rpi` (server) | `10.10.10.1` |
| connected clients | `10.10.10.2+` |

Client traffic is masqueraded behind the Pi's LAN IP (`10.33.111.141`) so LAN hosts can route responses back to tunnel clients.
Connected clients use Pi-hole (`10.33.111.141`) for DNS, giving them the same resolution and filtering as LAN devices.

The server's public endpoint is a Cloudflare DDNS subdomain that tracks the dynamic home IP.
Peers are configured with that hostname so reconnection is automatic after an IP change.

## Firewall posture

**Internet-facing:** the home router forwards only one port — UDP `55055` to `netrunner-rpi` for WireGuard.
No other ports are open inbound from the internet.
Web services (`arpatek.dev`, `git.arpatek.dev`) will reach the public through a Cloudflare Tunnel, which requires no inbound port forwarding.

**Proxmox-level:** the Proxmox firewall is enabled on every VM network interface (`firewall=1` in each VM config).
Each service's own README documents the specific ports it needs open.

**LAN:** no firewall between hosts on `10.33.111.0/24`.
Lab VMs can reach each other freely within the subnet.

## Public exposure

`wg.arpatek.dev` is the only hostname currently exposed — a grey-cloud A record pointing at the home public IP for WireGuard.

`arpatek.dev` and `git.arpatek.dev` are ready but not yet publicly deployed.
The planned mechanism is a Cloudflare Tunnel (`cloudflared` running in k3s), which requires no port forwarding and keeps the home IP out of the DNS records for the web services.
That work lives in a separate project and repo.

Once deployed, the expected traffic path is:

```
client → Cloudflare edge → cloudflared tunnel → k3s Traefik → arpatek.dev pod
client → Cloudflare edge → cloudflared tunnel → k3s Traefik → prod-git-0:3000
```

TLS is handled by cert-manager using a Let's Encrypt wildcard certificate issued via Cloudflare DNS-01.
Gitea SSH (`prod-git-0:2222`) will not be publicly exposed — SSH access remains WireGuard-only.
