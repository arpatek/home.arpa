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

## Public exposure

Two hostnames are reachable from the public internet.

### arpatek.dev

Cloudflare DNS points `arpatek.dev` at the home public IP.
The home router forwards HTTPS (443) to the k3s worker nodes.
Traefik (k3s ingress controller) routes requests to the `arpatek-dev` deployment.
TLS is terminated at Traefik using a Let's Encrypt certificate issued by cert-manager via Cloudflare DNS-01.

```
client → Cloudflare → home public IP → router → k3s Traefik → arpatek.dev pod
```

```bash
curl arpatek.dev               # terminal portfolio page
curl arpatek.dev/man | less    # resume in manpage format
```

### git.arpatek.dev

`git.arpatek.dev` shares the `*.arpatek.dev` wildcard certificate.
Traefik routes it to a headless Service backed by a static Endpoints object pointing at `prod-git-0:3000` on the LAN.
Gitea SSH (`prod-git-0:2222`) is not publicly exposed — SSH access is only available via WireGuard.

```
client → Cloudflare → home public IP → router → k3s Traefik → prod-git-0:3000
```
