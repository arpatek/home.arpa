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
