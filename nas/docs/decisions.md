# Decisions

The design choices made while restructuring the NAS across two Pis.

## RAID1 mirror over a single disk

**Decision.** `netrunner`'s NAS storage is a two-disk `mdadm` RAID1 mirror, not a single disk.

**Alternatives considered.**

_Single disk._ What the NAS ran on previously. Simplest, full capacity, no redundancy. A single disk failure loses everything until a restore.

_RAID0 / larger single disk._ More capacity, no redundancy. Wrong trade for data meant to be resilient.

_RAID5/6._ Needs three or more disks and more CPU/RAM for parity. Overkill on a 2-disk Pi and not worth the parity overhead at this scale.

**Why RAID1.**

A mirror is the simplest redundancy that survives a disk failure with zero data loss and no rebuild math. On a Pi with two USB disks it's the natural fit — `mdadm` is in-kernel, battle-tested, and adds no daemon. The cost is halved usable capacity, which is acceptable for the working set.

RAID1 is redundancy, not backup — it protects against hardware failure of one disk, not against deletion, corruption, or ransomware, all of which mirror instantly to both members. Backups are a separate concern (see [gotchas.md](gotchas.md)).

## ext4 over btrfs or ZFS

**Decision.** The RAID1 array and both `edgerunner` disks are `ext4`.

**Alternatives considered.**

_btrfs raid1._ Native mirroring with data checksums, self-healing, and snapshots. Real bit-rot protection. More operational care on a Pi, and its RAID story has historically needed attention.

_ZFS mirror._ Checksums, snapshots, `send/recv`. Wants 8GB+ RAM and is the heaviest option — only sane on a well-specced Pi, and even then it's a lot of machinery for a 2-disk mirror.

**Why ext4.**

`ext4` is the lightest, most boring-reliable choice on a Pi, and boring is the point for always-on storage. `mdadm` + `ext4` is a combination with decades of production history and no surprises. The integrity guarantees of btrfs/ZFS are real, but on a single-mirror homelab NAS the added RAM pressure and operational complexity aren't justified — and on a 1GbE Pi the filesystem is never the bottleneck. Bit-rot protection is a fair reason to revisit btrfs later; it wasn't worth blocking this rebuild on.

## Relocating the old disk instead of migrating its data

**Decision.** The original NAS disk was physically moved from `netrunner` to `edgerunner` and served in place as the `nas` share. Its data was not copied onto the new RAID1 mirror.

**Alternatives considered.**

_Migrate then wipe._ Copy the old disk's data onto the new mirror, verify, then repurpose the old disk empty. The "safe sequencing" default when the goal is consolidating onto the mirror.

**Why relocate.**

The goal wasn't to consolidate — it was to grow the storage footprint across two Pis. Moving the disk keeps its existing data intact with zero copy time and zero migration risk, and immediately gives `edgerunner` a populated share. The `tank` mirror starts empty and fills on its own terms. The only cost is that clients must repoint from `//netrunner/NAS` to `//edgerunner/nas` — a one-line change per client.

## Standalone Samba users over FreeIPA integration

**Decision.** Both hosts run standalone Samba with a local `tdbsam` password database. Neither is enrolled in FreeIPA for identity.

**Alternatives considered.**

_FreeIPA-integrated Samba._ Enroll the Pis and authenticate SMB against IPA/Kerberos. Single identity source, consistent with the rest of the lab.

**Why standalone.**

The migrated data is entirely `sysadmin`-owned (UID `1000`), which resolves identically on both Pis without any directory service. No file on the disk is owned by the IPA `arpatek` account, so there is nothing that requires IPA identity to serve correctly. Enrolling the Pis would pull `netrunner` (which also runs DNS, DHCP, and the VPN) into a Kerberos dependency it doesn't otherwise need, and add SSSD/keytab machinery for no functional gain. Keeping Samba standalone matches the existing setup and keeps the storage layer independent of the identity layer.

This is deliberately different from the lab VMs, which are IPA-enrolled. The Pis are always-on infrastructure kept intentionally simple.

## root:nas group ownership over user ownership

**Decision.** Share trees are owned `root:nas`, `2770`, with `force group = nas` and `valid users = @nas`.

**Alternatives considered.**

_User-owned (`sysadmin:sysadmin`)._ Simpler to reason about with one user. But it ties the share to a single account and makes adding a second writer a per-file ownership problem.

**Why root:nas.**

`root` owning the tree means no regular user can change ownership or delete the share root out from under others. The `nas` group grants write to any member, the setgid bit propagates group ownership into new subdirectories, and `force group = nas` covers the rest. Adding a writer becomes a pure group-membership operation — no `smb.conf` edit, no `chown` sweep. It's the standard multi-user NAS shape and scales cleanly past one user.
