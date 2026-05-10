# Upgrading

Procedures for upgrading Pi-hole on `netrunner-rpi`.

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
dig prod-mon-0.home.arpa @10.33.111.141

# Check the admin UI is reachable
curl -sk https://netrunner-rpi.home.arpa/admin/ | grep -i "pi-hole"

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

Blocklists are managed through the admin UI at `https://netrunner-rpi.home.arpa/admin/` under Lists.

After adding or removing a list, rebuild gravity to apply the change:

```bash
pihole -g
```

Keep the committed `pihole.toml` in sync with any list changes — blocklist URLs are stored in the SQLite database, not in `pihole.toml`, so the README's blocklist table should be updated manually to reflect the current state.

## Adding or removing local DNS records

Local DNS records are stored in the Pi-hole database and managed through the admin UI under Local DNS.

After adding or removing records, update the local DNS records table in `README.md` to keep the repo in sync.
