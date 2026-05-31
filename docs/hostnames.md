# Hostnames

## Naming convention

All hosts use a **Cyberpunk** themed naming scheme.

> **Note:** [RFC 1178](https://www.rfc-editor.org/rfc/rfc1178) recommends using themed, memorable names for hosts rather than encoding function, location, or environment in the hostname — a function-encoded name like `prod-git-0` becomes misleading the moment the role changes, while a themed name like `soulkiller` remains stable and distinct indefinitely.

Servers use short hostnames (`erebus`, `netwatch`) without a domain suffix — the FQDN is derived from the `home.arpa` search domain configured on all hosts.

IPA-enrolled hosts are an exception: `ipa-client-install` requires the full FQDN at enrollment time, so enrolled VMs carry `hostname.home.arpa` as their OS hostname.

WireGuard client interfaces and configs use the `wg-<hostname>` convention (e.g. `wg-silverhand`, `wg-malorian`).

---

## Host reference

### Lab servers

| Hostname | IP | Previous name | Role |
| -------- | -- | ------------- | ---- |
| `blackwall` | `10.33.111.44` | `devstem` | Proxmox hypervisor |
| `mikoshi` | `10.33.111.100` | `prod-ipa-0` | FreeIPA identity server |
| `soulkiller` | `10.33.111.101` | `prod-git-0` | Gitea + CI |
| `netwatch` | `10.33.111.102` | `prod-mon-0` | Prometheus + Loki + Grafana |
| `erebus` | `10.33.111.103` | `prod-k3s-master-0` | k3s control plane |
| `sandevistan` | `10.33.111.104` | `prod-k3s-worker-0` | k3s worker |
| `kerenzikov` | `10.33.111.105` | `prod-k3s-worker-1` | k3s worker |
| `netrunner` | `10.33.111.141` | `netrunner-rpi` | Pi-hole + WireGuard + NAS |
| `drone-01` | `10.33.111.200` | `dev-rhel-0` | Dev VM (RHEL, normally stopped) |
| `drone-02` | `10.33.111.201` | `dev-ubuntu-0` | Dev VM (Ubuntu, normally stopped) |

### Personal devices

| Hostname | Previous name | Device |
| -------- | ------------- | ------ |
| `silverhand` | `asahi` | MacBook Air (Asahi Linux) |
| `malorian` | `node-zero` | MacBook Air (macOS) |
| `uplink` | `deck-alpha` | iPhone |
| `dataslab` | `deck-gamma` | iPad Mini |
| `mizutani` | `node-one` | Mac Mini |
| `earworm` | — | AirPods Pro 2 |
| `neurojack` | — | AirPods Pro 2 (USB-C) |
| `noiseburn` | — | Sony WH-1000XM4 |

### WireGuard peers

| Peer interface | Previous name | Device |
| -------------- | ------------- | ------ |
| `wg-malorian` | `node-zero` | MacBook Air (macOS) |
| `wg-uplink` | `deck-alpha` | iPhone |
| `wg-dataslab` | `deck-gamma` | iPad Mini |
| `wg-silverhand` | `wg-asahi` | MacBook Air (Asahi Linux) |

---

## Migration notes

Performed 2026-05-31. Key steps and gotchas:

- **IPA-enrolled VMs** required unenroll → hostname change → re-enroll. The `ipa-client-install --uninstall` command exits non-zero due to `sssd-kcm` not being loaded — this is a warning, not a failure. Use `;` instead of `&&` when chaining the uninstall with subsequent commands.
- **New hosts must be added to a host group** after re-enrollment before IPA-based SSH (`arpatek`) works. HBAC rule `allow_ssh_devops` covers `prod-vms`, `infra`, `dev-vms`, and `ipaservers`.
- **k3s nodes** required `kubectl drain` + `kubectl delete node` before rename, and the old node entry must be manually deleted after restart (`kubectl delete node old-name.home.arpa`).
- **CIFS/SMB case-only renames** fail from the client — always SSH into netrunner for those.
- **Pi-hole local DNS** (`/etc/pihole/pihole.toml`) is separate from FreeIPA DNS and must be updated independently. Live config is gitignored; use `pihole reloaddns` after changes.
- **SSH too many authentication failures** — connect with `-i ~/.ssh/<host>.key -o IdentitiesOnly=yes` when the ssh-agent has many keys cached.
- **IPA server rename** (`mikoshi`) is pending — requires `ipa-backup`, uninstall, hostname change, reinstall, and restore. All clients will need their `/etc/ipa/default.conf`, `/etc/sssd/sssd.conf`, and `/etc/krb5.conf` updated to point to `mikoshi.home.arpa` afterwards.
