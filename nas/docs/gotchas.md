# Gotchas

Issues encountered during the NAS restructure.

## USB-attached disks can hang boot without `nofail`

**Symptom.**
A Pi with a USB-attached disk in `/etc/fstab` drops to an emergency shell at boot, or hangs waiting on the mount, when the disk is slow to enumerate or absent.

**Cause.**
USB storage on a Pi enumerates later and less reliably than internal storage. A standard `fstab` entry is treated as required — if the device isn't ready when `systemd` tries to mount it, the boot fails. On a headless Pi that means an unreachable box.

**Fix.**
Mount USB-backed stores with `nofail` and a device timeout:

```
UUID=<uuid>  /srv/shares/nas  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2
```

`nofail` lets the boot proceed if the disk is missing; `x-systemd.device-timeout=30` caps the wait at 30 seconds instead of the default 90. Applies to both `edgerunner` disks and, on `netrunner`, to the RAID1 mount — a failure to assemble the full array should never wedge a box that also serves DNS, DHCP, and the VPN.

**Verify netrunner.** The original `/srv/nas` line predates this convention and may lack `nofail`. Confirm:

```bash
grep /srv/nas /etc/fstab
```

If `nofail` is absent, add it. `mdadm` still assembles a RAID1 degraded on single-disk loss; `nofail` only covers the full-assembly-failure edge.

---

## The "NVMe" in the Argon ONE M.2 case is SATA, not NVMe

**Symptom.**
Expecting `/dev/nvme0n1` on `edgerunner`; the drive shows up as `/dev/sdb` instead.

**Cause.**
The Raspberry Pi 4B has no PCIe lanes exposed. The Argon ONE M.2 case for the Pi 4 accepts M.2 **SATA** (B-key/B+M-key) drives and bridges them to the Pi over internal USB 3.0. True NVMe (M-key/PCIe) drives don't function in it. Either way the drive presents as a USB block device, not an NVMe namespace.

**Implication.**
Reference it by UUID, never by `/dev/nvme*`. Its throughput is also capped by the Pi's single 1GbE NIC (~110 MB/s) for anything served over SMB — the SSD's speed only helps local work on `edgerunner`, not the `stor` share over the network.

**Broken assumption.**
"M.2 in a case" implied NVMe. On the Pi 4 platform, M.2 means SATA-over-USB. The speed rating is irrelevant to the network share.

---

## USB SATA-SSD bridges drop off the bus under UAS (stor, 2026-08-14)

**Symptom.**
A share silently stops working. `findmnt` shows the mount with a `shutdown` flag in its options, `lsblk` shows the device re-lettered (`sdb` → `sdc`) or missing, and `dmesg` logs `Buffer I/O error`, `JBD2: I/O error`, then repeated `EXT4-fs warning ... error -5 reading directory block ... comm smbd`. Samba serves EIO to clients until it's remounted.

**Cause.**
Both SSDs enumerate over USB on the `uas` (USB Attached SCSI) driver. The `stor` SSD sits behind a JMicron JMS583 bridge (`152d:0583`) — a chip with known UAS instability on the Pi. Under a glitch the bridge resets, the device drops off the bus, ext4 shuts the filesystem down, and the mount goes stale pointing at a now-gone device. USB re-enumeration reassigns the device letter on return — which is exactly why the shares mount by UUID, not `/dev/sdX`.

**Fix / status.**
The filesystem survived (journal replayed clean under `fsck.ext4 -f`). One drop on 2026-08-14, treated as a one-off rather than chronic, so the UAS quirk is **deferred**, not applied. If it recurs, disable UAS for the bridge(s) by appending to `/boot/firmware/cmdline.txt` (it is a single line — back it up first, a malformed line makes the Pi unbootable):

```
usb-storage.quirks=152d:0583:u,174c:1156:u
```

The `:u` flag (IGNORE_UAS) drops the bridge to plain BOT — slower, but stable, and invisible behind the Pi's 1GbE for the shares.

**Detection.**
The `nas-health` timer ([health/](../health/)) probes both mounts every 5 minutes and logs a journald error on failure, so a recurrence surfaces in minutes instead of the 3 days this one went unnoticed. Check with `journalctl -p err -u nas-health`.

**Broken assumption.**
"Mounted and healthy in `lsblk`" is not "device stable." A `shutdown` flag in `findmnt` options, or a device that changed letters, is the tell that a USB drive dropped and came back.

---

## An assembled RAID array is not a mounted, in-service array

**Symptom.**
`cat /proc/mdstat` shows `md0` healthy (`[UU]`), so the array looks "live" — but the filesystem is empty and writes seem to vanish.

**Cause.**
`mdadm` can assemble an array as `auto-read-only` and leave it unmounted. If Samba's share path (`/srv/nas`) exists as a plain directory while the array isn't mounted there, Samba serves the empty SD-card directory underneath the mountpoint, and writes land on the root disk instead of the mirror. The first real write also flips the array out of `auto-read-only`.

**Fix.**
Confirm the array is actually mounted before pointing a share at it:

```bash
findmnt /srv/nas          # SOURCE must be /dev/md0
```

An assembled array (`/proc/mdstat`), a mounted filesystem (`findmnt`), and a persisted config (`mdadm.conf` + initramfs) are three separate facts — verify all three, not just the first.

---

## `inherit permissions` overrides the create/directory masks

**Symptom.**
New files and directories don't get exactly the mode set in `create mask` / `directory mask`.

**Cause.**
`inherit permissions = yes` tells Samba to take permission bits from the parent directory instead of applying the masks. When the parent is a `2770` setgid directory the result matches what the masks would give, so the two settings agree here — but the parent, not the mask, is authoritative.

**Implication.**
This is harmless as configured (setgid parents produce `2770`/`0660`), just be aware the masks are belt-and-suspenders, not the source of truth, whenever `inherit permissions` is on.

---

## Statically-configured clients don't follow share or DNS changes

**Symptom.**
A device keeps mounting the old `//netrunner/NAS` path, or keeps using a single Pi-hole, after the network-wide change.

**Cause.**
SMB mounts are configured per client, and statically-addressed hosts (e.g. `mizutani`, which uses a manual IP) never pick up DHCP-delivered changes. There is no push mechanism — each client's mounts must be updated by hand.

**Fix.**
Repoint every client that mounted the old NAS:

- Unmount `//netrunner.home.arpa/NAS`.
- Mount `//edgerunner.home.arpa/nas` (the relocated data), plus `//netrunner.home.arpa/tank` and `//edgerunner.home.arpa/stor` as needed.

Keep an inventory of which devices mount which shares; there's no server-side list of expected clients.

---

## SMB case-only renames must be done on the server

**Symptom.**
Renaming a share directory or file by case only (e.g. `NAS` → `nas`) fails from a macOS client.

**Cause.**
macOS SMB and the case-insensitive client filesystem can't perform a case-only rename over the wire.

**Fix.**
SSH into the serving Pi and rename locally. The disk label was changed the same way (`e2label /dev/sda1 nas`) rather than through any client. (Same gotcha noted for the `home.arpa` rename in [../../docs/hostnames.md](../../docs/hostnames.md).)
