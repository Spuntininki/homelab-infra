# homelab-infra

GitOps-based homelab infrastructure using `k3s` (primary) or `k3d` (local) + `Argo CD`.

The main environment runs on a Hostinger VPS with `k3s`. The same manifests are validated locally with `k3d` before being pushed.

## Repository Structure

```text
apps/
  platform/            # Platform apps: cert-manager, external-secrets, Vault integration, Headlamp, cloudflared, registry, argocd
bootstrap/
  argocd/              # Initial Argo CD manifests; manual bootstrap only
clusters/
  local/               # Root Argo CD Application lives here
    apps/              # Declarative application onboarding via ApplicationSet
docker/
  vault/               # HashiCorp Vault dev-mode container (runs outside the cluster)
docs/
  access.md            # Persistent k3s access, TLS SANs & Tailscale mesh guide
  runbook.md           # Day-2 operations, app onboarding, troubleshooting & disaster recovery
scripts/
  setup-access.sh      # Automated kubeconfig configuration & verification
  setup-tailscale.sh   # Tailscale node & TLS SAN setup
  vault.sh             # Vault CLI & secret management helper
templates/
  app-base/            # Standardized application manifest scaffold
```

## Documentation & Operational Runbooks

- **[docs/runbook.md](docs/runbook.md)**: Comprehensive Day-2 operations manual, end-to-end < 10 minute app deployment checklist, architecture map, troubleshooting guides (Vault, ESO, GHCR, local-path storage), and disaster recovery procedures.
- **[docs/access.md](docs/access.md)**: Persistent remote k3s API access without manual SSH tunnels, TLS SAN configuration, and Tailscale mesh VPN setup.
- **[templates/app-base/README.md](templates/app-base/README.md)**: Application scaffold documentation, platform conventions (`enableServiceLinks: false`, URL-encoded database passwords, Traefik ingress, GHCR credentials).

## How It Works

1. `make create` installs `k3s` on the node or brings up a local `k3d` cluster
2. `make bootstrap` installs `Argo CD` and creates the root `Application`
3. `make repo-secret` registers your SSH key for private repo access
4. `Argo CD` reads `clusters/local/` and syncs the `platform` app-of-apps
5. The `platform` app deploys all platform components under `apps/platform/`, including the `ApplicationSet`
6. Any application declared in `clusters/local/apps/*.yaml` is automatically discovered and instantiated
7. `make vault-up` + `make vault-bootstrap` start Vault and configure Kubernetes ServiceAccount authentication for External Secrets Operator

## Deploying Applications

### Recommended: Automated Onboarding via ApplicationSet (< 10 Minutes)

Application manifests live in your application repository under `deploy/k8s/` (scaffolded using `templates/app-base/`).

To deploy a new application into the cluster:

1. Scaffold manifests in your app repository using `templates/app-base/`.
2. Seed secrets into Vault:
   ```bash
   make vault-put APP=myapp SECRET=database DATA="host=... port=5432 user=... password=... name=..."
   ```
3. Register the app repository SSH deploy key in Argo CD:
   ```bash
   kubectl -n argocd create secret generic myapp-repo \
     --from-literal=url="git@github.com:your-user/myapp.git" \
     --from-file=sshPrivateKey="$HOME/.ssh/id_ed25519_myapp" \
     --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n argocd label secret myapp-repo argocd.argoproj.io/secret-type=repository --overwrite
   ```
4. Create `clusters/local/apps/myapp.yaml` in `homelab-infra`:
   ```yaml
   name: myapp
   repoURL: git@github.com:your-user/myapp.git
   targetRevision: HEAD
   path: deploy/k8s
   namespace: myapp
   ```
5. Commit and push. Argo CD's `ApplicationSet` automatically discovers the file, creates the `Application`, enables automated self-healing, ServerSideApply, and creates the namespace.

See the complete step-by-step walkthrough in **[docs/runbook.md](docs/runbook.md)**.

### Alternative: Direct Argo CD Application

For specialized applications or platforms requiring custom sync options, create a standalone Application manifest under `clusters/local/`:

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
    repoURL: git@github.com:your-user/myapp.git
    targetRevision: HEAD
    path: deploy/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

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

### Remote k3s API access

To configure persistent access to the remote k3s cluster from your local workstation (without manual SSH tunnels):

```bash
# Via public IP / domain with TLS SAN:
SERVER=k8s.sputinik.tech REMOTE_HOST=root@187.77.241.62 make access

# Or via Tailscale mesh IP:
SERVER=100.64.0.1 REMOTE_HOST=root@187.77.241.62 make access
```

See [docs/access.md](docs/access.md) for architecture details, TLS SAN configuration, Tailscale setup, and troubleshooting.

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

The tunnel is **remotely managed** from the Cloudflare Zero Trust dashboard. The manifest only runs the `cloudflared` connector; the ingress rules live in Cloudflare.

In the dashboard, inside your tunnel, add the following public hostnames pointing to the internal Traefik service:

| Subdomain | Type | URL |
|---|---|---|
| `argocd.sputinik.tech` | HTTPS | `https://traefik.kube-system.svc.cluster.local` |
| `headlamp.sputinik.tech` | HTTPS | `https://traefik.kube-system.svc.cluster.local` |

For each hostname, expand **Additional application settings > TLS** and enable **No TLS Verify**. This is required because the cluster uses a self-signed certificate. The connection from the user to Cloudflare remains encrypted with a valid certificate.

### TLS mode

Set the Cloudflare TLS mode to **Full** (not Full Strict). This makes Cloudflare accept the cluster's self-signed certificate on the internal origin connection while presenting a valid certificate to users.

### Same manifests on k3d and k3s

The `cloudflared` manifests work unchanged on both k3d and k3s because they reference Traefik via internal cluster DNS (`traefik.kube-system.svc.cluster.local`). When migrating to k3s, just ensure the same tunnel token is available in Vault and that the `vault-integration` app is synced.

## Command Reference & Operational Tooling

### Cluster Status & Health

```bash
# Display cluster nodes, pods across all namespaces, and Argo CD application sync/health status:
make status

# Run baseline health checks on core platform workloads, ingresses, and Vault integration:
make verify

# Stream container logs with automatic selector resolution (Deployment, Pod, or Docker Vault):
make logs APP=cloudflared
make logs APP=argocd-server NS=argocd
make logs APP=vault TAIL=50
```

### Remote k3s API Access

```bash
# Configure persistent access via public IP / TLS SAN:
SERVER=k8s.sputinik.tech REMOTE_HOST=root@187.77.241.62 make access

# Or configure persistent access via Tailscale mesh IP:
SERVER=100.64.0.1 REMOTE_HOST=root@187.77.241.62 make access

# Merge into default ~/.kube/config:
SERVER=k8s.sputinik.tech REMOTE_HOST=root@187.77.241.62 MERGE=1 make access
```

See **[docs/access.md](docs/access.md)** for details on TLS SAN configuration and firewall rules.

### Vault & Secrets Management

```bash
# Store secrets in HashiCorp Vault:
make vault-put APP=myapp SECRET=database DATA="host=localhost port=5432 user=appuser password=secret"

# Retrieve secrets in clean JSON:
make vault-get APP=myapp SECRET=database

# List secrets stored under a path:
make vault-list
make vault-list PATH_ARG=secret/myapp

# Inspect Vault container status:
make vault-status

# Vault lifecycle:
make vault-up        # Start Vault container in Docker
make vault-bootstrap # Initialize KV v2 engine, create policy & token
make vault-down      # Stop Vault container
```
