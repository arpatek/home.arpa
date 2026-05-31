# Upgrading

Procedures for upgrading FreeIPA and the host OS on `mikoshi`.

IPA upgrades are different from the Docker-based services in the rest of this lab.
There are no container image tags to pin or bump.
The FreeIPA package version is delivered through Rocky Linux's package repositories and tied to the OS point release.
Upgrades happen via `dnf`, not by editing a compose file.

## Currently installed versions

| Component       | Package         | Version             |
| --------------- | --------------- | ------------------- |
| FreeIPA server  | `ipa-server`    | `4.12.2-22.el9_7.3` |
| Rocky Linux     | —               | `9.7 (Blue Onyx)`   |

FreeIPA's component services (389-DS, MIT Kerberos, BIND, Dogtag CA) are all dependencies of the `ipa-server` package.
Their versions are managed together — upgrading `ipa-server` pulls in updated versions of all of them.

Note: the package name on RHEL-family systems is `ipa-server`, not `freeipa-server`.
`rpm -q freeipa-server` returns "package not installed" even on a fully functional IPA server.
Use `rpm -q ipa-server` to check the installed version.

## Before any upgrade

Always take a backup before upgrading.
FreeIPA includes a built-in backup tool that captures all IPA state — LDAP data, Kerberos database, DNS zones, certificates:

```bash
sudo ipa-backup
```

Backups are written to `/var/lib/ipa/backup/`.
Each run creates a timestamped directory.
Copy the backup off the host before proceeding:

```bash
ls /var/lib/ipa/backup/
# scp the latest backup directory to a safe location
```

An alternative is to snapshot the Proxmox VM before the upgrade.
A VM snapshot is faster to restore than an `ipa-restore` but requires the VM to be offline during restore.
Both approaches have value — the IPA backup for granular recovery, the VM snapshot for a full rollback.

## FreeIPA package upgrade (within Rocky 9)

FreeIPA package updates arrive via Rocky Linux's normal update cycle.
A package version change (e.g., `4.12.2 → 4.12.3`) happens when Rocky releases an updated `ipa-server` RPM.

Check if an update is available:

```bash
dnf check-update ipa-server
```

Check the Rocky Linux and upstream FreeIPA release notes before applying.
Upstream release notes: <https://www.freeipa.org/page/Releases>.
FreeIPA applies schema migrations and restarts its services automatically during the `dnf` upgrade — there is no separate migration step.

Apply the update:

```bash
sudo dnf update ipa-server
```

`dnf` upgrades `ipa-server` and all its dependencies (389-DS, Kerberos, BIND, Dogtag) together.
Services restart automatically as part of the RPM post-install scripts.

**Verification.**

```bash
# Confirm the new version
rpm -q ipa-server

# Check all IPA services are running
sudo ipactl status

# Verify DNS is still resolving
dig soulkiller.home.arpa A @mikoshi.home.arpa

# Verify authentication from an enrolled client
ssh soulkiller.home.arpa "id arpatek"
```

**Rollback.**

If the upgrade causes regressions, restore from the pre-upgrade backup:

```bash
sudo ipactl stop
sudo ipa-restore /var/lib/ipa/backup/<backup-directory>
```

Or restore the Proxmox VM snapshot if one was taken.

## Rocky Linux point release upgrade (9.7 → 9.8 → etc.)

Rocky Linux 9.x point releases are cumulative.
Upgrading from 9.7 to 9.8 is a standard `dnf update` — it is not a major version change and does not require special handling.

```bash
sudo dnf update
sudo reboot
```

The FreeIPA package version may increment as part of this update.
The same verification steps apply as for a package-only upgrade.

Take a backup and VM snapshot before the update.
Rebooting `mikoshi` causes a brief outage for all enrolled hosts — they fall back to SSSD's local cache during the reboot window.

## Rocky Linux major version upgrade (9 → 10)

Rocky Linux 10 is available.
A major version upgrade of an IPA server is a significant operation — more so than for other hosts because `mikoshi` is load-bearing for DNS and authentication across the entire lab.

Two paths:

**In-place upgrade via Leapp.**
Red Hat's Leapp tool handles in-place RHEL-family major version upgrades.
FreeIPA is Leapp-aware — the pre-upgrade checks include IPA-specific inhibitors that will block the upgrade if the IPA state is incompatible.
This is the lower-disruption path and keeps all data in place.

```bash
sudo dnf install leapp-upgrade
sudo leapp preupgrade    # run checks, review report
sudo leapp upgrade       # perform the upgrade
sudo reboot
```

Review the Leapp pre-upgrade report carefully.
It will list any inhibitors that must be resolved before the upgrade can proceed.

**Fresh install with data migration.**
Provision a new Rocky 10 VM, install IPA fresh, then use `ipa-backup` / `ipa-restore` to migrate data from the Rocky 9 instance.
More disruptive (requires re-enrolling clients or restoring client-side configs) but produces a clean OS baseline.

Whichever path is chosen: take a full `ipa-backup`, snapshot the VM, and plan for a maintenance window.

## IPA clients after a server upgrade

Enrolled clients generally do not need action when the server is upgraded.
The client communicates with the server over standard protocols (Kerberos, LDAP, DNS) that remain stable across minor FreeIPA versions.

If a client package update is needed:

```bash
# On Debian/Ubuntu clients
sudo apt update && sudo apt install freeipa-client

# On Rocky/RHEL clients
sudo dnf update ipa-client
```

After updating, restart SSSD and verify:

```bash
sudo systemctl restart sssd
id arpatek
sudo -l
```

## Cadence

- **Monthly:** check `dnf check-update ipa-server` and review <https://www.freeipa.org/page/Security_Advisories>
- **With each Rocky point release:** apply `dnf update` after reviewing release notes
- **Before any upgrade:** `ipa-backup`, then snapshot the VM
