# MimirFlow Application Onboarding & Operations

Deployment reference and operations guide for MimirFlow (`mimir.sputinik.tech`) on the homelab k3s cluster via Argo CD GitOps.

---

## 1. Overview

- **Application Repository**: `git@github.com:Spuntininki/mimirflow.git`
- **Manifest Path**: `deploy/k8s`
- **Target Namespace**: `mimirflow`
- **Public Domain**: `https://mimir.sputinik.tech`
- **Ingress Controller**: Traefik (`websecure` entrypoint, host port 443)
- **Edge Routing**: Cloudflare Zero Trust Tunnel -> Traefik
- **TLS Issuer**: `letsencrypt-prod` (Cert-Manager ClusterIssuer)
- **Secret Management**: External Secrets Operator (ESO) syncing from HashiCorp Vault (`vault-backend`)

---

## 2. Prerequisites & Pre-Reconciliation Setup

Before Argo CD reconciles the `mimirflow` application, the following platform prerequisites must be in place.

### 2.1 Vault Secrets Provisioning

MimirFlow requires database and application secrets stored in Vault under `secret/mimirflow/*`.

Populate the database credentials:
```bash
make vault-put APP=mimirflow SECRET=database DATA="\
  host=postgres \
  port=5432 \
  user=mimirflow \
  password='<POSTGRES_PASSWORD>' \
  name=mimirflow"
```

Populate the runtime application secrets:
```bash
make vault-put APP=mimirflow SECRET=app DATA="\
  openrouter_api_key='<OPENROUTER_API_KEY>' \
  telegram_bot_token='<TELEGRAM_BOT_TOKEN>' \
  telegram_chat_id='<TELEGRAM_CHAT_ID>' \
  telegram_allowed_user_ids='[<TELEGRAM_ALLOWED_USER_ID>]' \
  redis_url='redis://redis:6379/0' \
  github_token='<OPTIONAL_GITHUB_TOKEN>' \
  log_level='INFO'"
```

Verify secrets are properly stored:
```bash
make vault-get APP=mimirflow SECRET=database
make vault-get APP=mimirflow SECRET=app
```

### 2.2 GHCR Image Pull Secret

Ensure the GHCR pull secret `registry-ghcr` exists in the `mimirflow` namespace. If namespace is created automatically by Argo CD, verify the synchronized secret or create it:
```bash
kubectl create namespace mimirflow --dry-run=client -o yaml | kubectl apply -f -
# If shared GHCR secret is used across namespaces:
kubectl get secret registry-ghcr -n default -o yaml | sed 's/namespace: default/namespace: mimirflow/' | kubectl apply -f -
```

### 2.3 Private Git Repository Access in Argo CD

If `Spuntininki/mimirflow` is private, register the deploy SSH key in Argo CD:
```bash
kubectl -n argocd create secret generic mimirflow-repo \
  --from-literal=url="git@github.com:Spuntininki/mimirflow.git" \
  --from-file=sshPrivateKey="$HOME/.ssh/id_ed25519_mimirflow" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret mimirflow-repo argocd.argoproj.io/secret-type=repository --overwrite
```

---

## 3. Cloudflare Zero Trust Configuration

MimirFlow web panel and API are routed through Cloudflare Tunnel with Zero Trust Access protection:

1. Open Cloudflare Zero Trust Dashboard -> **Networks** -> **Tunnels**.
2. Select the homelab tunnel and click **Configure**.
3. Under **Public Hostnames**, add:
   - **Subdomain**: `mimir`
   - **Domain**: `sputinik.tech`
   - **Type**: `HTTPS`
   - **URL**: `traefik.kube-system.svc.cluster.local`
4. Expand **Additional application settings** -> **TLS**:
   - Enable **No TLS Verify**.
5. Save hostname.
6. Under **Access** -> **Applications**, configure an Access Application protecting `mimir.sputinik.tech` for authorized email addresses/groups.

---

## 4. Verification & Diagnostics

Once `clusters/local/apps/mimirflow.yaml` is merged and pushed to `main`:

```bash
# Check Argo CD Application sync and health:
kubectl get applications -n argocd mimirflow

# Check Pods in mimirflow namespace:
kubectl get pods -n mimirflow

# Check ExternalSecret status:
kubectl get externalsecret -n mimirflow

# Check Ingress and TLS certificate:
kubectl get ingress,certificate -n mimirflow

# Stream logs for API or worker:
make logs APP=api NS=mimirflow
make logs APP=worker NS=mimirflow
```
