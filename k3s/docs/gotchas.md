# Gotchas

Issues encountered during cluster provisioning and setup.

## Node token truncated in terminal paste

**Symptom.**
The worker join command runs but produces no output.
The worker does not appear in `kubectl get nodes` on the master.

**Cause.**
The node token (`/var/lib/rancher/k3s/server/node-token`) is a long string.
When pasted into a terminal as part of a multi-line command, the token broke across lines.
The shell interpreted the second line of the token as a separate command, resulting in a silent failure — the join attempted with a truncated, invalid token.

**Fix.**
Export the token and URL as environment variables before running the install script:

```bash
export K3S_URL=https://10.33.111.103:6443
export K3S_TOKEN=<full-token>
curl -sfL https://get.k3s.io | sudo -E sh -
```

The `-E` flag preserves exported environment variables through sudo.
This avoids embedding the token inline in the curl pipeline where it can be mangled by terminal line wrapping.

**Broken assumption.**
I assumed pasting a multi-line shell command would work the same as typing it.
Long tokens in inline environment variable assignments are fragile when pasted — export them first.

## sudo strips environment variables by default

**Symptom.**
Running `curl -sfL https://get.k3s.io | K3S_URL=... K3S_TOKEN=... sudo sh -` either fails or
starts k3s without the URL and token, treating the node as a server instead of an agent.

**Cause.**
sudo drops most environment variables by default for security reasons.
Setting `K3S_URL=... K3S_TOKEN=...` before `sudo` passes them to the shell's environment but sudo doesn't forward them into the elevated process unless explicitly told to.

**Fix.**
Use `sudo -E` to preserve the calling environment, combined with exporting the variables first:

```bash
export K3S_URL=https://10.33.111.103:6443
export K3S_TOKEN=<token>
curl -sfL https://get.k3s.io | sudo -E sh -
```

**Broken assumption.**
I assumed environment variables set before `sudo` would be visible inside the sudo process.
By default, sudo starts with a clean environment.
`sudo -E` is the explicit opt-in to inherit the parent environment.

## ~/.kube directory does not exist by default

**Symptom.**
`scp` of the kubeconfig fails with `open local "/Users/arpatek/.kube/config": No such file or directory`.

**Cause.**
`~/.kube/` is not created automatically when kubectl is installed.
`scp` cannot create intermediate directories on the destination.

**Fix.**
Create the directory before copying:

```bash
mkdir -p ~/.kube
scp arpatek@10.33.111.103:/etc/rancher/k3s/k3s.yaml ~/.kube/config
```

**Broken assumption.**
None — this is just a prerequisite step that's easy to skip.

## ARM64 kubectl required on Asahi Linux

**Symptom.**
kubectl downloaded from the standard Linux URL fails to execute on Asahi Linux (Apple Silicon MacBook Air running Fedora Asahi Remix).

**Cause.**
The standard kubectl binary is compiled for x86_64 (`amd64`).
Asahi Linux runs on ARM64 (Apple M-series chip).
The wrong architecture binary either fails to execute or runs under emulation with poor performance.

**Fix.**
Download the `arm64` build explicitly:

```bash
curl -LO "https://dl.k8s.io/release/v1.35.4/bin/linux/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Broken assumption.**
I assumed the default kubectl download URL would serve the right architecture.
The URL requires the architecture to be specified explicitly — it does not auto-detect.
