# Decisions

The design choices made while setting up this WireGuard deployment.

## WireGuard over OpenVPN or IPsec

**Decision.** WireGuard is the VPN protocol.

**Alternatives considered.**

_OpenVPN._ The traditional choice for self-hosted VPNs.
Mature, widely supported, extensive documentation.
Runs as a userspace daemon, requires a PKI (TLS certificates), and has a significantly larger configuration surface.

_IPsec (strongSwan / Libreswan)._ The standard VPN protocol at the network layer.
Supported natively by most operating systems without installing a client app.
Configuration is complex — IKE policy negotiation, phase 1/phase 2 settings, certificate management.
Debugging is harder than either WireGuard or OpenVPN.

_Tailscale._ A managed WireGuard mesh built on top of the WireGuard protocol.
Zero configuration, built-in DDNS, works through most NATs without port forwarding.
Requires a Tailscale account and trust in a third-party coordination server for key distribution.

**Why WireGuard.**

It is the simplest thing that does the job.
A kernel module, a config file, and `wg-quick`.
No daemon to manage, no certificates to rotate, no PKI to operate.
The protocol surface is small — the spec fits in a short paper.

Performance is better than userspace VPN implementations.
Encryption runs in kernel space, which matters on a Raspberry Pi where CPU headroom is limited.

The attack surface is minimal.
The WireGuard codebase is around 4,000 lines — orders of magnitude smaller than OpenVPN.
The protocol design makes some classes of attack impossible by construction (no response to unauthenticated packets, for example).

## Running on the Pi over a lab VM

**Decision.** WireGuard runs on `netrunner-rpi` (bare metal Raspberry Pi), not on a VM inside Proxmox.

**Alternatives considered.**

_VM on Proxmox._ Co-locate VPN access with the rest of the infrastructure.
Simpler to manage everything in one place.

_Dedicated lightweight VM or container._ Something like an LXC container on Proxmox.

**Why the Pi.**

VPN access should survive hypervisor maintenance.
If Proxmox is being rebooted, upgraded, or recovered, VMs are unavailable.
A VPN running as a VM would go down exactly when remote access to the lab is most needed.
The Pi is independent infrastructure — it runs whether or not Proxmox is healthy.

The Pi is already always-on for Pi-hole.
Combining WireGuard and Pi-hole on the same device keeps the "small always-on services" footprint to one piece of hardware.
Both services are lightweight and don't compete for resources.

## Hub-and-spoke over mesh

**Decision.** All peers connect to `netrunner-rpi` as the hub.
Peers have no routes to each other.

**Alternatives considered.**

_Full mesh._ Every peer connects to every other peer directly.
Lower latency for peer-to-peer traffic.
Requires each peer to know every other peer's public key and endpoint.
Configuration grows as O(n²) with the number of peers.

_Tailscale mesh._ Managed mesh with automatic peer discovery and NAT traversal.
No configuration per-peer — the coordination server handles it.
Covered under the WireGuard vs Tailscale decision above.

**Why hub-and-spoke.**

The use case is LAN access, not peer-to-peer.
The only thing remote peers need to reach is the home network.
Direct peer-to-peer routes add configuration complexity for a use case that doesn't exist.

With three peers and no plans to add more, the configuration is static and manageable.

## Port 55055 over the default 51820

**Decision.** WireGuard listens on port 55055, not the default 51820.

**Why.**
A non-default port reduces automated scanning noise.
Port 51820 appears in scans that specifically target WireGuard deployments.
This doesn't meaningfully improve security against a determined attacker, but it reduces log noise from opportunistic scans.

## Cloudflare DDNS

**Decision.** A Cloudflare DDNS client keeps a subdomain pointed at the current home IP.

**Alternatives considered.**

_Static IP from ISP._ A fixed public IP would eliminate DDNS entirely.
Costs extra monthly and isn't available from all ISPs.

_Other DDNS providers._ DynDNS, No-IP, DuckDNS all work but require accounts with additional external services.

_Manual updates._ Update peer configs when the IP changes.
Fragile — if a peer is traveling when the IP changes, access is lost until the config is updated manually.

**Why Cloudflare.**
The domain is already managed on Cloudflare.
Using Cloudflare's API for DDNS keeps DNS management in one place.
The DDNS client runs as a systemd service on `netrunner-rpi` and updates the record automatically when the IP changes.

> The DDNS client implementation is documented separately at [codeberg.org/arpatek/cloudflare-ddns](https://codeberg.org/arpatek/cloudflare-ddns).

## Smaller decisions

**MTU 1380.** The default WireGuard MTU of 1420 caused packet fragmentation under this ISP connection, visible as intermittent TCP drops on large transfers. Setting MTU to 1380 resolved it. See [gotchas.md](gotchas.md) for the full story.

**iptables-persistent over nftables.** On Debian 13 (and Raspberry Pi OS built on it), `iptables` is already the `iptables-nft` compatibility layer — it writes nftables rules in the kernel under the hood. The ruleset here is four lines. The clarity and expressiveness advantages of native nftables syntax only matter for complex multi-table rulesets. Migration would mean rewriting the rules, updating the PostUp/PostDown hooks in `wg0.conf`, and replacing `iptables-persistent` — real work for no functional gain at this scale. If the ruleset ever grows significantly, migrating to native nftables syntax becomes worth reconsidering.

**AllowedIPs as /32 per peer.** Each peer's `AllowedIPs` is set to its specific tunnel IP (`10.10.10.10/32`, etc.), not the full `10.10.10.0/24` subnet. This prevents a compromised peer from spoofing packets that appear to come from another peer's IP. WireGuard uses `AllowedIPs` as both a routing table and an access control list.
