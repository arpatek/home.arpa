# Gotchas

Issues encountered during the WireGuard setup.

## Key generation has no PKI — it's just random bytes

**Symptom.**
Confusion about how to generate keys and get peers connected.
Looking for a certificate authority, a CSR workflow, or a signing step that doesn't exist.

**Cause.**
WireGuard's authentication model is completely different from OpenVPN or IPsec.
There is no certificate authority, no certificate signing request, no PKI.
Each peer generates its own keypair locally using `wg genkey`.
The public key is shared with whoever needs it.
That's the entire key management workflow.

**Fix.**
Generate a keypair on the device that will use it:

```bash
# Generate private key and derive public key in one step
wg genkey | tee privatekey | wg pubkey > publickey
```

The private key goes into `[Interface] PrivateKey` on that device.
The public key goes into `[Peer] PublicKey` on every device that needs to communicate with it.
Private keys never leave the device that generated them.

**Broken assumption.**
I assumed WireGuard key management would resemble other VPNs — a CA, a signing ceremony, certificate files.
WireGuard uses raw Curve25519 keypairs with no ceremony.
The public key is its own trust anchor.

## Peers connect to the tunnel but can't reach the LAN

**Symptom.**
WireGuard handshake succeeds — `wg show` reports a recent last handshake and data is being exchanged.
But the peer can't ping or reach any LAN host (`10.33.111.x`).
Traffic disappears after entering the tunnel.

**Cause.**
The WireGuard interface (`wg0`) establishes the encrypted tunnel, but two additional things are required for packets to actually reach the LAN:

1. **IP forwarding** must be enabled in the kernel, otherwise the kernel won't route packets between interfaces.
2. **NAT and FORWARD rules** must be active in iptables — without them, packets from `10.10.10.x` arrive on `eth0` from an unknown source, and LAN devices have no route back to the `10.10.10.0/24` subnet.

**Fix.**
Enable IP forwarding persistently:

```bash
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard.conf
sudo sysctl --system
```

Add and persist the iptables rules:

```bash
sudo iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
sudo netfilter-persistent save
```

Using `iptables-persistent` (rather than PostUp/PostDown hooks in `wg0.conf`) means the rules are loaded at boot independently of WireGuard, which is cleaner — the forwarding and NAT rules should always be active whether or not the WireGuard interface is up.

**Broken assumption.**
I assumed that configuring the WireGuard interface and getting a handshake was enough for full connectivity.
The tunnel handles encryption and decryption — IP forwarding and NAT are separate concerns handled independently by the kernel.

## MTU mismatch causes silent TCP failures on large transfers

**Symptom.**
WireGuard connects and basic connectivity works.
Small packets (pings, DNS queries, SSH commands) succeed.
Large transfers (file copies, git clones, HTTP downloads) stall or fail silently mid-stream.

**Cause.**
The default WireGuard MTU is 1420 bytes (standard Ethernet 1500 minus ~80 bytes of WireGuard and UDP/IP overhead).
This ISP adds additional overhead that reduces the effective path MTU below 1420.
Packets above the actual path MTU are fragmented or dropped silently, which only manifests under load on large TCP transfers.

**Fix.**
Set a conservative MTU on the WireGuard interface in `wg0.conf`:

```ini
[Interface]
MTU = 1380
```

To find the right value for a given connection, ping with a fixed packet size until drops stop:

```bash
ping -M do -s 1350 prod-mon-0.home.arpa   # adjust -s until pings succeed consistently
```

**Broken assumption.**
I assumed the default MTU would work because WireGuard already accounts for its own overhead.
It accounts for its overhead relative to standard Ethernet, not relative to additional ISP encapsulation on top of that.

## AllowedIPs = 0.0.0.0/0 routes all traffic through the tunnel

**Symptom.**
Internet browsing and downloads become significantly slower when connected to WireGuard.
The connection feels throttled even on a fast local connection.

**Cause.**
Setting `AllowedIPs = 0.0.0.0/0` in the client's peer config routes all traffic — including regular internet traffic — through the tunnel.
Every request goes out through the home network's internet connection.
The home upload bandwidth becomes the bottleneck for the client's downloads.

**Fix.**
Use split tunneling — set `AllowedIPs` to only the subnets that need to route through the VPN:

```ini
[Peer]
AllowedIPs = 10.33.111.0/24, 10.10.10.0/24
```

Internet traffic goes directly from the client device.
LAN access still works because the relevant subnets are routed through the tunnel.

**Broken assumption.**
I assumed `0.0.0.0/0` was a reasonable default for "full access."
For a use case where the goal is LAN access rather than privacy or anonymity, split tunneling is the correct configuration.
