# Gotchas

Issues encountered during the Proxmox installation and initial setup.

## Enterprise subscription repository blocks apt on a fresh install

**Symptom.**
Running `apt update` immediately after a fresh Proxmox install returns errors:

```
Err:1 https://enterprise.proxmox.com/debian/pve bookworm InRelease
  401 Unauthorized [IP: ...]
W: Failed to fetch https://enterprise.proxmox.com/debian/pve/dists/bookworm/InRelease
   401 Unauthorized
```

`apt upgrade` and any package installation fail until this is resolved.

**Cause.**
Proxmox is free to use but the default install configures the enterprise package repository (`enterprise.proxmox.com`), which requires an active paid subscription.
Without a valid subscription key, apt cannot authenticate to the enterprise repo and all package operations fail.

**Fix.**
Disable the enterprise repository and enable the no-subscription community repository.
A community post-install script handles this automatically alongside other common setup tasks (removing the subscription nag, enabling dark mode, etc.):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"
```

Or manually:

```bash
# Disable enterprise repo
echo "# disabled - no subscription" > /etc/apt/sources.list.d/pve-enterprise.list

# Add no-subscription repo
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  >> /etc/apt/sources.list

apt update && apt dist-upgrade
```

**Broken assumption.**
I assumed a fresh Proxmox install would be usable without a subscription.
It is — but not without first switching the package repository.
The enterprise repo is the default and must be explicitly replaced.

## Directory storage over a CIFS subdir mount reports wrong capacity and has no offline guard

**Symptom.**
`pvesm status` shows `nas-isos` with the same total/used as the root filesystem instead of the NAS share's capacity.
Worse: if the CIFS mount drops, the storage stays "active" — Proxmox sees an empty directory on the root disk and silently writes ISO uploads there.

**Cause.**
`nas-isos` is a `dir` storage at `/mnt/nas-isostore`, but the CIFS share (`//netrunner.home.arpa/NAS/ISOs`) is mounted one level deeper, at `/mnt/nas-isostore/template/iso` — the subdir Proxmox uses for ISO content.
Directory storage measures capacity at the storage root, which lives on the root filesystem.
And without `is_mountpoint`, Proxmox has no way to know the path is supposed to be a mount — a missing mount looks identical to an empty storage.

**Fix.**
`is_mountpoint` accepts an explicit path, so it can point at the subdir where the mount actually lives:

```bash
pvesm set nas-isos --is_mountpoint /mnt/nas-isostore/template/iso
```

With this set, Proxmox marks the storage inactive whenever the mount is down and refuses to write to it.
Capacity reporting stays wrong (still measured at the storage root) — cosmetic, tolerated.

**Broken assumption.**
I assumed an active directory storage implied its backing mount was healthy.
Proxmox treats a `dir` storage as just a path — mounted, unmounted, it doesn't care unless `is_mountpoint` tells it to check.
