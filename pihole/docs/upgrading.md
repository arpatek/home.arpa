# Upgrading

Procedures for upgrading Pi-hole on `netrunner`.

## Currently installed

| Component | Version |
| --------- | ------- |
| Pi-hole   | v6.6    |
| FTL       | v6.6    |

Check running versions:

```bash
pihole version
pihole-FTL version
```

## Upgrading Pi-hole

Pi-hole provides a built-in update command:

```bash
pihole -up
```

This updates the Pi-hole scripts, FTL binary, and web interface in place.
The command checks for available updates, downloads them, and restarts the relevant services automatically.

Check for available updates without applying:

```bash
pihole -up --check-only
```

**Before upgrading**, note the current version and skim the release notes at <https://github.com/pi-hole/pi-hole/releases>.
Pay attention to any breaking changes in `pihole.toml` — new settings may be added and defaults may change between minor versions.
Pi-hole v6 introduced `pihole.toml` as a unified config, replacing the multiple-file approach from v5.
Future major versions may introduce similar structural changes.

**After upgrading:**

```bash
# Verify services are running
systemctl status pihole-FTL
systemctl status lighttpd

# Check DNS is resolving
dig netwatch.home.arpa @10.33.111.141

# Check the admin UI is reachable
curl -sk https://netrunner.home.arpa/admin/ | grep -i "pi-hole"

# Verify gravity is intact (blocklist still active)
pihole status
```

**Rollback.**
Pi-hole does not have a built-in rollback mechanism.
If an upgrade breaks something, the options are:
- Restore from a Raspberry Pi SD card backup taken before the upgrade
- Reinstall Pi-hole and restore `pihole.toml` from this repo, then re-run `pihole -g` to rebuild gravity

## Updating blocklists (gravity)

Blocklists don't update automatically — gravity must be rebuilt manually or on a cron schedule.

Rebuild gravity (re-downloads all blocklists and recompiles the database):

```bash
pihole -g
```

Pi-hole can be configured to run `pihole -g` on a schedule via its built-in cron support.
Check the current schedule in the admin UI under Settings → System.

## Raspberry Pi OS upgrades

Pi-hole runs as a userspace application and is not tied to the kernel.
Raspberry Pi OS patch upgrades (`apt update && apt upgrade`) are safe to apply without touching Pi-hole.

For major Raspberry Pi OS upgrades, the safest path is:
1. Take a full SD card image backup
2. Apply the OS upgrade
3. Verify Pi-hole still works: `pihole status`, DNS resolution, admin UI
4. If broken, restore the SD card image and investigate

## Adding or removing blocklists

Blocklists are managed through the admin UI at `https://netrunner.home.arpa/admin/` under Lists.

After adding or removing a list, rebuild gravity to apply the change:

```bash
pihole -g
```

Keep the committed `pihole.toml` in sync with any list changes — blocklist URLs are stored in the SQLite database, not in `pihole.toml`, so the README's blocklist table should be updated manually to reflect the current state.

## Adding or removing local DNS records

Local DNS records are stored in the Pi-hole database and managed through the admin UI under Local DNS.

After adding or removing records, update the local DNS records table in `README.md` to keep the repo in sync.

## Upgrading the replica (edgerunner)

`edgerunner` runs an independent Pi-hole install — upgrade it the same way as `netrunner` (`pihole -up`), separately. The two are not upgraded in lockstep; `nebula-sync` replicates *config*, not the Pi-hole binaries.

Keep the versions close. A large version skew between primary and replica can cause Teleporter import mismatches if the config schema changes between releases. After upgrading either, run a manual sync and confirm it still completes:

```bash
# on netrunner
sudo systemctl start nebula-sync.service
sudo journalctl -u nebula-sync.service -n 20 --no-pager     # expect "Sync completed"
```

## Upgrading nebula-sync

The binary lives at `/usr/local/bin/nebula-sync` on `netrunner`, installed by hand from GitHub releases. It is not managed by `apt`.

```bash
cd /tmp
ver=$(curl -fsSL https://api.github.com/repos/lovelaze/nebula-sync/releases/latest | grep '"tag_name"' | grep -o 'v[0-9][^"]*' | tr -d '\r')
base="nebula-sync_${ver#v}_linux_arm64.tar.gz"
curl -fsSLO "https://github.com/lovelaze/nebula-sync/releases/download/${ver}/${base}"
curl -fsSLO "https://github.com/lovelaze/nebula-sync/releases/download/${ver}/checksums.txt"
sha256sum --ignore-missing -c checksums.txt     # must print OK before proceeding
tar xzf "$base"
sudo install -m 0755 nebula-sync /usr/local/bin/nebula-sync
nebula-sync --version
```

Always verify the checksum before installing — this binary runs as root-adjacent on the DNS/DHCP host. After upgrading, trigger a run and read the log to confirm the env schema still parses (env var names occasionally change between major versions — check the release notes):

```bash
sudo systemctl start nebula-sync.service
sudo journalctl -u nebula-sync.service -n 20 --no-pager
```

If env vars changed, update `/etc/nebula-sync/nebula-sync.env` and the committed [../nebula-sync/nebula-sync.env.example](../nebula-sync/nebula-sync.env.example) together.

## Verifying HA health

Quick end-to-end check that both resolvers work and the replica is in sync:

```bash
# both instances answer
dig +short google.com @10.33.111.141
dig +short google.com @10.33.111.142

# DHCP hands out both (on netrunner)
grep -E 'dhcp-option|local=/local/' /etc/pihole/dnsmasq.conf

# the guard held — edgerunner is NOT running DHCP
ssh edgerunner 'pihole-FTL --config dhcp.active'      # must be false

# config replicated — adlist counts match
for h in 10.33.111.141 10.33.111.142; do
  echo -n "$h: "; ssh "$h" "echo 'SELECT COUNT(*) FROM adlist;' | sudo sqlite3 /etc/pihole/gravity.db"
done
```
