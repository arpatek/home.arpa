# Decisions

The design choices made while building this identity management stack.
This file captures the "why" behind decisions that aren't obvious from the configs.

Three decisions get fuller treatment because they had real alternatives worth weighing.
The rest are documented as paragraphs.

## FreeIPA over standalone components or alternatives

**Decision.** FreeIPA on Rocky Linux 9.7 is the identity and DNS server for the home.arpa lab.

**Alternatives considered.**

_OpenLDAP + MIT Kerberos, manually integrated._ Both projects are what FreeIPA bundles under the hood.
Running them separately is possible but requires writing the integration yourself: schema extensions, Kerberos-backed LDAP lookups, SSSD configuration, certificate management.
FreeIPA is years of Red Hat engineering on top of those exact components.
Doing it manually would reproduce that work poorly.

_Active Directory._ The dominant identity provider in enterprise Windows environments.
Supports LDAP and Kerberos.
Requires a Windows Server license, runs on Windows, and is designed for a mixed Windows/Linux fleet.
The home.arpa lab is Linux-only.

_Keycloak / Authentik._ Modern OIDC/OAuth2 identity providers.
Good fit for web application SSO and API authentication.
Not the right tool for Linux host authentication — they don't speak Kerberos or serve sudoers policies natively.
The Linux PAM/SSSD integration that FreeIPA handles out of the box requires significant glue work on top of either.

_Local accounts on each host._ The zero-infrastructure approach.
Works for a fleet of one or two hosts.
Breaks at the scale of this lab — eight enrolled hosts with two users means coordinating account creation, UID consistency, sudo policies, and SSH keys across eight machines manually.

**Why FreeIPA.**

It solves the right problem.
Linux host authentication, centralized sudo policy, SSH host key distribution, and DNS are exactly what FreeIPA was built for.
There is no glue work.
SSSD integrates with it natively.
`ipa-client-install` handles enrollment in one command.

The integrated CA is useful.
Dogtag issues certificates for enrolled hosts automatically.
Having a working internal CA is foundational for future services that need TLS without public CA involvement.

## Rocky Linux for the IPA server

**Decision.** `mikoshi` runs Rocky Linux 9.7.
All other homelab VMs run Debian 13.

**Alternatives considered.**

_Debian 13 for consistency._ FreeIPA is packaged for Debian and works.
Using the same OS across the fleet simplifies operations.

_Ubuntu 24.04 LTS._ FreeIPA is packaged and well-supported.
Canonical maintains it actively.

_AlmaLinux 9._ Functionally equivalent to Rocky Linux 9 — same sources, same packages, same RHEL compatibility.

**Why Rocky Linux.**

FreeIPA is a Red Hat project.
The canonical deployment platform is RHEL, and Rocky Linux is the closest RHEL-compatible OS available without a subscription.
The package versions, default configurations, and SELinux policies on Rocky Linux match what the upstream documentation describes.
Running FreeIPA on Debian works but puts you one step away from the canonical configuration on every decision.

The operational difference is manageable.
One RHEL-family host in an otherwise Debian fleet means learning `dnf` and `firewall-cmd` for one machine.
The monitoring stack already handles this split — `mikoshi` uses native systemd agents while Debian hosts use containerized agents.
The pattern is established.

**Decision to revisit.**

If Rocky Linux's future becomes uncertain, AlmaLinux is a direct replacement — same packages, same behavior, same RHEL compatibility.
The decision to revisit isn't OS family but which RHEL clone to use.

## Integrated DNS via FreeIPA over external resolver

**Decision.** FreeIPA's BIND integration serves as the primary DNS authority for `home.arpa`.
Pi-hole (`10.33.111.141`) serves as fallback for non-enrolled devices and as the upstream resolver.

**Alternatives considered.**

_Pi-hole as primary DNS for all hosts._ Pi-hole was already running on the network before IPA was built.
Using it as the single DNS server would have been simpler.

_Separate BIND instance._ Run BIND independently on `mikoshi` or another host, manage zone files manually.
FreeIPA would integrate with it via dynamic DNS updates.

_DNS entirely separate from IPA._ Deploy IPA without DNS integration, manage DNS on Pi-hole or a standalone BIND, maintain DNS records manually.

**Why FreeIPA DNS.**

Client enrollment requires SRV records.
`ipa-client-install` relies on `_kerberos._tcp.home.arpa` and `_ldap._tcp.home.arpa` SRV records to discover the IPA server.
Pi-hole doesn't support custom SRV records.
Without FreeIPA DNS, those records would need a separate authoritative nameserver anyway.

DNS updates happen automatically on enrollment.
When a new host runs `ipa-client-install`, its A and PTR records are written to LDAP and served by BIND immediately.
With external DNS, every enrollment requires a manual DNS update — an easy step to forget.

It keeps state in one place.
Host objects, Kerberos principals, and DNS records for the same host all live in 389-DS.
There is one place to add a host, one place to remove it, and no DNS records left behind when a host is decommissioned.

**Why Pi-hole is still in the picture.**

FreeIPA's BIND handles only the `home.arpa` zone.
Upstream queries need a forwarder.
Pi-hole handles that forwarding, plus ad blocking and content filtering for the network.
Non-enrolled devices (phones, laptops) use Pi-hole directly since they aren't IPA clients and don't need the SRV records.

The split is: IPA DNS is authoritative for `home.arpa`, Pi-hole is the upstream resolver and the catch-all for non-enrolled devices.

## Smaller decisions

**Single master, no replica.** A single `mikoshi` with no replica is a deliberate homelab trade-off. A replica would survive the primary going down, but setting one up means a second always-on VM consuming resources for marginal benefit. SSSD's credential caching means enrolled hosts can continue to function for a limited time during an outage. The risk is accepted.

**HBAC deny-all with explicit allow.** The default `allow_all` HBAC rule is disabled. Access is granted only via `allow_ssh_devops`, which explicitly names the user groups, host groups, and services permitted. The cost is that a new host group or user group must be explicitly added to the rule to get access; the benefit is that access is never accidentally granted to a new host or user.

**Dogtag CA enabled.** FreeIPA can be installed without a CA (`--no-pkinit`), which simplifies the install and removes the Dogtag dependency. I chose to keep the CA enabled because an internal CA is foundational for future services that need TLS without involving a public CA. The Dogtag CA also issues host certificates automatically during enrollment, which SSSD uses for PKINIT authentication.

**`kinit` for CLI operations, not a persistent admin session.** The `ipa` CLI requires a valid Kerberos ticket. Rather than running a persistent admin session, I acquire a ticket with `kinit admin` when I need to make changes and let it expire. This avoids leaving long-lived admin credentials in memory.
