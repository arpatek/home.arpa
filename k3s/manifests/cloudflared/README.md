# cloudflared

Cloudflare Tunnel deployment for `arpatek.dev`.

Runs as a 2-replica Deployment — two pods, two redundant connections to Cloudflare's edge.
Traffic path: `Cloudflare edge → tunnel → cloudflared pod → Traefik → arpatek-dev Service :8000`

## Tunnel details

| | |
|---|---|
| Tunnel name | `arpatek-dev` |
| Tunnel ID | `6e7e231c-1c15-4beb-a345-799852d72e62` |
| Hostname | `arpatek.dev` |
| Backend | `http://traefik.kube-system.svc.cluster.local:80` |
| Replicas | 2 (one connection per pod — survives pod restarts and rolling updates without downtime) |
| Image | `cloudflare/cloudflared:2026.5.0` |

## Prerequisites

- `cloudflared` installed locally (`brew install cloudflare/cloudflare/cloudflared` on macOS)
- `kubectl` configured against the cluster
- Cloudflare account access for `arpatek.dev`

## First-time setup

These steps are required once per cluster. The credentials Secret is not committed — it must be recreated if the cluster is rebuilt.

**1. Authenticate cloudflared with your Cloudflare account:**

```bash
cloudflared tunnel login
```

Select `arpatek.dev` in the browser. This writes `~/.cloudflared/cert.pem`.

**2. The tunnel is already registered.** If you need to recreate it (e.g. after deleting it in the dashboard), run:

```bash
cloudflared tunnel create arpatek-dev
```

Update the tunnel ID in `deployment.yaml` and this README with the new UUID.

**3. Load the credentials into k3s as a Secret:**

```bash
kubectl create secret generic cloudflared-credentials \
  --from-file=credentials.json=$HOME/.cloudflared/<TUNNEL-ID>.json \
  -n default
```

**4. Add the DNS CNAME (only needed if it was removed):**

```bash
cloudflared tunnel route dns arpatek-dev arpatek.dev
```

**5. Apply the manifests:**

```bash
kubectl apply -f deployment.yaml
```

## Verify

```bash
# Both pods should be Running with 0 restarts
kubectl get pods -l app=cloudflared -n default

# Check tunnel connectivity from Cloudflare's side
cloudflared tunnel info arpatek-dev
```

## Upgrading cloudflared

1. Check the latest release: `cloudflared --version` after `brew upgrade cloudflare/cloudflare/cloudflared`
2. Update the image tag in `deployment.yaml`
3. `kubectl apply -f deployment.yaml` — k3s will do a rolling update

## Recovery (cluster rebuild)

If the cluster is rebuilt from scratch:

1. The tunnel registration in Cloudflare survives — no need to recreate it
2. Recreate the credentials Secret (step 3 above)
3. Reapply the manifests (step 5 above)
4. The DNS CNAME also survives — no action needed
