# homelab-infra

GitOps-based homelab infrastructure using `k3d` + `Argo CD`.

## Repository Structure

```text
bootstrap/
  argocd/              # Initial Argo CD manifests; manual bootstrap only
clusters/
  local/               # k3d cluster config; root Application lives here
apps/
  platform/            # Platform apps: sealed-secrets, monitoring, logs
charts/                # Custom Helm charts (if needed)
manifests/
  common/              # Reusable plain Kubernetes YAMLs
```

## How It Works

1. `make create` brings up the `k3d` cluster
2. `make repo-secret` registers your SSH key for private repo access
3. `make bootstrap` installs `Argo CD` and creates the root `Application`
4. `Argo CD` reads `clusters/local/` and syncs the `platform` app-of-apps
5. The `platform` app creates all apps under `apps/platform/`
6. Everything stays in sync with Git automatically

## Local workflow

### Requirements

- `k3d` => `v5.9.0`
- `kubectl`=> `v1.35.4`
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
```

Delete the k3d cluster:

```bash
make delete
```

Recreate the cluster from scratch:

```bash
make recreate
```

## Secret management with HashiCorp Vault

For simplicity, this homelab runs [HashiCorp Vault](https://www.vaultproject.io/) in Docker **outside** the Kubernetes cluster. This setup emulates a production environment where secrets are managed by an external secret store rather than inside Kubernetes. The [External Secrets Operator](https://external-secrets.io/) syncs secrets from Vault into standard Kubernetes `Secret` resources.

### Start Vault

> Requires the k3d cluster to be running, because Vault attaches to the k3d Docker network (`k3d-homelab` by default).

```bash
make vault-up
```

To use a different Docker network, create `docker/vault/.env` from `.env.example` and set `VAULT_NETWORK`:

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

Apply the token as a Kubernetes Secret manually (Option A):

```bash
kubectl create secret generic vault-token \
  -n external-secrets \
  --from-literal=token="$(cat docker/vault/eso-token.txt)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Validate the integration

Create a demo secret in Vault:

```bash
docker exec -e VAULT_TOKEN=root vault vault kv put secret/demo username=admin password=supersecret
```

Wait for External Secrets Operator to sync, then verify:

```bash
kubectl get externalsecret -n vault-demo
kubectl get secret vault-demo-secret -n vault-demo -o jsonpath='{.data.username}' | base64 -d
```

### Useful commands

```bash
make vault-status    # Show Vault status
make vault-token     # Print the ESO token
make vault-down      # Stop Vault container
```
