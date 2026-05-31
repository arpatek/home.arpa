# Gotchas

Issues encountered during the Gitea build.

## Bind mount permission failure due to UID/GID mismatch

**Symptom.**
Gitea starts but fails to write to its data directories.
Errors in the logs reference permission denied on paths under `/opt/gitea/data/` or `/opt/gitea/config/`.

**Cause.**
Gitea's container runs as a `git` user.
The UID and GID of that user inside the container defaulted to values that did not match
the ownership of the bind-mounted directories on the host.
Docker bind mounts are not UID-mapped — the container sees the host filesystem's raw ownership,
so a mismatch causes permission errors immediately.

**Fix.**
Set `USER_UID` and `USER_GID` in `docker-compose.yml` to match the UID and GID
of the user that owns `/opt/gitea/` on the host:

```bash
id git   # check the host user's UID and GID
```

Then set the values in the Compose file:

```yaml
environment:
  - USER_UID=999
  - USER_GID=988
```

**Broken assumption.**
I assumed the container's default git user would have the same UID as the host's git user.
Container base images assign UIDs independently of the host.
Any service that runs as a non-root user inside a container and uses bind mounts
needs its in-container UID explicitly aligned with the host.

## SSH host key mismatch via SSSD

**Symptom.**
Cloning from Gitea over SSH fails with a host key verification error,
even with the correct hostname and port.

**Cause.**
FreeIPA configures SSSD to serve SSH host keys via `sss_ssh_knownhosts`.
The key it serves is for the host's own SSH daemon on port 22.
Gitea's SSH runs on port 2222, and the key presented there does not match
what SSSD has on record for `soulkiller.home.arpa`.

**Fix.**
Add a `Host` entry to `~/.ssh/config` on the client that disables `KnownHostsCommand`
for `soulkiller.home.arpa`:

```
Host soulkiller.home.arpa
    KnownHostsCommand none
    Port 2222
```

SSH falls back to `~/.ssh/known_hosts` for host key verification,
which works correctly once the Gitea host key is accepted on first connect.

**Broken assumption.**
I assumed SSSD's SSH host key integration was port-aware.
It is not — it serves the key for the host, not for a specific service on that host.
Any service running SSH on a non-standard port on an IPA-enrolled host will hit this.

> This gotcha is also documented in [ipa/README.md](../../ipa/README.md) under Gotchas,
> since the root cause lives in the IPA/SSSD layer.
