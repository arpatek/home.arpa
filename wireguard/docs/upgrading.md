# Upgrading

Upgrade considerations for WireGuard and the host OS on `netrunner-rpi`.

WireGuard is built into the Linux kernel — there is no separate package to pin or upgrade.
The version you get is whatever the Raspberry Pi OS kernel ships.
The `wireguard-tools` package (`wg`, `wg-quick`) is a separate apt package but is stable and rarely changes in meaningful ways.

## Currently installed

| Component       | Version / Source                              |
| --------------- | --------------------------------------------- |
| WireGuard       | kernel built-in (kernel `6.12.62+rpt-rpi-v8`) |
| wireguard-tools | apt: `wireguard` package                      |
| Raspberry Pi OS | Lite, based on Debian 13 Trixie               |

Check running versions:

```bash
uname -r                        # kernel version
wg --version                    # wireguard-tools version
cat /etc/os-release             # OS version
```

## Upgrading wireguard-tools and OS packages

Standard apt update applies all package updates including `wireguard-tools`:

```bash
sudo apt update && sudo apt upgrade
```

WireGuard-tools updates are infrequent and backward-compatible.
The protocol is frozen — there are no breaking changes between tool versions.

## Upgrading the kernel (Raspberry Pi OS update)

The WireGuard kernel module version is tied to the kernel.
A kernel update arrives as part of a Raspberry Pi OS upgrade:

```bash
sudo apt update && sudo apt full-upgrade
sudo reboot
```

After rebooting, verify WireGuard is still running:

```bash
sudo wg show
systemctl status wg-quick@wg0
```

A kernel upgrade should have no effect on the WireGuard configuration or persistent iptables rules — both survive reboots independently.

## Raspberry Pi OS major version upgrade

When Raspberry Pi OS moves to the next Debian base (e.g. Trixie → whatever follows), the upgrade path is either:

- **In-place via `apt` dist-upgrade** — works for Raspberry Pi OS major releases, follow the official Raspberry Pi documentation for the specific release.
- **Fresh SD card image** — flash a new image, reinstall `wireguard-tools` and `iptables-persistent`, copy `/etc/wireguard/wg0.conf` and `/etc/iptables/rules.v4` from the old card, re-enable the services.

The fresh image approach is lower risk for a Pi.
The entire WireGuard state is in two files (`wg0.conf` and `rules.v4`) plus the sysctl config (`99-wireguard.conf`) — all committed or backed up.

## Adding a new peer

1. Generate a keypair on the new device:

```bash
wg genkey | tee privatekey | wg pubkey > publickey
```

2. Add a `[Peer]` block to `/etc/wireguard/wg0.conf` on `netrunner-rpi`:

```ini
# Peer: <name>
[Peer]
PublicKey = <new-device-public-key>
AllowedIPs = 10.10.10.<next-ip>/32
```

3. Assign the next available IP in the `10.10.10.0/24` range (next after `10.10.10.12`).

4. Reload WireGuard without dropping existing connections:

```bash
sudo wg addconf wg0 <(wg-quick strip wg0)
# or simply restart the service
sudo systemctl restart wg-quick@wg0
```

5. Update the peers table in `README.md` and `wg0.conf.example` in this repo.

## Removing a peer

1. Delete the `[Peer]` block for that peer from `/etc/wireguard/wg0.conf`.
2. Reload: `sudo systemctl restart wg-quick@wg0`.
3. Remove the peer from `README.md` and `wg0.conf.example` in this repo.

The removed peer's keypair is now useless — it can no longer authenticate to the server.
No key revocation ceremony is required.

## Key rotation

If a peer's private key is compromised or a device is lost:

1. Generate a new keypair on a replacement or recovered device.
2. Update the `[Peer] PublicKey` entry in `wg0.conf` on `netrunner-rpi` with the new public key.
3. Reload WireGuard.
4. Update `README.md` and `wg0.conf.example` in this repo.

The old public key immediately stops working once removed from the server config.
