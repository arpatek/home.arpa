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

Before enrolling any client, point the client host's DNS resolver at `prod-ipa-0` (`10.33.111.100`) so it can resolve SRV records.
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
I assumed that being logged in to `prod-ipa-0` would keep credentials alive.
Kerberos doesn't work that way — the ticket lifetime is fixed at issuance and isn't renewed by activity.
If a long admin session is needed, run `kinit -r 7d admin` to get a renewable ticket and use `kinit -R` to renew it before it expires.

## SSSD serves host keys by hostname, not by port

**Symptom.**
SSH connections to a host that runs SSH on a non-standard port (e.g. Gitea's SSH on port 2222 of `prod-git-0`) fail with a host key verification error, even after the correct key has been accepted previously.

**Cause.**
FreeIPA configures the SSH client on enrolled hosts to use `sss_ssh_knownhosts` via `KnownHostsCommand` in `/etc/ssh/ssh_config`.
SSSD serves the host key it retrieved from LDAP for the given hostname.
That key is the one associated with the host's main SSH daemon (port 22).
When SSH connects to port 2222, it receives a different key (from Gitea's containerized SSH), but SSSD presents the port-22 key for comparison.
The mismatch causes the verification failure.

**Fix.**
Add a `Host` entry to `~/.ssh/config` on the client that disables `KnownHostsCommand` for that specific host:

```
Host prod-git-0.home.arpa
    KnownHostsCommand none
    Port 2222
```

SSH then falls back to `~/.ssh/known_hosts` for that host, which works once the Gitea key has been accepted on first connect.

**Broken assumption.**
I assumed SSSD's host key serving was port-aware.
It is not — SSSD associates one key per host entry in LDAP, regardless of how many SSH-speaking services run on that host.

> This gotcha is also documented in [gitea/docs/gotchas.md](../../gitea/docs/gotchas.md), where the root cause is described from the Gitea side.
