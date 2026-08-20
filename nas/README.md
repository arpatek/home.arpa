# NAS

## Hosts

Two Raspberry Pis serve network storage over SMB. Each backs one or more shares with its own block devices.

### netrunner

|          |                                                                 |
| -------- | --------------------------------------------------------------- |
| Hardware | Raspberry Pi 4B, 8GB RAM, 256GB MicroSD, Argon NEO Case          |
| OS       | Raspberry Pi OS Lite (based on Debian 13 Trixie)                |
| IP       | 10.33.111.141                                                   |
| Hostname | netrunner.home.arpa                                            |
| Storage  | 2 × 500GB USB-attached drives, `mdadm` RAID1 mirror (`/dev/md0`) |
| Serves   | `tank`                                                          |

### edgerunner

|          |                                                                     |
| -------- | ------------------------------------------------------------------- |
| Hardware | Raspberry Pi 4B, 4GB RAM, 128GB MicroSD, Argon ONE M.2 Case          |
| OS       | Raspberry Pi OS Lite (based on Debian 13 Trixie)                    |
| IP       | 10.33.111.142                                                       |
| Hostname | edgerunner.home.arpa                                                |
| Storage  | 500GB USB drive (ex-netrunner NAS) + 250GB M.2 SATA SSD (USB3 bridge) |
| Serves   | `nas`, `stor`                                                      |

## Overview

Network-attached storage for the lab, exported over SMB (Samba) from two Raspberry Pis.
Storage moved from a single-disk setup on `netrunner` to a mirrored pair, and the original data disk was relocated to `edgerunner` rather than migrated.

- **`tank`** (`netrunner`) — a fresh `mdadm` RAID1 mirror. Redundant, empty at creation, intended for data that benefits from surviving a single-disk failure.
- **`nas`** (`edgerunner`) — the original NAS disk, physically moved from `netrunner`. Data left in place, not copied. This carries the existing library (Assets, Books, Git, ROMs, etc.).
- **`stor`** (`edgerunner`) — the M.2 SSD. Fast local/scratch storage for `edgerunner`.

`edgerunner` also runs the redundant Pi-hole replica — see [pihole/](../pihole/). The two roles are independent; this document covers only storage.

## Shares

| Share  | Host         | UNC path                          | Backing store                       | Mount point         |
| ------ | ------------ | --------------------------------- | ----------------------------------- | ------------------- |
| `tank` | `netrunner`  | `//netrunner.home.arpa/tank`      | RAID1 mirror (`/dev/md0`, ext4)     | `/srv/nas`          |
| `nas`  | `edgerunner` | `//edgerunner.home.arpa/nas`      | WD Red SA500 500GB SSD (USB)        | `/srv/shares/nas`   |
| `stor` | `edgerunner` | `//edgerunner.home.arpa/stor`     | WD Blue 250GB SATA SSD (USB, M.2)   | `/srv/shares/stor`  |

Backing stores are referenced by model, not `/dev/sdX` — the USB SSDs re-letter across reboots (see [gotchas.md](docs/gotchas.md)), so all mounts are by UUID.

The old `//netrunner.home.arpa/NAS` share no longer exists — its data moved with the disk to `edgerunner` and is now served as `nas`. Clients that mounted the old path must repoint to `//edgerunner.home.arpa/nas`.

## Access model

Standalone Samba on both hosts (`tdbsam` passdb, not tied to FreeIPA — see [decisions.md](docs/decisions.md)).

| Property        | Value                                            |
| --------------- | ------------------------------------------------ |
| Share owner     | `root:nas`                                       |
| Group           | `nas` (GID `1002`)                               |
| Directory mode  | `2770` (setgid)                                  |
| File mode       | `0660`                                           |
| Allowed users   | `@nas` (any member of the `nas` group)           |

`root:nas` ownership means no single user owns the share tree — group membership grants write, and the setgid bit propagates group ownership down. `force group = nas` in each share stanza guarantees new files land in the group even outside setgid paths.

Add a share user:

```bash
sudo useradd -M -s /usr/sbin/nologin -G nas <user>   # share-only account
sudo smbpasswd -a <user>                             # set Samba password
```

Membership in `nas` is all that's required — the shares allow `@nas`, so `smb.conf` never needs editing per user.

## Repository layout

```
nas/
├── README.md               # this file — hosts, shares, access model
└── docs/
    ├── architecture.md     # RAID1 layer, Samba, share topology
    ├── decisions.md        # design choices and rationale
    ├── gotchas.md          # things that will trip you up
    └── upgrading.md        # growing the array, replacing a disk, adding a share
```

## Installation

Condensed stand-up. See [docs/architecture.md](docs/architecture.md) for the layering, [docs/gotchas.md](docs/gotchas.md) for the `nofail`/USB rationale, and [docs/upgrading.md](docs/upgrading.md) for adding shares or replacing disks.

### netrunner — RAID1 mirror

```bash
# assemble the mirror, create ext4, label it tank
sudo mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdb1 /dev/sdc1
sudo mkfs.ext4 -L tank /dev/md0

# persist the array so it reassembles as /dev/md0 across reboots
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm/mdadm.conf
sudo update-initramfs -u

# mount by filesystem UUID
sudo mkdir -p /srv/nas
echo 'UUID=<fs-uuid>  /srv/nas  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2' | sudo tee -a /etc/fstab
sudo mount -a && findmnt /srv/nas
```

### edgerunner — two independent disks

```bash
sudo mkdir -p /srv/shares/nas /srv/shares/stor
# add both disks to /etc/fstab by UUID with nofail, then:
sudo mount -a && findmnt /srv/shares/nas /srv/shares/stor
```

### Both hosts — Samba

```bash
sudo apt install -y samba
sudo groupadd -g 1002 nas          # matching GID on both hosts
sudo usermod -aG nas <user>

# per-share ownership and stanzas — see docs/architecture.md
sudo chown root:nas /srv/<share> && sudo chmod 2770 /srv/<share>

sudo smbpasswd -a <user>
sudo testparm -s
sudo systemctl enable --now smbd nmbd
smbclient -L localhost -U <user>   # confirm shares list
```

