# Gotchas

Issues encountered during the Pi-hole setup.

## dns.revServers caused a DNS resolution loop

**Symptom.**
DNS resolution stops working intermittently or completely.
Queries time out or return SERVFAIL.
The Pi-hole query log shows requests being made but no responses.
The problem is hard to attribute because it manifests as a general "DNS is broken" failure rather than a specific error.

**Cause.**
The `dns.revServers` setting in `pihole.toml` tells Pi-hole to delegate reverse DNS queries (PTR records) for specified subnets to another server.
If that server in turn forwards queries back to Pi-hole — either directly or through the network's default DNS path — a loop forms.

In this setup, the loop could form two ways:

- **LAN subnet delegated to the gateway** (`10.33.111.1`): The Netgear gateway uses Pi-hole as its upstream DNS. Enabling this revServer entry meant Pi-hole forwarded PTR queries for `10.33.111.x` to the gateway, which forwarded them back to Pi-hole, which forwarded them to the gateway again.

- **WireGuard subnet entry pointing at Pi-hole itself** (`10.33.111.141#55055`): The `#55055` port in this entry is the WireGuard VPN port, not a DNS port. If enabled, Pi-hole would attempt to send DNS queries to itself on a port that is not listening for DNS traffic. The intent was presumably to handle WireGuard subnet PTR records locally, but the configuration was wrong.

**Fix.**
Delegate `home.arpa` to FreeIPA, which is the actual authoritative nameserver for the zone:

```toml
revServers = [
  "true,10.33.111.0/24,10.33.111.100,home.arpa"
]
```

This configures Pi-hole to forward both the `home.arpa` forward zone and `10.33.111.x` reverse lookups to FreeIPA (`mikoshi`).
The old disabled entries were wrong in two ways: the gateway entry (`10.33.111.1`) created a loop, and the WireGuard entry pointed at Pi-hole's own WireGuard port rather than a DNS port.

**Broken assumption.**
I assumed `revServers` was only for situations where a router owns the reverse zone.
It is the correct mechanism whenever any external server is authoritative — including FreeIPA.
Keeping `home.arpa` records in `dns.hosts` alongside FreeIPA caused drift and hostname shadowing; delegation to FreeIPA eliminates the duplication.

---

## FTL v6 config and diagnostic gotchas

A collection of FTL v6 behaviors that aren't obvious from the documentation.

### `pihole-FTL --config <key> <value>` segfaults on boolean values

**Symptom.**
Running `pihole-FTL --config dhcp.multiDNS false` prints nothing and exits with a segfault.

**Cause.**
FTL v6.6.2 has a bug in its CLI config setter for boolean types.

**Fix.**
Edit `pihole.toml` directly with `sed`, then restart:

```bash
sudo sed -i 's/multiDNS = true/multiDNS = false/' /etc/pihole/pihole.toml
sudo systemctl restart pihole-FTL
```

Verify with `pihole-FTL --config dhcp.multiDNS` after restart.

### `/etc/dnsmasq.d/` is disabled by default

**Symptom.**
Files dropped in `/etc/dnsmasq.d/` have no effect.

**Cause.**
Pi-hole v6 sets `misc.etc_dnsmasq_d = false` by default. The directory is not loaded.

**Fix.**
Use `misc.dnsmasq_lines` in `pihole.toml` to inject custom dnsmasq options:

```toml
[misc]
  dnsmasq_lines = ["local=/local/"]
```

Then restart pihole-FTL. Verify the line appears in the generated config:
```bash
grep 'local=/local/' /etc/pihole/dnsmasq.conf
```

### FTL rewrites pihole.toml on every restart

**Symptom.**
After restarting pihole-FTL, `pihole.toml` has been reformatted — arrays that were on one line are now multiline.

**Cause.**
FTL regenerates the config file on every startup.
It preserves your values but may change formatting (e.g. `["x"]` → multiline array syntax).

**Implication.**
`sed` edits to `pihole.toml` survive restarts; the value is kept, just potentially reformatted.
Always verify with `grep` after restart, not by reading the exact line you edited.

### FTL database type numbers are not RFC type numbers

**Symptom.**
Querying `pihole-FTL.db` with `WHERE type=6` to find SOA queries returns PTR queries instead.

**Cause.**
FTL uses an internal sequential enum, not RFC DNS type numbers.
The mapping is:

| FTL type | Query type |
|----------|-----------|
| 5 | SOA |
| 6 | PTR |

RFC assigns SOA=6 and PTR=12. FTL does not match RFC numbering.

**Fix.**
Use `WHERE type=5` for SOA queries in FTL database queries.

### Pi-hole web UI shows client hostname in the domain column for locally-answered queries

**Symptom.**
The query log in the web UI shows entries that look like SOA queries for `mikoshi.home.arpa` or `iPhone.home.arpa`.
Querying the database directly shows the actual domain queried was `local.`.

**Cause.**
When Pi-hole answers a query from its local data (type `local`), it displays the resolved hostname of the client in the domain column of the web UI instead of the queried domain.
This is a display quirk, not a real query for those hostnames.

**Fix.**
Query the database directly to see the actual domain:

```bash
pihole-FTL sqlite3 /etc/pihole/pihole-FTL.db \
  "SELECT datetime(timestamp,'unixepoch','localtime'), domain, client FROM queries WHERE type=5 ORDER BY timestamp DESC LIMIT 20;"
```

### SOA queries for `local.` cause 5–20 second latency

**Symptom.**
Pi-hole query log shows frequent `SOA local.` queries (every ~60 seconds) with reply times of 5–20 seconds.
Clients are Apple devices and FreeIPA components doing DNS-SD probing.

**Cause.**
`local.` is the mDNS domain (RFC 6762).
Without explicit configuration, Pi-hole forwards `local.` to upstream DNS (1.1.1.1), which times out because `local.` is not a public zone.
Apple devices and FreeIPA's sssd probe `SOA local.` periodically as part of mDNS/DNS-SD service discovery.

**Fix.**
Add `local=/local/` to `misc.dnsmasq_lines`.
This tells dnsmasq to answer `local.` immediately with NXDOMAIN from local data, without forwarding:

```toml
[misc]
  dnsmasq_lines = ["local=/local/"]
```

After restart, latency drops from 5–20s to under 1ms.
The queries continue — they are normal device behavior — but are now harmless.

---

## nebula-sync HA gotchas

Issues encountered wiring up the `edgerunner` replica with `nebula-sync`.

### Teleporter import returns 403 with app passwords

**Symptom.**
`nebula-sync` authenticates fine but fails on import:

```
FTL Sync failed error="sync teleporters: http://10.33.111.142/api/teleporter: unexpected status code: 403"
```

The export from the primary works; only the import into the replica 403s.

**Cause.**
Authentication succeeded (a `401` would mean bad credentials) — this is `403 Forbidden`: the app-password session is valid but not *permitted* to do this. A Teleporter import rewrites the entire config, a sudo-class action. Pi-hole v6 gates that behind `webserver.api.app_sudo`, which defaults to `false`. An app-password session can read and do light operations but cannot import config until `app_sudo` is enabled.

**Fix.**
Enable `app_sudo` on the **replica** (the write target — `edgerunner`), not the primary:

```bash
sudo pihole-FTL --config webserver.api.app_sudo true
pihole-FTL --config webserver.api.app_sudo        # verify: true
```

Applies live, no restart. The primary (`netrunner`) is only ever read from, so it doesn't need it. This is [nebula-sync #83](https://github.com/lovelaze/nebula-sync/issues/83).

**Broken assumption.**
A valid app password implies full API access. It doesn't — Pi-hole v6 scopes app-password sessions away from privileged/config-writing operations by default. `app_sudo` is the explicit opt-in.

### `dhcp-option=6` collides with `dhcp.multiDNS`

**Symptom.**
Clients receive garbage DNS servers (entries containing `0.0.0.0`), and `pihole-FTL` logs `Ignoring duplicate dhcp-option 6`.

**Cause.**
Two things try to set DHCP option 6 at once: the manual `dhcp-option=6,...` line in `misc.dnsmasq_lines`, and Pi-hole's own "advertise DNS server multiple times" feature (`dhcp.multiDNS`). When both are active, dnsmasq sees a duplicate option 6 and the auto-generated entry produces `0.0.0.0` placeholders. This is [pi-hole #6360](https://github.com/pi-hole/pi-hole/issues/6360).

**Fix.**
Set option 6 manually (needed to advertise both Pi-hole instances) and keep `dhcp.multiDNS = false`:

```bash
pihole-FTL --config dhcp.multiDNS      # must read false
```

Verify the served config has exactly one option 6, in the generated dnsmasq file:

```bash
grep -E 'dhcp-option|local=/local/' /etc/pihole/dnsmasq.conf
```

### `misc.dnsmasq_lines` is an array — setting it replaces the whole thing

**Symptom.**
Adding the `dhcp-option=6` line via CLI wipes the existing `local=/local/` entry (mDNS latency returns).

**Cause.**
`misc.dnsmasq_lines` is a TOML array. `pihole-FTL --config` sets the entire key — there is no append. Passing only the new line replaces the array and drops `local=/local/`.

**Fix.**
Set the whole array, including every entry you want to keep:

```bash
sudo pihole-FTL --config misc.dnsmasq_lines \
  '[ "local=/local/", "dhcp-option=6,10.33.111.141,10.33.111.142" ]'
pihole-FTL --config misc.dnsmasq_lines     # confirm BOTH entries present
```

### journal is unreadable without `sudo` for non-admin users

**Symptom.**
`journalctl -u nebula-sync.service` prints "No journal files were opened due to insufficient permissions" and shows nothing.

**Cause.**
A user not in the `adm` or `systemd-journal` group can only see its own journal, not system-service logs.

**Fix.**
Prefix with `sudo` (`sudo journalctl -u nebula-sync.service`), or add the user to `adm`/`systemd-journal` if it should read service logs routinely.
