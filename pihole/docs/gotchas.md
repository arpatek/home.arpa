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
Set both `revServer` entries to `false` (disabled):

```toml
revServers = [
  "false,10.33.111.0/24,10.33.111.1,home.arpa",
  "false,10.10.10.0/24,10.33.111.141#55055,home.arpa",
]
```

Pi-hole answers reverse DNS queries for both subnets directly from its local DNS records, which already contain A records for all lab hosts and WireGuard peers.
No delegation is needed.

**Broken assumption.**
I assumed `revServers` was needed to enable reverse DNS for the local subnets.
Pi-hole can answer PTR queries for any host it has an A record for, without delegation.
The `revServers` feature is for situations where another server is authoritative for reverse DNS — typically when a router or another DNS server owns that zone.
In this network, Pi-hole owns all the records.
