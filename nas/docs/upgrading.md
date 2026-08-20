# Upgrading

Procedures for maintaining and extending the NAS.

## Backups

RAID1 is redundancy, not backup. It survives a disk failure; it does not survive deletion, corruption, or a filesystem fault — those replicate to both mirror members instantly.

**Current posture.**

| Data                        | Protection                                              |
| --------------------------- | ------------------------------------------------------- |
| `tank` (RAID1, `netrunner`) | Mirror survives one disk failure. No off-box backup yet. |
| `nas` (old disk, `edgerunner`) | Manual `rsync` to an external Sabrent drive, on demand. |
| `stor` (SSD, `edgerunner`)  | Scratch/fast-local — treat as disposable unless noted.  |

The manual-to-Sabrent flow is a deliberate choice, not an oversight — see the homelab backup strategy. Automate it only if the working set outgrows a manual cadence.

**Known gap.** Neither Pi's OS/config state (`smb.conf`, `fstab`, `mdadm.conf`, Pi-hole config) is backed up off-box. `edgerunner` is now a second host in this gap, alongside `netrunner`. Rebuilding either means reinstalling from this repo's documented config. Accepted for now; revisit if rebuild time becomes a concern.

Manual data backup (adjust source/target):

```bash
rsync -aHAX --info=progress2 /srv/shares/nas/ /mnt/sabrent/nas-backup/
```

## Replacing a failed RAID1 disk

When `mdadm` reports a failed member (`/proc/mdstat` shows `[U_]` or `[_U]`, and `mdadm --detail /dev/md0` marks a disk `faulty`):

1. **Identify the failed disk** by serial before touching hardware:
   ```bash
   sudo mdadm --detail /dev/md0
   for d in sdb sdc; do echo "$d: $(sudo hdparm -I /dev/$d 2>/dev/null | grep -i 'serial')"; done
   ```

2. **Remove the failed member** from the array (if not already removed):
   ```bash
   sudo mdadm /dev/md0 --remove /dev/sdX1
   ```

3. **Physically swap the disk**, then partition the replacement to match the surviving member:
   ```bash
   sudo sfdisk -d /dev/<good> | sudo sfdisk /dev/<new>   # clone partition table
   ```

4. **Add the new member** and let it resync:
   ```bash
   sudo mdadm /dev/md0 --add /dev/sdX1
   watch cat /proc/mdstat        # progress; array stays online, degraded, during resync
   ```

The array serves data throughout the rebuild. Resync of a 500GB mirror over USB takes hours — don't power-cycle mid-resync.

## Growing the array

To move to larger disks, replace one member at a time (steps above) with a bigger disk, let each resync, then after both are swapped grow the array and filesystem:

```bash
sudo mdadm --grow /dev/md0 --size=max
sudo resize2fs /dev/md0
```

Both members must be the larger size before the filesystem can expand. This is why one-at-a-time replacement works for capacity upgrades as well as failures.

## Adding a new share

1. Mount the backing store by UUID in `/etc/fstab` (use `nofail` for USB — see [gotchas.md](gotchas.md)):
   ```bash
   sudo blkid /dev/sdX1                    # get the UUID
   sudo mkdir -p /srv/shares/<name>
   # append fstab line, then:
   sudo mount -a && findmnt /srv/shares/<name>
   ```

2. Set ownership to match the model:
   ```bash
   sudo chown root:nas /srv/shares/<name>
   sudo chmod 2770 /srv/shares/<name>
   ```

3. Add the share stanza to `/etc/samba/smb.conf` (copy an existing one, change `path` and header), then:
   ```bash
   sudo testparm -s                        # validate config
   sudo systemctl reload smbd nmbd
   smbclient -L localhost -U sysadmin      # confirm the share lists
   ```

Keep the shares table in [../README.md](../README.md) in sync when shares are added or removed.

## OS upgrades

Samba and `mdadm` run as userspace/kernel components managed by the distro. Raspberry Pi OS patch upgrades (`apt update && apt upgrade`) are safe to apply.

For a major OS upgrade, back up the config files first — they are the only thing not reconstructible from disk:

```bash
sudo tar czf ~/nas-config-backup.tgz \
  /etc/samba/smb.conf /etc/fstab /etc/mdadm/mdadm.conf
```

After the upgrade, verify the array assembles, the filesystems mount, and the shares serve:

```bash
cat /proc/mdstat            # netrunner: array healthy [UU]
findmnt /srv/nas /srv/shares/nas /srv/shares/stor 2>/dev/null
smbclient -L localhost -U sysadmin
```
