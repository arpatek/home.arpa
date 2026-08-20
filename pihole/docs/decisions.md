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

## Redundant Pi-hole via nebula-sync over keepalived

**Decision.** A second Pi-hole on `edgerunner` provides DNS redundancy. The two instances are kept identical by `nebula-sync`, and clients fail over via DHCP-advertised dual DNS — not a shared VIP managed by keepalived.

**Alternatives considered.**

_keepalived + VRRP (floating VIP)._ A virtual IP floats to whichever node is healthy; clients point at the VIP and get ~3s automatic failover, covering statically-configured clients too. This is the "enterprise" HA pattern.

_gravity-sync / orbital-sync._ The previous generation of Pi-hole sync tools. Both are archived — they targeted the Pi-hole v5 API and don't work with v6's Teleporter/auth model. Not viable.

_Manual config duplication._ Configure both by hand, keep them in sync manually. Guaranteed drift over time.

**Why nebula-sync + dual DNS.**

keepalived adds real moving parts: a VRRP daemon on both nodes, a third IP, health-check scripting, and a new failure mode (split-brain if VRRP misbehaves). Client-side failover needs none of it — every OS resolver already tries DNS servers in order and falls through on timeout. Handing out both Pi IPs via DHCP option 6 gets failover from code that's already running on every client, with zero extra infrastructure. The trade-off is that failover is per-query timeout rather than sub-second VIP movement, and statically-configured hosts don't benefit — acceptable for a homelab.

`nebula-sync` is the maintained successor to gravity-sync for Pi-hole v6. It drives the Teleporter API to replicate config from a primary, which fits the "one source of truth, enforced onto replicas" model exactly.

## Selective sync over full sync (DHCP guard)

**Decision.** `nebula-sync` runs with `FULL_SYNC=false`, enabling only DNS, resolver, NTP, misc, and gravity sections. DHCP and the query database are excluded.

**Why.**
`FULL_SYNC=true` teleports the entire config blob, which includes the DHCP settings. That would set `dhcp.active=true` on `edgerunner` and produce two DHCP servers racing on the same `/24` — conflicting leases and intermittent, hard-to-diagnose network failures. Excluding DHCP (`SYNC_CONFIG_DHCP=false`, its default) keeps DHCP solely on `netrunner`. The query database is excluded (`SYNC_CONFIG_DATABASE=false`) so each instance keeps its own query history rather than one stomping the other. Selective sync makes the safe sections opt-in and the dangerous one impossible to enable by accident.

## App password over admin password for sync

**Decision.** `nebula-sync` authenticates to both instances with per-instance Pi-hole v6 **app passwords**, not the admin password. The replica additionally has `webserver.api.app_sudo = true`.

**Why.**
An app password is a scoped, independently revocable credential. If it leaks, you revoke one token instead of rotating the admin login. This is the least-privilege choice for a service account. The cost is that Pi-hole v6 gates privileged operations — the Teleporter *import* rewrites config, a sudo-class action — behind `webserver.api.app_sudo`, which must be enabled on the replica (the write target) for the import to be permitted. That's a deliberate, narrow widening of the replica's app-password scope, not a blanket grant. See [gotchas.md](gotchas.md) for the 403 this produces if forgotten.

## DHCP stays single-homed on netrunner

**Decision.** Only `netrunner` runs DHCP. `edgerunner` is a DNS-only replica.

**Why.**
Pi-hole has no HA DHCP — two active DHCP servers on one segment issue conflicting IPs. DNS is trivially redundant (two independent resolvers); DHCP is not. Rather than attempt DHCP failover, DHCP is kept single-homed and accepted as a single point of failure. The mitigation is lease duration: if `netrunner` goes down, no *new* leases are issued, but existing clients keep their current lease — including both DNS servers — for the 24h lease time, and continue resolving via `edgerunner`. For a homelab this is the right trade: DNS redundancy where it's cheap, and a bounded, understood DHCP gap rather than fragile DHCP HA.
