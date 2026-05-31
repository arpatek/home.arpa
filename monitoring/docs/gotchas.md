# Gotchas

Real problems hit during the build of this monitoring stack.
Each entry follows the same shape: what the symptom looked like, what was actually happening underneath, the fix that worked, and what assumption it broke.

The "why it surprised me" part is the most important part.
A list of fixes is a procedure manual.
A list of broken assumptions is a learning aid.

Major issues are documented in full.
Smaller surprises are listed as bullets at the end.

## cAdvisor breaks on Debian 13's default Docker storage

**Symptom.**
After deploying cAdvisor in the monitoring stack, container metrics had no `name` label.
Querying `container_memory_usage_bytes{name!=""}` in Grafana returned nothing.
The cAdvisor logs were a flood of:

```
failed to identify the read-write layer ID for container "..."
- open /var/lib/docker/image/overlayfs/layerdb/mounts/.../mount-id: no such file or directory
```

The `cadvisor_version_info` metric showed `dockerVersion=""` — empty string.

**Cause.**
Three things compounded.

First, Debian 13 ships Docker 29, which uses the **containerd image store** by default on fresh installs.
This isn't the traditional `overlay2` graph driver that most ecosystem tools assume.
The on-disk layout is different: `/var/lib/docker/image/overlay2/layerdb/` doesn't exist on this setup.

Second, the cAdvisor version I started with (v0.52.1) only knew how to read the legacy layout.
Support for the containerd snapshotter shipped in cAdvisor v0.54.0, but I had pinned an older version without checking the changelog.
The result was that cAdvisor couldn't find Docker's container metadata, fell back to reading raw cgroups, and lost all container identity in the process.

Third — and this was the part that took longest to find — even after upgrading to 0.56.2, cAdvisor still failed.
The fix in v0.54.0 made cAdvisor query containerd directly via its socket instead of reading on-disk files.
But that requires the **containerd** socket (`/run/containerd/containerd.sock`), not just the Docker socket.
Without that mount, cAdvisor's logs showed:

```
Registration of the docker container factory failed: ... dial unix /run/containerd/containerd.sock: connect: no such file or directory
```

Both factory registrations failed, cAdvisor fell back to the Raw factory (kernel cgroups only, no container names), and I was back where I started despite running the patched version.

There were also two cosmetic changes in the same release window worth knowing about: the image registry moved from `gcr.io/cadvisor/cadvisor` to `ghcr.io/google/cadvisor`, and the tag format dropped the `v` prefix.
Git release tag `v0.56.2` is the Docker image tag `0.56.2`.
Easy to miss, easy to mistake for a typo.

**Fix.**
Three changes to the cAdvisor service in the compose file:

1. New image: `ghcr.io/google/cadvisor:0.56.2` (note: `ghcr.io`, not `gcr.io`; no `v` on the tag).
2. Add the containerd socket as a volume: `/run/containerd/containerd.sock:/run/containerd/containerd.sock:ro`.
3. Add `--docker_only=true` to the command so cAdvisor only emits metrics for Docker-managed containers, not every cgroup on the system.

After all three are in place, `cadvisor_version_info` shows a populated `dockerVersion`, and metrics get the `name`, `image`, and Compose service labels.

**Why it surprised me.**
The assumption was that "install cAdvisor" is a solved problem — it's been the standard Docker container metrics tool for a decade.
What I didn't realize is that cAdvisor was written assuming Docker's traditional storage architecture, and that Docker has been quietly migrating to a containerd-based architecture that fresh installs (Docker 29+) get by default.
The ecosystem hasn't caught up uniformly.

The deeper lesson: when a tool fails on a new platform default, the first question is "has the tool caught up?" — not "should I downgrade the platform?"
The version of cAdvisor that supports containerd snapshotter exists. Verifying current stable releases before pinning would have caught this in the first place. Pinning a version from memory without checking the changelog is the actual root cause.

## Loki rejects logs older than its retention threshold, even on first run

**Symptom.**
Right after deploying Alloy on soulkiller and pointing it at the central Loki, log ingestion seemed broken.
The Alloy logs were full of rejection errors from Loki:

```
entry too far behind, oldest acceptable timestamp is: 2026-04-XX
```

Logs were being sent, but Loki was refusing them.
For about five minutes, almost nothing landed in Grafana's log explorer.

**Cause.**
Loki has a `reject_old_samples` config option, set to true by default with a 7-day cutoff.
Anything older than that, Loki refuses.
This is intentional — out-of-order writes wreck performance, and there's rarely a legitimate reason to ingest logs from weeks ago.

The trigger was Docker's log file behavior on the Gitea host.
Gitea had been running for thirteen days when I deployed the agent.
Docker keeps container stdout in JSON-formatted log files under `/var/lib/docker/containers/<id>/<id>-json.log`, and those files persist for the lifetime of the container.
When Alloy started up and discovered the running Gitea container, it didn't ship "logs from now forward" — it shipped the entire historical log file.
Most of those entries had timestamps Loki rejected.

The system worked correctly through it.
Alloy worked through the backlog over a few minutes, hitting the 7-day cutoff repeatedly, and once it caught up to recent entries, fresh logs flowed normally.
But during those five minutes the rejection errors looked like a real failure.

**Fix.**
No fix needed.
Wait through the backlog and verify that fresh logs are flowing once Alloy catches up.

If a real fix were needed (say, deploying agents against containers that have been running for months), the options would be:

1. Bump Loki's `reject_old_samples_max_age` to cover the existing log range.
2. Configure Alloy to start tailing from the end of existing logs rather than reading from the start.

Option 2 is the better approach long-term but requires understanding Alloy's positions file.
For a homelab where backlogs are short, waiting it out is fine.

**Why it surprised me.**
I expected log shipping to be a "from now forward" operation.
The mental model was: agent starts, agent watches files, new lines get shipped.
What I missed is that Docker treats container stdout as a persistent file, and Alloy's default behavior is to read files from the beginning unless told otherwise.
Combine those two behaviors and "deploy the agent" becomes "ship every log line since the container started" by default.

The deeper lesson: log shippers and metrics scrapers have very different default behaviors around historical data.
Prometheus scrapes points-in-time and has no concept of backfill.
Loki receivers (Alloy, Promtail, Vector) replay historical files by default.
The mental model from one doesn't transfer cleanly to the other.

## SELinux preserves source context across `mv` on RHEL

**Symptom.**
On mikoshi (Rocky 9.7), I downloaded the node_exporter binary to `/tmp` and moved it to `/usr/local/bin/`.
The systemd service refused to start, exiting with status `203/EXEC`:

```
node_exporter.service: Failed to locate executable /usr/local/bin/node_exporter: Permission denied
node_exporter.service: Failed at step EXEC spawning /usr/local/bin/node_exporter: Permission denied
```

The file existed.
Permissions were correct (`rwxr-xr-x`, owned by `node_exporter`).
Running it manually as the user worked.
Only systemd couldn't exec it.

**Cause.**
SELinux file contexts.

When the binary was downloaded into `/tmp`, it inherited the `user_tmp_t` SELinux context — the type for files in user temp directories.
The `mv` command moves files by changing inode pointers, not by re-creating the file.
That means the `user_tmp_t` context came along with the move.

systemd runs services in the `init_t` domain, which has a strict policy about which file contexts it's allowed to exec.
`user_tmp_t` is not on that list.
The binary was readable, executable, and correctly owned, but SELinux blocked the exec at the kernel level.

The denial doesn't show up in regular logs.
It shows up in `/var/log/audit/audit.log` as `AVC` denials, which is a different log most people don't look at first.

**Fix.**
Two options.

The reactive fix, after the move has already happened:

```bash
sudo restorecon -v /usr/local/bin/node_exporter
```

`restorecon` resets the SELinux context to whatever the policy expects for that path.
For files in `/usr/local/bin/`, that's `bin_t`, which `init_t` is allowed to exec.

The proactive fix, which avoids the issue entirely, is to use `install` instead of `mv`:

```bash
sudo install -m 0755 -o node_exporter -g node_exporter \
  /tmp/node_exporter-1.11.1.linux-amd64/node_exporter \
  /usr/local/bin/node_exporter
```

`install` creates the destination file fresh (rather than moving an inode), so it gets the correct context for its destination path automatically.
It also handles ownership and mode in one command, replacing what would otherwise be three steps.

The proactive fix is the right habit because it doesn't require remembering SELinux exists.

**Why it surprised me.**
On Debian, this entire failure mode doesn't exist.
`mv` from `/tmp` to `/usr/local/bin` and the binary just runs.
There's no enforcement layer that cares where a file came from.

RHEL's SELinux is doing real security work — preventing a process that gets exploited from dropping a binary in a temp directory and executing it later — but the enforcement is invisible until it bites.
And the failure mode looks exactly like a permissions problem, which sends you down the wrong debugging path.
Five minutes of `chmod` and `chown` later, the binary still won't exec, and only then does it occur to check `audit.log`.

The deeper lesson: when something on RHEL fails in a way that "should work" by Linux fundamentals, check SELinux before doubting the fundamentals.
Standard `ls -l` shows nothing about contexts.
You need `ls -lZ` to see them, and most tutorials don't mention it.

## Alloy needs explicit `SupplementaryGroups=systemd-journal` in its systemd unit

**Symptom.**
On mikoshi, Alloy was installed and configured to read from journald.
The service ran without errors.
But Loki had no logs from mikoshi.
Alloy's own logs showed permission errors when trying to read journal files:

```
permission denied: /var/log/journal/...
```

**Cause.**
Reading the systemd journal requires membership in the `systemd-journal` group (or root, but we don't want that).
The standard fix is `usermod -aG systemd-journal alloy`, which I ran.
Verification with `id alloy` showed the group was present.

But Alloy still couldn't read the journal.

The issue is that the Alloy systemd unit has hardening directives like `ProtectSystem=strict`, `PrivateTmp=true`, and others.
Some of these — depending on systemd version and exact combination — can drop supplementary groups when the service starts.
The user is in the group at the OS level, but the running process doesn't actually have that group's privileges.

**Fix.**
Add an explicit `SupplementaryGroups=` directive to the Alloy systemd unit:

```ini
[Service]
User=alloy
Group=alloy
SupplementaryGroups=systemd-journal
```

This tells systemd "regardless of what the hardening directives do, ensure this process runs with these supplementary groups."

The belt-and-suspenders approach — keeping the `usermod -aG` from before and adding the unit directive — is the safe pattern.
The unit directive is what actually matters at runtime, but the OS-level group membership doesn't hurt and matches what an admin reading `/etc/group` would expect.

**Why it surprised me.**
The mental model from "normal" Linux is that group membership is a property of the user.
Add user to group, user has the group's privileges everywhere.
That's not quite true under systemd with hardening enabled.
Hardening directives can reshape the runtime environment of a service in ways that aren't visible from `id` or `groups`.

The deeper lesson: when a service can't access something the user "should" have access to, check the unit file's hardening section before assuming the group membership is broken.
The kernel-level access check happens in the runtime context of the service, not the OS context of the user.

## Grafana provisioning changes can be hidden by browser cache

**Symptom.**
After adding Loki to the Grafana provisioning datasources file and restarting the Grafana container, the UI showed:

```
Data source not found
```

…on dashboards that should have been able to query the new datasource.
Server-side, everything looked fine: the provisioning logs in Grafana's container output showed both Prometheus and Loki being inserted.
A `curl` against Grafana's API returned both datasources.
But the browser-rendered UI insisted Loki didn't exist.

**Cause.**
Grafana caches the list of datasources in the browser's local storage.
The cached list, from before Loki was added, didn't include it.
The dashboard tried to query against that cached list and failed.

**Fix.**
Hard-refresh the browser: `Ctrl+Shift+R` on Linux/Windows, `Cmd+Shift+R` on macOS.
Or, more aggressively, clear the site's local storage from devtools.
After the refresh, the new datasource appears immediately.

**Why it surprised me.**
"Data source not found" sounds like a backend error.
The instinct is to check provisioning logs, the YAML file, the network connectivity to Loki, the datasource itself.
None of those were the problem — the backend was correct, the frontend was stale.

The deeper lesson: when a configuration change "doesn't take effect" but logs say it did, check the frontend cache before debugging the backend.
This applies beyond Grafana — anywhere a web UI persists state client-side, a hard refresh is a five-second test that rules out a whole category of false alarms.

## Smaller surprises

The following bit but didn't take days to resolve.
Documented as one-liners because the lesson is short.

- **Image tag/registry conventions vary per project.** Loki uses `3.7.1` (no `v` prefix). Alloy uses `v1.15.1` (with `v`). cAdvisor uses `0.56.2` (no `v`, on the new `ghcr.io` registry; `v` was used on the old `gcr.io` registry). There's no consistent convention. Always verify against the actual registry page, not the upstream Git release page.

- **firewalld is a two-step apply on RHEL.** `firewall-cmd --permanent --add-port=9100/tcp` writes the config but doesn't apply it. `firewall-cmd --reload` applies. Without the reload, the rule survives a reboot but isn't live in the current runtime. This is different from runtime-only `--add-port` (no `--permanent`), which applies immediately but doesn't survive reboot.

- **Renaming a Compose service requires `--remove-orphans`.** Renaming a service in `docker-compose.yml` (for example, fixing a typo from `graphana` to `grafana`) leaves the old container as an "orphan" — same name, no matching service in the file. The next `docker compose up -d` fails with a name collision. Add `--remove-orphans` to clean up.

- **Stale Prometheus series persist for the full retention period.** When a scrape target's identifier changes (renamed, re-IPed, etc.), the old time series doesn't disappear when new scrapes start. It sits in the TSDB until the retention window (in this stack, 90 days) expires. This shows up as ghost entries in Grafana variable dropdowns. Cosmetic only, but a useful reminder that Prometheus retains _series identity_, not just samples.

- **PromQL series identity is the full label set, not a single label.** Querying `{name="cadvisor"}` across multiple hosts returns multiple series — distinguished by `instance`. To aggregate "this container across the fleet," group by `(instance, name)` rather than expecting `name` alone to be unique.

- **Alloy's container image has no `wget` or `curl`.** When debugging connectivity from inside the Alloy container, the usual `docker exec alloy curl http://loki:3100/ready` doesn't work — the binaries aren't there. Modern minimal container images strip everything non-essential. Use Alloy's debug UI on port 12345 instead, or run network tests from a sidecar.

- **Loki dashboards from grafana.com may use placeholder data source names.** Importing dashboard 3662 (or others) initially fails with `DS_THEMIS not found` — a leftover variable from the original author's environment. The fix is in the import dialog itself: there's a dropdown to map `DS_THEMIS` to your actual Prometheus datasource. Easy to miss because the error message points at a missing data source rather than an unmapped variable.
