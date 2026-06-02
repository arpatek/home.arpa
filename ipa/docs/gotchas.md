# Gotchas

Issues encountered during the FreeIPA build.

## DNS must be integrated at install time

**Symptom.**
`ipa-server-install` completes successfully, but `ipa-client-install` on other hosts fails during the discovery phase with an error like:
`DNS discovery failed to determine your DNS domain`.
Manually specifying `--server` and `--domain` gets further but enrollment still fails when the client tries to look up SRV records.

**Cause.**
FreeIPA's `ipa-client-install` relies on DNS SRV records (`_kerberos._tcp.home.arpa`, `_ldap._tcp.home.arpa`) to locate services on the IPA server.
If the server was installed without DNS integration (`ipa-server-install` without `--setup-dns`), those SRV records don't exist.
DNS on the client host was also still pointed at Pi-hole, which has no knowledge of these records.

**Fix.**
Install the DNS server package and re-run the server installer with DNS support:

```bash
sudo dnf install ipa-server-dns -y
sudo ipa-server-install --setup-dns
sudo ipa-dns-install
```

Before enrolling any client, point the client host's DNS resolver at `mikoshi` (`10.33.111.100`) so it can resolve SRV records.
Verify the records exist before attempting enrollment:

```bash
dig _kerberos._tcp.home.arpa SRV
dig _ldap._tcp.home.arpa SRV
```

**Broken assumption.**
I assumed DNS integration could be bolted on after the initial server install.
It can, but it requires going through the installer again.
The right order is: DNS on the server first, client resolver pointed at IPA DNS second, client enrollment third.

## HBAC and sudo rules are evaluated independently

**Symptom.**
A user can SSH into a host but `sudo` immediately fails with `Sorry, user X is not allowed to execute` or a PAM denial, even though a sudo rule is configured.
Alternatively, a user has a sudo rule but cannot SSH in at all.

**Cause.**
FreeIPA enforces two separate access control layers.
HBAC governs PAM service access — whether a user is allowed to use a given PAM service (sshd, sudo) on a given host.
Sudo rules govern which commands a user may run once they've reached a sudo prompt.
Both layers must permit access for privileged access to work end-to-end.

Configuring a sudo rule (`dev_sudo`) grants command permissions but does not permit the user to invoke sudo in the first place.
That permission lives in the HBAC rule, specifically requiring `sudo` as a permitted service alongside `sshd`.

**Fix.**
Ensure the HBAC rule includes both `sshd` and `sudo` as permitted services:

```bash
ipa hbacrule-add-service allow_ssh_devops --hbacsvcs=sshd
ipa hbacrule-add-service allow_ssh_devops --hbacsvcs=sudo
```

Then ensure the sudo rule is also in place:

```bash
ipa sudorule-add dev_sudo
ipa sudorule-add-allow-command dev_sudo --sudocmds=all
ipa sudorule-enable dev_sudo
```

**Broken assumption.**
I assumed a sudo rule alone was sufficient for sudo access.
In FreeIPA, `sudo` is a PAM service that SSSD checks against HBAC before the sudo rule is even consulted.
Both gates must be open.

## `sudocmds=all` is case-sensitive

**Symptom.**
`ipa sudorule-add-allow-command` fails with an error about the command not being found:
`ipa: ERROR: ALL: command not found`.

**Cause.**
FreeIPA's pseudo-command that grants access to all commands is the lowercase string `all`.
The conventional sudo syntax uses uppercase `ALL`, but the `ipa` CLI does not accept it.

**Fix.**
Use lowercase:

```bash
ipa sudorule-add-allow-command dev_sudo --sudocmds=all
```

**Broken assumption.**
I assumed `ALL` (uppercase) would work by analogy with `/etc/sudoers` syntax.
The `ipa` CLI has its own convention and it differs from the sudoers file format.

## Kerberos tickets expire silently

**Symptom.**
`ipa` CLI commands that worked earlier in a session now fail with:
`ipa: ERROR: Ticket expired`.
Or Kerberos-authenticated operations (LDAP queries via `ldapsearch`, `ipa` API calls) return authentication errors without a clear explanation.

**Cause.**
Kerberos tickets have a finite lifetime — 24 hours in this deployment.
After the ticket expires, the `ipa` CLI has no valid credential to authenticate to the XML-RPC API.
The error message is not always immediately obvious as a credential issue.

**Fix.**
Acquire a fresh ticket:

```bash
kinit admin
```

Or for the primary user:

```bash
kinit arpatek
```

Then retry the failing command.

**Broken assumption.**
I assumed that being logged in to `mikoshi` would keep credentials alive.
Kerberos doesn't work that way — the ticket lifetime is fixed at issuance and isn't renewed by activity.
If a long admin session is needed, run `kinit -r 7d admin` to get a renewable ticket and use `kinit -R` to renew it before it expires.

## Renaming the IPA server is not officially supported

**Symptom.**
After renaming the Proxmox VM hostname, setting a new OS hostname, and attempting `ipa-restore` from a backup taken on the old hostname, the restore fails with a cascade of errors:

1. `Host name mikoshi.home.arpa does not match backup name prod-ipa-0.home.arpa` — the restore refuses to start.
2. After patching the backup header: `cannot connect to 'ldaps://prod-ipa-0.home.arpa:636'` — the restore reads the old hostname from `/etc/ipa/default.conf` inside the backup tarball's nested `files.tar`.
3. After patching `files.tar`: `Restoring /etc/ipa/default.conf failed: tar: etc/ipa/default.conf: Not found in archive` — path prefix mismatch (`./etc/ipa/` vs `etc/ipa/`) between how we repacked the tar and how `ipa-restore` extracts it.
4. After fixing the path: `import userRoot: Duplicated DN detected: "idnsname=mikoshi,idnsname=home.arpa.,cn=dns,dc=home,dc=arpa"` — our sed rename of `prod-ipa-0` → `mikoshi` in the LDIF created two entries with the same DN: the backup's A record (renamed) and the fresh install's self-registration.
5. After removing the duplicate: `ldif2db successful with skipped entries` but database is empty — `ldif2db` silently aborts the entire import when the top-level `dc=home,dc=arpa` entry is skipped, cascading to every child entry being skipped too.
6. After the data-only restore succeeds (556 entries): `Configured hostname 'mikoshi.home.arpa' does not match any master server in LDAP` — the master entry is still registered as `prod-ipa-0` in the restored LDAP.
7. With the restored LDAP: all service keytabs (`HTTP/`, `ldap/`, `ipa-custodia/`) contain the old hostname and cannot authenticate. Each one must be regenerated, but regenerating them requires authenticating via the broken keytabs — a circular dependency.
8. `ipa-getkeytab` via `kinit admin` fails with `SASL Bind failed: Invalid credentials` because the LDAP server's own keytab (`ldap/prod-ipa-0.home.arpa`) does not match the new hostname.

**Cause.**
Red Hat explicitly states in their documentation that **renaming an IPA server is not a supported operation**. The officially supported path is to deploy a new replica with the desired hostname, transfer all roles to it, and decommission the old server. On a single-server homelab, that option is not practical.

The `ipa-restore` tool performs hostname validation at multiple layers (backup header, `files.tar`, LDIF data, LDAP DN structure) and does not provide any mechanism to override the hostname during restore. Even manually patching all references in the backup fails because the service keytabs are binary files that cannot be updated with `sed`.

**What actually works.**
A fresh install of IPA with the new hostname, followed by manual recreation of all data via the `ipa` CLI:

```bash
# 1. Uninstall the old IPA server
sudo ipa-server-install --uninstall -U

# 2. Remove leftover PKI state from failed reinstall attempts
sudo rm -rf /var/lib/pki/pki-tomcat /etc/pki/pki-tomcat /var/log/pki/pki-tomcat

# 3. Stop any residual dirsrv instance
sudo dsctl HOME-ARPA remove --do-it 2>/dev/null || true

# 4. Fresh install with new hostname
sudo ipa-server-install \
  --realm=HOME.ARPA \
  --domain=home.arpa \
  --hostname=mikoshi.home.arpa \
  --setup-dns \
  --forwarder=10.33.111.141 \
  --no-ntp

# 5. Recreate users, groups, HBAC rules, sudo rules, host groups, DNS records
kinit admin
bash /path/to/ipa-setup.sh

# 6. Re-enroll every client (old keytabs are invalid against the new CA)
# On each enrolled host:
echo "10.33.111.100 mikoshi.home.arpa mikoshi" | sudo tee -a /etc/hosts
sudo ipa-client-install --uninstall -U
sudo ipa-client-install \
  --domain=home.arpa \
  --server=mikoshi.home.arpa \
  --realm=HOME.ARPA \
  --hostname=<hostname>.home.arpa \
  --mkhomedir \
  --no-ntp \
  --principal=admin
```

**Why ALL clients need re-enrollment.**
The fresh IPA install generates a new CA with new root certificate and new service keys. Every keytab issued under the old CA is cryptographically invalid against the new CA. There is no workaround — every enrolled host must `ipa-client-install --uninstall` and re-enroll to get new keytabs signed by the new CA.

**Additional gotchas encountered during re-enrollment.**

*DNS resolution after unenrollment.*
After `ipa-client-install --uninstall`, some hosts lose DNS resolution for `mikoshi.home.arpa` because their resolver was configured by IPA and reverts to a state that cannot reach the IPA BIND server. Fix: add the IPA server to `/etc/hosts` before re-enrolling:
```bash
echo "10.33.111.100 mikoshi.home.arpa mikoshi" | sudo tee -a /etc/hosts
```

*HBAC rule: host groups and services must be added separately.*
`ipa hbacrule-add-host --hostgroups=a,b,c` looks like it accepts a comma-separated list but may fail silently if one group doesn't exist. Always add each group and service in its own `ipa hbacrule-add-host` call and verify with `ipa hbacrule-show --all`. If `Host Groups` and `HBAC Services` are absent from the output, SSH will be denied to all users via `pam_sss(sshd:account): Access denied`. The symptom at the SSH client is: key is accepted, then `Connection closed` immediately after — no auth error, just a silent close.

*SSSD passkey module crashes on Debian with "Cannot allocate memory".*
IPA 4.11+ enables passkey authentication by default. On Debian-based enrolled clients, the passkey PAM module fails with `pam_passkey_get_user_done: Unexpected passkey error [12]: Cannot allocate memory`. This causes `pam_sss` to return `PAM_PERM_DENIED` even after a successful key authentication. The symptom is the same silent `Connection closed` after key acceptance.

Fix: add to the `[domain/home.arpa]` section of `/etc/sssd/sssd.conf` on every affected Debian client:
```ini
[domain/home.arpa]
local_auth_policy = disable:passkey
```

Note: this line must be inside `[domain/home.arpa]`, not appended to the end of the file (which would place it under a different section). Use sed to insert it correctly:
```bash
sudo sed -i '/^\[domain\/home.arpa\]/a local_auth_policy = disable:passkey' /etc/sssd/sssd.conf
sudo systemctl restart sssd
```

*Local user shadowing IPA user (UID mismatch).*
On k3s worker nodes, a local `arpatek` user with UID 1000 was present in `/etc/passwd`. Because `nsswitch.conf` lists `files` before `sss`, this local user takes precedence over the IPA user (UID 1479800005). The symptom is `id arpatek` returning UID 1000 instead of 1479800005. SSH still works because `sss_ssh_authorizedkeys` serves IPA keys, but the session runs as the local UID, breaking any UID-dependent permissions.

Fix: remove the local user entry directly from the system files (standard `userdel` fails when the user has an active session):
```bash
sudo sed -i '/^arpatek:/d' /etc/passwd /etc/shadow /etc/group
```

*`sudo userdel` fails with active session.*
If an SSH session exists for the user being deleted, `userdel` returns an error. Editing `/etc/passwd` directly (as above) is the workaround.

**Broken assumption.**
I assumed `ipa-restore` was designed to handle hostname changes if the backup files were patched. It is not. The tool validates the hostname at every layer and the service keytab problem is fundamentally unsolvable through patching alone because keytabs are binary. The only correct approach for renaming a single IPA server is a fresh install.

---

## User UID outside IPA ID range causes kinit to fail with Generic error

**Symptom.**
`kinit arpatek` returns `Generic error (see e-text) while getting initial credentials` after successful password entry.
SPAKE pre-authentication succeeds (password is correct), but the KDC returns the error during the `handle_authdata` phase.
The KDC log on `mikoshi` shows:

```
AS_REQ : handle_authdata (2)
AS_REQ ... HANDLE_AUTHDATA: arpatek@HOME.ARPA for krbtgt/HOME.ARPA@HOME.ARPA, No such file or directory
```

SSH key authentication still works. Only `kinit` (and anything that needs a Kerberos ticket) fails.
Attempts to fix by clearing `krbExtraData`, setting `krbPasswordExpiration`, restarting `krb5kdc`, or deleting and recreating the user with the same UID all reproduce the same error.

**Cause.**
FreeIPA's KDC backend (`ipa-kdb`) generates a PAC (Privilege Attribute Certificate) during the `handle_authdata` phase of every AS request.
PAC generation requires a SID for the user.
SIDs are derived from the user's UID relative to the configured ID range.
If the UID falls outside all configured ID ranges, no SID can be generated and `ipa-kdb` returns `No such file or directory`, which the KDC surfaces as `KDC_ERR_GENERIC`.

This happens when a user is recreated with a UID from a previous IPA installation whose ID range no longer exists.
When `ipa user-add` is run with an explicit `--uid` that is outside the current range, IPA warns:

```
WARNING: User 'arpatek', with UID Number '1479800005' is out of all ID Ranges, 'SID' will not be correctly generated.
```

This warning is the exact indicator of the problem. Do not ignore it.

**Fix.**
Delete the user and recreate without specifying `--uid`.
IPA will auto-assign a UID within the current ID range, SID generation will succeed, and `kinit` will work.

```bash
ipa user-del arpatek
ipa user-add arpatek --first=Juan --last=Garcia --homedir=/home/arpatek --shell=/bin/bash
```

After recreation, fix ownership of the user's home directory on all enrolled hosts using the new numeric UID (check with `ipa user-show arpatek | grep UID`):

```bash
sudo chown -R <new-uid>:<new-uid> /home/arpatek
sudo rm -rf /var/lib/sss/db/*.ldb /var/lib/sss/mc/*
sudo systemctl restart sssd
```

**Check ID ranges before recreating with an explicit UID.**

```bash
ipa idrange-find
```

The primary local range is shown as `First Posix ID` + `Number of IDs`.
Any `--uid` passed to `ipa user-add` must fall within this range.

**Broken assumption.**
I assumed `kinit` failure was always a password or must-change issue.
The real cause was a UID outside the ID range — a consequence of the IPA reinstall creating a new ID range while the user was recreated with an old UID.
The `Generic error (see e-text)` from kinit gives no hint of this; the KDC log is required to diagnose it.

---

## SSSD serves host keys by hostname, not by port

**Symptom.**
SSH connections to a host that runs SSH on a non-standard port (e.g. Gitea's SSH on port 2222 of `soulkiller`) fail with a host key verification error, even after the correct key has been accepted previously.

**Cause.**
FreeIPA configures the SSH client on enrolled hosts to use `sss_ssh_knownhosts` via `KnownHostsCommand` in `/etc/ssh/ssh_config`.
SSSD serves the host key it retrieved from LDAP for the given hostname.
That key is the one associated with the host's main SSH daemon (port 22).
When SSH connects to port 2222, it receives a different key (from Gitea's containerized SSH), but SSSD presents the port-22 key for comparison.
The mismatch causes the verification failure.

**Fix.**
Add a `Host` entry to `~/.ssh/config` on the client that disables `KnownHostsCommand` for that specific host:

```
Host soulkiller.home.arpa
    KnownHostsCommand none
    Port 2222
```

SSH then falls back to `~/.ssh/known_hosts` for that host, which works once the Gitea key has been accepted on first connect.

**Broken assumption.**
I assumed SSSD's host key serving was port-aware.
It is not — SSSD associates one key per host entry in LDAP, regardless of how many SSH-speaking services run on that host.

> This gotcha is also documented in [gitea/docs/gotchas.md](../../gitea/docs/gotchas.md), where the root cause is described from the Gitea side.
