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
