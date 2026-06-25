# homelab-infra

GitOps-based homelab infrastructure using `k3s` (primary) or `k3d` (local) + `Argo CD`.

The main environment runs on a Hostinger VPS with `k3s`. The same manifests are validated locally with `k3d` before being pushed.

## Repository Structure

```text
bootstrap/
  argocd/              # Initial Argo CD manifests; manual bootstrap only
clusters/
  local/               # Root Argo CD Application lives here
apps/
  platform/            # Platform apps: cert-manager, external-secrets, Vault integration, Headlamp, cloudflared
charts/                # Custom Helm charts (if needed)
docker/
  vault/               # HashiCorp Vault dev-mode container (runs outside the cluster)
```

## How It Works

1. `make create` installs `k3s` on the node or brings up a local `k3d` cluster
2. `make bootstrap` installs `Argo CD` and creates the root `Application`
3. `make repo-secret` registers your SSH key for private repo access
4. `Argo CD` reads `clusters/local/` and syncs the `platform` app-of-apps
5. The `platform` app creates all apps under `apps/platform/`
6. Everything stays in sync with Git automatically
7. `make vault-up` + `make vault-bootstrap` start Vault and provide the token to External Secrets Operator

## Adding a new Git repository

This homelab follows the app-of-apps pattern. The root Application (`bootstrap/argocd/root-application.yaml`) watches `clusters/local/`, and every Argo CD Application placed there is automatically synced.

### Recommended: separate repository

To add a new standalone repository, create a new Application manifest under `clusters/local/`:

```yaml
# clusters/local/myapp-application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:your-user/myapp-infra.git
    targetRevision: HEAD
    path: clusters/local
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Then register the repository SSH credential:

```bash
kubectl -n argocd create secret generic myapp-repo-secret \
  --from-literal=url="git@github.com:your-user/myapp-infra.git" \
  --from-file=sshPrivateKey="$HOME/.ssh/id_ed25519_myapp" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret myapp-repo-secret argocd.argoproj.io/secret-type=repository --overwrite
```

### Alternative: add inside this repository

You can also add a new Application under `apps/platform/<app>/` if it is part of the platform base. The existing `platform` Application will pick it up automatically.

## k3s workflow (production-like VPS)

### Requirements

- A Linux node with SSH access (tested on Hostinger VPS).
- `kubectl` installed on the machine that runs `make`.
- A dedicated SSH private key for Argo CD repo access, for example `~/.ssh/id_ed25519_argocd`.
- The key must not have a passphrase.

> The Makefile commands for `k3s` assume you run them **on the target node itself** (or via SSH with the repo already cloned there), because it installs k3s via `curl | sh` and copies `/etc/rancher/k3s/k3s.yaml`.

### Create the cluster

```bash
K3_TYPE=k3s K3S_NODE_IP=203.0.113.10 make create
```

### Verify the cluster

```bash
make status
make verify
```

### Delete the cluster

```bash
K3_TYPE=k3s make delete
```

## Local workflow (k3d)

### Requirements

- `k3d` => `v5.9.0`
- `kubectl` => `v1.35.4`
- a dedicated local SSH private key for Argo CD repo access, for example `~/.ssh/id_ed25519_argocd`
- the key must not have a passphrase

Install `k3d`:

```bash
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

Install `kubectl`:

```bash
sudo dnf install kubectl
```

### Workflow

Create the cluster:

```bash
make create
```

**Configuration options:**

The Makefile supports customization via environment variables:

```bash
# Use k3s instead of k3d (default: k3d)
K3_TYPE=k3s

# k3s node IP (required for k3s)
K3S_NODE_IP=203.0.113.10

# Custom cluster name (default: homelab)
CLUSTER_NAME=my-cluster

# Custom k3d/k3s arguments
K3_ARGS="--servers 3 --agents 2"

# Combine multiple options
K3_TYPE=k3d CLUSTER_NAME=dev K3_ARGS="--servers 1"
```

Register the Git repository credential from your local SSH key:

```bash
make repo-secret
```

If needed, generate a dedicated key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_argocd -N ""
```

Run basic health checks:

```bash
make status
make verify
```

Delete the cluster:

```bash
make delete
```

Recreate the cluster from scratch:

```bash
make recreate
```

## Secret management with HashiCorp Vault

For simplicity, this homelab runs [HashiCorp Vault](https://www.vaultproject.io/) in Docker **outside** the Kubernetes cluster. This setup emulates a production environment where secrets are managed by an external secret store rather than inside Kubernetes. The [External Secrets Operator](https://external-secrets.io/) syncs secrets from Vault into standard Kubernetes `Secret` resources.

> **Trade-off:** Vault runs in dev mode with a fixed root token (`root`) and without TLS. This is intentional for learning/homelab and is **not** suitable for real sensitive data.

### Start Vault

> Requires the Docker network to exist. For k3d it is created automatically by `make create`; for k3s the Makefile creates it before starting Vault.

```bash
make vault-up
```

The default Docker network is `k3-$(CLUSTER_NAME)`, e.g. `k3-homelab`. To override it, create `docker/vault/.env` from `.env.example` and set `VAULT_NETWORK`:

```bash
cp docker/vault/.env.example docker/vault/.env
# edit VAULT_NETWORK in docker/vault/.env
```

### Bootstrap Vault

This enables the KV v2 secrets engine, creates a read-only policy, and generates a token for External Secrets Operator:

```bash
make vault-bootstrap
```

The token is saved locally to `docker/vault/eso-token.txt` and is **not** committed to Git.

### Provide the Vault token to Kubernetes

The token is injected automatically when using `make create`. To inject it manually:

```bash
kubectl create secret generic vault-token \
  -n external-secrets \
  --from-literal=token="$(cat docker/vault/eso-token.txt)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Using a Vault secret in an application

1. Create the secret in Vault:

```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=root \
  vault vault kv put secret/myapp/database \
    host=postgres.myapp.svc user=appuser password=changeme
```

2. Add an `ExternalSecret` to your application manifests:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-database
  namespace: myapp
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-backend
  target:
    name: database-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: DB_HOST
      remoteRef:
        key: secret/myapp/database
        property: host
    - secretKey: DB_USER
      remoteRef:
        key: secret/myapp/database
        property: user
    - secretKey: DB_PASSWORD
      remoteRef:
        key: secret/myapp/database
        property: password
```

3. Reference the generated Kubernetes Secret in your Deployment:

```yaml
envFrom:
  - secretRef:
      name: database-secret
```

> Only commit the `ExternalSecret`. The generated `Secret` is created at runtime and must not be committed.

## TLS and Ingress

The cluster uses **Traefik** (default in k3d/k3s) as the ingress controller and **cert-manager** with a self-signed `ClusterIssuer` to provide TLS for internal services.

The domain `sputinik.tech` is used for friendly URLs. The certificates are self-signed, so browsers will show a warning on first access; accept the exception to proceed.

### Exposed services

| Service | k3d URL | k3s URL |
|---|---|---|
| Argo CD | `https://argocd.sputinik.tech:8443` | `https://argocd.sputinik.tech` |
| Headlamp | `https://headlamp.sputinik.tech:8443` | `https://headlamp.sputinik.tech` |

### Local DNS (k3d)

Add the following entry to `/etc/hosts` on the machine that accesses the cluster:

```text
127.0.0.1 argocd.sputinik.tech headlamp.sputinik.tech
```

The k3d load balancer maps host port `8443` to Traefik port `443`.

### DNS on k3s

Point the same hostnames in your LAN DNS (router, Pi-hole, etc.) to the k3s node IP or a LoadBalancer IP, then access the services on standard port `443`:

```text
https://argocd.sputinik.tech
https://headlamp.sputinik.tech
```

No manifest changes are required; only the DNS target changes.

### Argo CD behind the ingress

The Argo CD server is configured to run in **insecure mode** (`server.insecure: "true"`) so that Traefik terminates TLS and talks HTTP to the backend. If you change the ingress configuration, you may need to restart the Argo CD server deployment:

```bash
kubectl rollout restart deployment argocd-server -n argocd
```

### Migrating to a public certificate

When you are ready to expose services to the internet directly, replace the `selfsigned-issuer` `ClusterIssuer` with a Let's Encrypt issuer (HTTP-01 or DNS-01) and update the `cert-manager.io/cluster-issuer` annotation on the ingresses. The rest of the configuration remains the same.

## Exposing services to the internet with Cloudflare Tunnel

The repository includes a `cloudflared` deployment that creates an outbound tunnel to Cloudflare. This allows exposing services without opening inbound ports on your firewall.

### Requirements

- A Cloudflare account.
- The domain `sputinik.tech` managed by Cloudflare.
- The Cloudflare Tunnel token stored in Vault at `secret/cloudflare` under the key `TUNNEL_TOKEN`.

### How it works

```text
user → Cloudflare → cloudflared (inside k3d/k3s) → Traefik → service
```

Because the tunnel is initiated from inside the cluster, no inbound firewall rules are required.

### Tunnel configuration

The ingress rules for the tunnel are defined in the repository at `apps/platform/cloudflared/config.yaml`:

```yaml
ingress:
  - hostname: argocd.sputinik.tech
    service: https://traefik.kube-system.svc.cluster.local
    originRequest:
      noTLSVerify: true
  - hostname: headlamp.sputinik.tech
    service: https://traefik.kube-system.svc.cluster.local
    originRequest:
      noTLSVerify: true
  - service: http_status:404
```

The `noTLSVerify` option is required because the cluster uses a self-signed certificate. The connection from the user to Cloudflare remains encrypted with a valid certificate.

In the Cloudflare Zero Trust dashboard you only need to create the tunnel and copy its token to Vault. The public hostnames themselves are managed by the config file above; do not configure them manually in the dashboard, or keep them empty to avoid conflicts.

### TLS mode

Set the Cloudflare TLS mode to **Full** (not Full Strict). This makes Cloudflare accept the cluster's self-signed certificate on the internal origin connection while presenting a valid certificate to users.

### Same manifests on k3d and k3s

The `cloudflared` manifests work unchanged on both k3d and k3s because they reference Traefik via internal cluster DNS (`traefik.kube-system.svc.cluster.local`). When migrating to k3s, just ensure the same tunnel token is available in Vault and that the `vault-integration` app is synced.

### Useful commands

```bash
make vault-status    # Show Vault status
make vault-token     # Print the ESO token
make vault-down      # Stop Vault container
```
