# Decisions

The design choices made while setting up Pi-hole.

## Pi-hole over alternatives

**Decision.** Pi-hole v6 is the network's DNS resolver and content blocker.

**Alternatives considered.**

_AdGuard Home._ A comparable DNS-based ad blocker with a polished UI and built-in DoH/DoT support.
More actively developed at the UI layer.
Single binary, easier to containerize.

_Unbound + blocklists._ A validating, recursive resolver with blocklists applied via local zones.
More control over resolution behavior (DNSSEC validation, no third-party upstream).
Significantly more configuration work.

_Router-based blocking._ The Netgear gateway has a content filtering option.
No additional hardware required.
Limited to what the router vendor implements — no custom blocklists, no query logging.

**Why Pi-hole.**

Pi-hole is the established standard for homelab DNS-based content filtering.
The gravity blocklist system, the admin UI, and the query log are all well-documented and widely used.
For a homelab where the goal is working infrastructure rather than novelty, Pi-hole reduces the amount of custom configuration needed.

The query log is genuinely useful.
Being able to see every DNS query on the network, filter by client, and identify which device is querying what is practical for troubleshooting and monitoring.
Neither AdGuard Home nor a router-based solution integrates as cleanly with Pi-hole's existing logging workflow.

## Co-locating Pi-hole and WireGuard on the Pi

**Decision.** Both Pi-hole and WireGuard run on `netrunner`.

**Alternatives considered.**

_WireGuard on a dedicated VM on Proxmox._ Covered in the WireGuard decisions doc.
The key constraint: VPN access must survive Proxmox maintenance.

_Pi-hole on a VM._ Running Pi-hole in a container or VM on Proxmox would follow the same pattern as the rest of the lab.
But Pi-hole needs to be available before DNS works, and DNS needs to work before VMs can resolve anything.
A Pi-hole VM has a circular dependency on the infrastructure it's supposed to serve.

**Why co-location.**

The Pi is always-on infrastructure independent of Proxmox.
Both services are lightweight and don't compete for resources on an 8GB Pi 4B.
A single always-on device running two always-on services is simpler than two always-on devices.

## Pi-hole as DHCP server over router DHCP

**Decision.** Pi-hole runs the DHCP server for `10.33.111.0/24`, not the Netgear gateway.

**Alternatives considered.**

_Router DHCP._ The gateway already handles DHCP by default.
Simpler — one less service to manage.
But router DHCP would tell clients to use the router's DNS, which doesn't go through Pi-hole.

**Why Pi-hole DHCP.**

When Pi-hole runs DHCP, it tells clients to use `10.33.111.141` as their DNS server automatically.
Every device that gets an IP also gets Pi-hole as its resolver — no manual DNS configuration required per device.
With router DHCP, this requires either setting Pi-hole as the router's upstream DNS (which may not be available on all gateways) or manually configuring DNS on every client.

## Cloudflare upstream over self-hosted Unbound

**Decision.** DNS queries that Pi-hole can't answer locally are forwarded to Cloudflare (`1.1.1.1`, `1.0.0.1`).

**Alternatives considered.**

_Self-hosted Unbound._ A recursive resolver running locally on the Pi.
Eliminates the dependency on a third-party DNS provider.
Slower on cold cache (recursive resolution is slower than forwarding to a cached upstream).

_NextDNS or other managed DNS._ Hosted DNS filtering with its own blocklists.
Adds a dependency on another external service.

**Why Cloudflare.**

Cloudflare's resolvers are fast and privacy-respecting (no query logging after 24h per their policy).
For a homelab, the practical difference between Cloudflare and self-hosted Unbound is negligible.
The added complexity of operating Unbound isn't worth the marginal improvement in privacy for a private home network.

## Blocklist selection

**Decision.** Three blocklists: Hagezi Pro, Hagezi NSFW, and Hagezi TIF.

Hagezi Pro is a comprehensive tracker and ad blocker with a reputation for low false positive rates relative to its coverage.
It replaced StevenBlack/hosts as the baseline — better maintained, broader coverage, and the Hagezi lists are consistent in quality across tiers.

Hagezi NSFW adds content filtering for adult content.
Applied network-wide for consistent coverage across all devices.

Hagezi TIF (Threat Intelligence Feeds) adds blocking for known malicious domains.
Low false positive risk for a private homelab; useful additional coverage without the operational overhead of running IDS/IPS.

Note: Hagezi Pro deliberately does not block ad-network apex domains like `doubleclick.net` — only subdomains — to avoid collateral damage to non-ad traffic on the same domain.
This is expected behavior, not a gap.

Adding more lists increases the risk of false positives without proportional coverage gains.
StevenBlack was removed when Hagezi Pro was added — the coverage overlap was high and StevenBlack's deletion path from Pi-hole requires manual database cleanup (no `ON DELETE CASCADE` on `gravity`/`antigravity`).

## Delegating home.arpa to FreeIPA

**Decision.** Pi-hole does not hold any `home.arpa` DNS records.
All forward and reverse lookups for the local domain are delegated to FreeIPA's BIND via `dns.revServers`.

**Why.**
The previous approach maintained a copy of all lab host records in `dns.hosts` alongside the authoritative copy in FreeIPA's LDAP.
That duplication caused drift: stale entries in Pi-hole shadowed the live records in FreeIPA, producing incorrect resolutions when hostnames were renamed.
Fake A records for `_kerberos._tcp.home.arpa` and `_ldap._tcp.home.arpa` were particularly harmful — they broke SRV record lookup for IPA client enrollment.

Centralizing authority in FreeIPA means any change to a host record is immediately visible everywhere without a second update step.
`dns.revServers` handles the delegation cleanly: Pi-hole forwards the entire `home.arpa` zone and `10.33.111.0/24` reverse zone to mikoshi.
The split-horizon `arpatek.dev` entries remain in `dns.hosts` — those are Pi-hole's own responsibility.
