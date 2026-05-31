# Upgrading

Procedures for upgrading Proxmox VE on `blackwall`.

## Currently installed

| Component   | Version   |
| ----------- | --------- |
| Proxmox VE  | 9.1.9     |
| Kernel      | 7.0.0-3-pve |
| Debian base | Debian 12 (Bookworm) |

Check running versions:

```bash
pveversion -v
uname -r
```

## Package upgrades (within Proxmox 9.x)

Proxmox follows Debian's package management.
Minor updates and security patches arrive via `apt`:

```bash
apt update && apt dist-upgrade
```

Use `dist-upgrade` rather than `upgrade` — Proxmox packages occasionally require dependency resolution that `upgrade` won't handle.

Check the Proxmox changelog before upgrading: <https://pve.proxmox.com/wiki/Roadmap>

After upgrading packages, check if a kernel update was included:

```bash
proxmox-boot-tool kernel list
```

If a new kernel is listed, reboot to load it:

```bash
reboot
```

**Impact on running VMs:** A kernel update requires a host reboot, which stops all VMs.
Schedule accordingly — all lab services go down during a host reboot.

## Major version upgrade (Proxmox 9 → 10)

Proxmox major version upgrades are in-place — no reinstall required.
Each upgrade requires following the official upgrade guide for that specific version transition.

The general process:

```bash
# Verify the current system is fully up to date first
apt update && apt dist-upgrade

# Run the Proxmox upgrade checker — lists any blockers
pve7to8 --full   # adjust version numbers per the target release
# or
pve8to9 --full

# Follow the official guide at:
# https://pve.proxmox.com/wiki/Upgrade_from_8_to_9
```

**Before any major upgrade:**
- Take Proxmox-level snapshots of all running VMs
- Note VM IDs and configs (`qm config <vmid>` for each)
- Back up `/etc/pve/` — this directory holds all VM configs, storage configs, and network config

The upgrade checker (`pveXtoY --full`) catches the most common blockers before you commit to the upgrade.
Do not skip it.

## Backing up VM configurations

VM configurations live in `/etc/pve/qemu-server/<vmid>.conf`.
These are plain text files and small — worth committing or copying off-host before any major change:

```bash
# Copy all VM configs to a backup location
cp -r /etc/pve/qemu-server/ ~/vm-configs-backup-$(date +%Y%m%d)/
```

The actual VM disk data lives on `local-lvm` and is not captured by copying these config files.
For full VM backups, use Proxmox's built-in backup tool (`vzdump`) or snapshot via the web UI before upgrading.

## Cadence

- **Monthly:** `apt update && apt dist-upgrade`
- **After each upgrade:** verify all VMs are running with `qm list`
- **Before major upgrades:** snapshot all VMs, back up `/etc/pve/`
