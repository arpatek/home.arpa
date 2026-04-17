# FreeIPA

## Host

|                  |                                                |
| ---------------- | ---------------------------------------------- |
| Hardware         | Virtual Machine on Proxmox (devstem)           |
| Machine Type     | q35                                            |
| Sockets          | 1                                              |
| Cores            | 2                                              |
| CPU Type         | host (physical CPU passthrough)                |
| RAM              | 3072 MB                                        |
| Disk             | 80GB qcow2 (VirtIO SCSI, iothread enabled)     |
| Network          | VirtIO, bridge vmbr0, Proxmox firewall enabled |
| OS               | Rocky Linux 9.7 (Blue Onyx)                    |
| IP               | 10.33.111.100                                  |
| Hostname         | prod-ipa-0.home.arpa                           |
| Start on Boot    | Yes                                            |
| QEMU Guest Agent | Enabled                                        |

## Overview

Centralized identity management server providing authentication, authorization, and DNS for the home.arpa domain.
FreeIPA integrates Kerberos, LDAP (389 Directory Server), DNS (BIND), and a certificate authority into a single managed service.

All homelab VMs are enrolled as IPA clients and authenticate via SSSD.
Access control is enforced through HBAC rules rather than local user accounts.

Rocky Linux 9.7 was chosen for RHEL compatibility and alignment with RHCSA/RHCE certification objectives.

## Installation

### Prerequisites

```bash
sudo hostnamectl set-hostname prod-ipa-0.home.arpa
sudo vim /etc/hosts  # add hostname entry
sudo dnf update -y
```

### Server Installation

FreeIPA server and DNS were installed and configured in stages:

```bash
# Install server package
sudo dnf install freeipa-server -y

# First attempt without DNS
sudo ipa-server-install

# Install DNS package and reinstall with DNS support
sudo dnf install ipa-server-dns -y
sudo ipa-server-install --setup-dns

# DNS install run separately to finalize DNS configuration
sudo ipa-dns-install
```

### NTP Configuration

Accurate time is critical for Kerberos — tickets will fail if clocks are skewed more than 5 minutes between client and server.
Chrony was configured manually:

```bash
sudo vim /etc/chrony.conf
sudo systemctl enable --now chronyd
```

Verify sync:

```bash
chronyc sources -v
chronyc tracking
```

### Firewall Configuration

Firewall rules were added incrementally as services were configured:

```bash
# Web interface
sudo firewall-cmd --add-service=http --permanent
sudo firewall-cmd --add-service=https --permanent

# Identity services
sudo firewall-cmd --add-service=ldap --permanent
sudo firewall-cmd --add-service=kerberos --permanent
sudo firewall-cmd --add-service=kerberos-kpasswd --permanent
sudo firewall-cmd --add-service=ntp --permanent

# DNS
sudo firewall-cmd --add-service=dns --permanent

# Kerberos password change protocol
sudo firewall-cmd --add-port=464/tcp --permanent
sudo firewall-cmd --add-port=464/udp --permanent

sudo firewall-cmd --reload
```

### Client Enrollment

RHEL/Rocky:

```bash
sudo dnf install freeipa-client -y
sudo ipa-client-install --domain=home.arpa --server=prod-ipa-0.home.arpa \
  --realm=HOME.ARPA --mkhomedir --hostname=<hostname>.home.arpa
```

Debian/Ubuntu:

```bash
sudo apt install freeipa-client -y
sudo ipa-client-install --domain=home.arpa --server=prod-ipa-0.home.arpa \
  --realm=HOME.ARPA --mkhomedir --hostname=<hostname>.home.arpa
```

## Realm Configuration

| Setting           | Value                  |
| ----------------- | ---------------------- |
| Realm             | `HOME.ARPA`            |
| Domain            | `home.arpa`            |
| IPA Master        | `prod-ipa-0.home.arpa` |
| CA Server         | `prod-ipa-0.home.arpa` |
| CA Renewal Master | `prod-ipa-0.home.arpa` |
| Default Shell     | `/bin/bash`            |
| Default Auth      | password               |

## DNS

FreeIPA's integrated BIND serves as the primary DNS authority for the `home.arpa` domain.
Enrolled clients use `prod-ipa-0` (`10.33.111.100`) as their primary DNS server.
Pi-hole (`10.33.111.141`) serves as fallback for non-enrolled devices and upstream resolution.

### Forward Zone

| Setting          | Value                            |
| ---------------- | -------------------------------- |
| Zone             | `home.arpa.`                     |
| Authoritative NS | `prod-ipa-0.home.arpa.`          |
| Dynamic Update   | Enabled (Kerberos authenticated) |
| Allow Query      | any                              |
| Allow Transfer   | none                             |

### Reverse Zone

| Setting          | Value                        |
| ---------------- | ---------------------------- |
| Zone             | `111.33.10.in-addr.arpa.`    |
| Authoritative NS | `prod-ipa-0.home.arpa.`      |
| Dynamic Update   | Enabled (Kerberos subdomain) |
| Allow Query      | any                          |
| Allow Transfer   | none                         |

### Adding DNS Records

DNS records are added manually when new hosts are enrolled:

```bash
ipa dnsrecord-add home.arpa <hostname> --a-rec <ip>
ipa dnsrecord-add 111.33.10.in-addr.arpa <last-octet> --ptr-rec <hostname>.home.arpa.
```

## Identity Management

Authentication is handled via Kerberos.
SSSD manages client-side identity resolution and caching on enrolled hosts.

### Users

| Username | Role              |
| -------- | ----------------- |
| admin    | IPA administrator |
| arpatek  | Primary user      |
| jgarcia  | Primary user      |

### Groups

| Group        | GID        | Description                 |
| ------------ | ---------- | --------------------------- |
| admins       | 1479800000 | Account administrators      |
| devs         | 1479800003 | Development group           |
| editors      | 1479800002 | Limited admins              |
| ipausers     | —          | Default group for all users |
| trust admins | —          | Trusts administrators       |

### Host Groups

| Host Group  | Description                 |
| ----------- | --------------------------- |
| controllers | Host controllers            |
| dev-vms     | Dev Virtual Machines        |
| prod-vms    | Production Virtual Machines |
| ipaservers  | IPA server hosts            |

### Enrolled Hosts

| Host                        | Role          |
| --------------------------- | ------------- |
| prod-ipa-0.home.arpa        | IPA server    |
| prod-git-0.home.arpa        | Gitea CI/CD   |
| prod-mon-0.home.arpa        | Monitoring    |
| prod-k3s-master-0.home.arpa | k3s master    |
| prod-k3s-worker-0.home.arpa | k3s worker    |
| prod-k3s-worker-1.home.arpa | k3s worker    |
| dev-rhel-0.home.arpa        | RHEL dev VM   |
| dev-ubuntu-0.home.arpa      | Ubuntu dev VM |
| ctrl-node.home.arpa         | Control node  |

## Access Control

Access control is enforced via HBAC (Host-Based Access Control) rules evaluated by SSSD on each enrolled host.
HBAC rules govern PAM service access independently of sudo rules — both must be configured to grant full privileged access to a host.

### HBAC Rules

| Rule               | User Groups | Host Groups                                | Services     | Enabled  |
| ------------------ | ----------- | ------------------------------------------ | ------------ | -------- |
| allow_all          | all         | all                                        | all          | Disabled |
| allow_ssh_devops   | devs        | controllers, dev-vms, ipaservers, prod-vms | sshd, sudo   | Enabled  |
| allow_systemd-user | all         | all                                        | systemd-user | Enabled  |

> `allow_all` is intentionally disabled. Access is granted explicitly via
> `allow_ssh_devops` to control which users can reach which hosts.

### Sudo Rules

| Rule     | Users        | Commands | Enabled  |
| -------- | ------------ | -------- | -------- |
| admins   | admins group | all      | Disabled |
| dev_sudo | devs group   | all      | Enabled  |

### Configuring HBAC and Sudo

```bash
# Create HBAC rule
ipa hbacrule-add allow_ssh_devops
ipa hbacrule-add-user allow_ssh_devops --groups=devs
ipa hbacrule-add-host allow_ssh_devops --hostgroups=controllers,dev-vms,ipaservers,prod-vms
ipa hbacrule-add-service allow_ssh_devops --hbacsvcs=sshd
ipa hbacrule-add-service allow_ssh_devops --hbacsvcs=sudo
ipa hbacrule-enable allow_ssh_devops

# Create sudo rule
ipa sudorule-add dev_sudo
ipa sudorule-add-user dev_sudo --users=arpatek
ipa sudorule-add-user dev_sudo --users=jgarcia
ipa sudorule-add-allow-command dev_sudo --sudocmds=all
ipa sudorule-enable dev_sudo
```

## Gotchas

- **HBAC and sudo are independent** — HBAC governs PAM service access (e.g. sshd), sudo rules govern privilege escalation.
  Both must allow access for a user to SSH in AND run sudo. Configuring sudo alone is not enough.
- **Kerberos ticket expiry** — tickets expire and must be renewed with `kinit admin`.
  Running `ipa` commands without a valid ticket returns `Ticket expired`.
- **SSSD KnownHostsCommand** — FreeIPA configures SSSD to serve SSH host keys via `sss_ssh_knownhosts`.
  This conflicts with services running SSH on non-standard ports (e.g. Gitea on port 2222) where the stored host key doesn't match.
  Workaround: set `KnownHostsCommand none` in `~/.ssh/config` for the affected host.
- **`sudocmds=all` is lowercase** — passing `ALL` uppercase to `ipa sudorule-add-allow-command` will fail.
  Use `all` lowercase.
- **DNS must be configured before clients enroll** — SRV records for `_kerberos` and `_ldap` must resolve correctly or client enrollment will fail.
  Verify with: `dig _kerberos._tcp.home.arpa SRV`

## Notes

- Single IPA master — no replica configured yet
- `allow_all` HBAC rule disabled in favor of explicit access rules
- Rocky Linux 9.7 chosen for RHEL compatibility and RHCSA/RHCE certification alignment
