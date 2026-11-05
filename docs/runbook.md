# Homelab Operations & Day-2 Runbook

Comprehensive operational guide, architecture reference, troubleshooting runbooks, and disaster recovery procedures for the homelab infrastructure on k3s and k3d.

---

## 1. Homelab Architecture & Traffic Flow

The homelab runs on a Hostinger VPS (single-node k3s) managed via GitOps with Argo CD. Local development and validation use k3d.

### 1.1 Ingress & Network Traffic Flow

```
+---------------------------------------------------------------------------------------+
|                                    PUBLIC INTERNET                                    |
|                                                                                       |
|   Client Request (https://<app>.sputinik.tech)                                        |
+------------------------------------------+--------------------------------------------+
                                           |
                                           v
+---------------------------------------------------------------------------------------+
|                              CLOUDFLARE ZERO TRUST EDGE                               |
|                                                                                       |
|   - Edge SSL Termination (Strict HTTPS)                                               |
|   - DDoS & Web Application Firewall (WAF)                                             |
|   - DNS Resolution (*.sputinik.tech -> Cloudflare Anycast IP)                          |
+------------------------------------------+--------------------------------------------+
                                           | Encrypted Tunnel (Outbound TCP/QUIC)
                                           v
+---------------------------------------------------------------------------------------+
|                           K3S CLUSTER (Hostinger VPS)                                 |
|                                                                                       |
|   +-------------------------------------------------------------------------------+   |
|   | namespace: cloudflared                                                        |   |
|   |   cloudflared Pod (Connector)                                                 |   |
|   |   Receives traffic from Cloudflare via outbound tunnel connection.            |   |
|   |   Proxies to internal Traefik Ingress Controller.                             |   |
|   +--------------------------------------+----------------------------------------+   |
|                                          | Internal HTTPS / Port 443                  |
|                                          v                                            |
|   +-------------------------------------------------------------------------------+   |
|   | namespace: kube-system                                                        |   |
|   |   Traefik Ingress Controller (Host Port 443 / websecure entrypoint)           |   |
|   |   - Matches Host header (e.g. my-service.sputinik.tech)                       |   |
|   |   - Routes to backend Service                                                 |   |
|   +--------------------------------------+----------------------------------------+   |
|                                          | ClusterIP / Pod Network                    |
|                                          v                                            |
|   +-------------------------------------------------------------------------------+   |
|   | namespace: <app-namespace>                                                    |   |
|   |   ClusterIP Service -> Workload Pods (Containers)                             |   |
|   +-------------------------------------------------------------------------------+   |
+---------------------------------------------------------------------------------------+
```

### 1.2 GitOps Reconciliation Loop

```
Git Repository (github.com/Spuntininki/homelab-infra)
  │
  ├── bootstrap/argocd/root-application.yaml
  │     └── Watches: clusters/local/
  │
  └── clusters/local/
        ├── platform-application.yaml
        │     └── Watches: apps/platform/
        │           ├── cert-manager (Helm)
        │           ├── external-secrets (Helm)
        │           ├── vault-integration (ClusterSecretStore)
        │           ├── registry (ClusterExternalSecret for GHCR)
        │           ├── cloudflared (Deployment + ExternalSecret)
        │           ├── headlamp (Helm)
        │           └── argocd (ApplicationSet)
        │
        └── apps/*.yaml (Monitored by ApplicationSet)
              └── Automatically generates Argo CD Applications
```

### 1.3 Secret Management & Registry Flow

```
HashiCorp Vault (Docker container on host at port 8200)
  │
  ├── ServiceAccount Auth (`external-secrets` in `external-secrets` namespace)
  │     └── Validated by Vault Kubernetes auth engine
  │
  ├── ClusterSecretStore (`vault-backend`)
  │     ├── Synced to app namespaces via `ExternalSecret`
  │     └── Injected into Pods via Kubernetes `Secret` (`envFrom.secretRef`)
  │
  └── ClusterExternalSecret (`registry-ghcr`)
        ├── Pulls GHCR dockerconfig from Vault (`secret/platform/ghcr-token`)
        └── Automatically replicates `registry-ghcr` secret into all namespaces
```

---

## 2. Fast New App Onboarding (< 10 Minutes)

Follow this step-by-step checklist to deploy a new application into the homelab from scratch.

### Step 1: Scaffold Manifests in the App Repo (~2 min)

In your application's Git repository, create `deploy/k8s/` using `templates/app-base/`:

```bash
mkdir -p deploy/k8s
cp -r /path/to/homelab-infra/templates/app-base/* deploy/k8s/
cd deploy/k8s
```

Run search-and-replace for placeholders:

```bash
# Set your application name and domain
APP_NAME="my-service"
DOMAIN="${APP_NAME}.sputinik.tech"
IMAGE="ghcr.io/spuntininki/${APP_NAME}:v1.0.0"

sed -i "s/app-template/${APP_NAME}/g" *.yaml
sed -i "s|app\.sputinik\.tech|${DOMAIN}|g" ingress.yaml
sed -i "s|ghcr.io/spuntininki/app-template:latest|${IMAGE}|g" deployment.yaml
```

Key platform conventions already built into `templates/app-base/`:
- `enableServiceLinks: false` prevents Kubernetes service environment variables from overriding numeric application ports.
- `imagePullSecrets: [{ name: registry-ghcr }]` automatically uses the replicated GHCR credentials.
- `urlquery` Sprig filter in `external-secret.yaml` URL-encodes special characters in database passwords.
- Baseline resource requests (`50m` CPU / `64Mi` memory) protect VPS stability.

Validate manifests locally:
```bash
kubectl kustomize .
```

Commit and push `deploy/k8s/` to your application repository.

### Step 2: Seed Secrets in Vault (~2 min)

Use `scripts/vault.sh` or `make vault-put` from the `homelab-infra` directory:

```bash
# Seed application secrets:
make vault-put APP=my-service SECRET=database \
  DATA="host=postgres.database.svc.cluster.local port=5432 user=myuser password=Pass#Word! name=mydb"

# Or using the script directly:
./scripts/vault.sh put my-service database \
  host=postgres.database.svc.cluster.local \
  port=5432 \
  user=myuser \
  password='Pass#Word!' \
  name=mydb
```

Verify secrets are stored correctly:

```bash
make vault-get APP=my-service SECRET=database
```

### Step 3: Register Private Git Repository in Argo CD (~2 min)

If your application repository is private, register an SSH deploy key in Argo CD:

```bash
kubectl -n argocd create secret generic my-service-repo \
  --from-literal=url="git@github.com:Spuntininki/my-service.git" \
  --from-file=sshPrivateKey="$HOME/.ssh/id_ed25519_my_service" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret my-service-repo argocd.argoproj.io/secret-type=repository --overwrite
```

### Step 4: Register in ApplicationSet (~1 min)

In `homelab-infra`, create `clusters/local/apps/my-service.yaml`:

```yaml
name: my-service
repoURL: git@github.com:Spuntininki/my-service.git
targetRevision: HEAD
path: deploy/k8s
namespace: my-service
```

Commit and push:

```bash
git add clusters/local/apps/my-service.yaml
git commit -m "feat(apps): onboard my-service via ApplicationSet"
git push origin feat/<branch>
```

The Argo CD `ApplicationSet` controller automatically detects the new file, creates the `my-service` Application in Argo CD, and synchronizes the manifests into namespace `my-service`.

### Step 5: Configure Cloudflare Zero Trust Routing (~2 min)

If the service should be accessible over the internet:

1. Open Cloudflare Zero Trust Dashboard -> **Networks** -> **Tunnels**.
2. Select the homelab tunnel and click **Configure**.
3. Under **Public Hostnames**, click **Add a public hostname**:
   - **Subdomain**: `my-service`
   - **Domain**: `sputinik.tech`
   - **Type**: `HTTPS`
   - **URL**: `traefik.kube-system.svc.cluster.local`
4. Expand **Additional application settings** -> **TLS**:
   - Enable **No TLS Verify** (required because internal certificates are self-signed).
5. Save hostname.

### Step 6: Verify Deployment (~1 min)

Verify status from your workstation:

```bash
# Check node and pod status across namespaces:
make status

# Stream application logs:
make logs APP=my-service

# Verify ExternalSecret status:
kubectl get externalsecret -n my-service

# Verify Ingress and TLS certificate:
kubectl get ingress,certificate -n my-service

# Test health check endpoint:
curl -fsSL -k https://my-service.sputinik.tech/healthz
```

---

## 3. Troubleshooting Runbooks

### Runbook A: ExternalSecrets Validation & Vault Sync Issues

#### Symptom 1: `ClusterSecretStore` is `NotReady` or says `permission denied`

**Diagnostic Steps:**
```bash
kubectl describe clustersecretstore vault-backend
```

**Common Causes & Remediation:**

1. **Kubernetes ServiceAccount Token Missing or Expired:**
   - The ClusterSecretStore uses the `external-secrets` ServiceAccount in the `external-secrets` namespace.
   - Verify the ServiceAccount exists:
     ```bash
     kubectl get serviceaccount external-secrets -n external-secrets
     ```
   - If missing, reapply the RBAC manifests:
     ```bash
     kubectl apply -k apps/platform/vault-integration/
     ```

2. **Vault Kubernetes Auth Role Misconfigured:**
   - On the VPS node or via remote Vault API, verify the role configuration:
     ```bash
     curl -s -H "X-Vault-Token: root" ${VAULT_ADDR:-http://127.0.0.1:8200}/v1/auth/kubernetes/role/external-secrets
     # Or if accessing the container directly:
     docker exec -it vault vault read auth/kubernetes/role/external-secrets
     ```
   - If the role is missing, re-run Vault bootstrap:
     ```bash
     VAULT_ADDR=http://<vps-ip>:8200 make vault-bootstrap
     ```

3. **k3s DNS / Host Routing Missing (Node IP):**
   - On k3s, pods in the cluster cannot resolve the host Docker container by hostname `vault`.
   - Ensure the `vault` Service and Endpoints exist in `external-secrets`:
     ```bash
     kubectl get endpoints vault -n external-secrets
     ```
   - If missing or IP is wrong, re-run routing setup:
     ```bash
     K3S_NODE_IP=<vps-ip> make vault-k3s-routing
     ```

#### Symptom 2: `ExternalSecret` is in `SecretSyncedError`

**Diagnostic Steps:**
```bash
kubectl describe externalsecret <secret-name> -n <app-namespace>
```

**Common Causes & Remediation:**

1. **Path or Secret Key Does Not Exist in Vault:**
   - Inspect the secret in Vault:
     ```bash
     make vault-get APP=<app-name> SECRET=<secret-name>
     ```
   - If missing, store the required keys using:
     ```bash
     make vault-put APP=<app-name> SECRET=<secret-name> DATA="key=val"
     ```

2. **Database Password URL-Encoding Failure:**
   - If application logs report `invalid connection string: invalid port` or `failed to parse database URI`:
   - Check if the password contains special characters (`@`, `#`, `!`, `?`).
   - Ensure the `ExternalSecret` manifest uses `{{ .db_password | urlquery }}` under `template.data.DATABASE_URL`.

---

### Runbook B: GHCR Private Image Pulls & Secret Propagation

#### Symptom: Pod stuck in `ErrImagePull` or `ImagePullBackOff`

```text
Failed to pull image "ghcr.io/spuntininki/my-service:v1.0.0": rpc error: code = Unknown desc = failed to pull and unpack image: failed to resolve reference: unexpected status from HEAD request to https://ghcr.io/...: 403 Forbidden
```

**Diagnostic Steps:**

1. Check if the secret exists in the target namespace:
   ```bash
   kubectl get secret registry-ghcr -n <app-namespace>
   ```

2. Check the `ClusterExternalSecret` status in `apps/platform/registry/`:
   ```bash
   kubectl describe clusterexternalsecret registry-ghcr
   ```

**Common Causes & Remediation:**

1. **`registry-ghcr` Secret Missing in Namespace:**
   - The `ClusterExternalSecret` matches namespaces with `external-secrets.io/type: application` or all non-system namespaces.
   - Check `apps/platform/registry/cluster-external-secret.yaml`. If namespace selection fails, label the namespace:
     ```bash
     kubectl label namespace <app-namespace> external-secrets.io/type=application --overwrite
     ```

2. **Expired or Invalid GitHub PAT:**
   - If GHCR returns `403 Forbidden`, the PAT token stored in Vault has expired or lacks `read:packages` scope.
   - Generate a new GitHub Personal Access Token (classic) with `read:packages` scope.
   - Update Vault and regenerate the dockerconfigjson in one command:
     ```bash
     ./scripts/vault.sh generate-dockerconfig <github-username> <new-pat-token> \
       --store platform ghcr-token
     ```
   - External Secrets Operator detects the change within its refresh interval (`1h`) or force refresh immediately:
     ```bash
     kubectl annotate externalsecret registry-ghcr -n argocd force-sync=$(date +%s) --overwrite
     ```

3. **Missing `imagePullSecrets` in Pod Spec:**
   - Ensure the deployment contains:
     ```yaml
     spec:
       template:
         spec:
           imagePullSecrets:
             - name: registry-ghcr
     ```

---

### Runbook C: Persistent Storage (local-path provisioner) Caveats

k3s uses Rancher's `local-path-provisioner` as the default storage class. It binds PersistentVolumes directly to host directory paths (`/var/lib/rancher/k3s/storage/`).

#### Caveat 1: Single-Node Host Binding

- Local-path PersistentVolumes are **strictly host-local**.
- If the node is formatted or re-installed without backing up `/var/lib/rancher/k3s/storage/`, all database and persistent volumes are lost permanently.
- **Rule**: Always perform database backups (`pg_dump`) to remote storage before performing node maintenance or OS upgrades.

#### Caveat 2: Host Filesystem Permissions After Reboot or Migration

**Symptom**: Pod stuck in `CrashLoopBackOff` with logs:
```text
initdb: error: could not access directory "/var/lib/postgresql/data": Permission denied
```

**Root Cause:**
Container processes run as non-root UIDs (e.g., PostgreSQL runs as UID `999` or `70`, Redis runs as `999`). If host directory ownership changes during a restore or permissions are restricted, the container cannot write to its mounted volume.

**Diagnostic Steps:**
1. Identify the PersistentVolume host path:
   ```bash
   kubectl get pv $(kubectl get pvc <pvc-name> -n <namespace> -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.local.path}'
   ```
2. Inspect permissions on the host VPS:
   ```bash
   ls -ld /var/lib/rancher/k3s/storage/<pv-volume-directory>
   ```

**Remediation:**
Fix the ownership on the host filesystem:
```bash
# For PostgreSQL:
sudo chown -R 999:999 /var/lib/rancher/k3s/storage/<pvc-dir>

# General permissive fix for local homelab:
sudo chmod -R 775 /var/lib/rancher/k3s/storage/<pvc-dir>
```

#### Caveat 3: PVC Stuck in `Terminating` State

If a namespace or PVC is deleted while pods are still referencing it:
```bash
# Remove finalizers to unblock termination:
kubectl patch pvc <pvc-name> -n <namespace> -p '{"metadata":{"finalizers":null}}'
```

---

## 4. Disaster Recovery & Node Reboot Procedures

### 4.1 Planned Maintenance / Safe Shutdown Sequence

When applying OS security updates or rebooting the Hostinger VPS:

1. **Step 1: Cordon the node (optional for single-node, prevents scheduling churn):**
   ```bash
   kubectl cordon homelab-vps
   ```

2. **Step 2: Gracefully stop k3s:**
   Stopping k3s gracefully allows the container runtime to stop workload containers cleanly and sync storage buffers to disk:
   ```bash
   sudo systemctl stop k3s
   ```

3. **Step 3: Gracefully stop HashiCorp Vault:**
   ```bash
   make vault-down
   ```

4. **Step 4: Reboot the host:**
   ```bash
   sudo reboot
   ```

---

### 4.2 Post-Reboot Recovery Sequence

After the server reboots:

1. **Step 1: Check HashiCorp Vault:**
   - In dev mode, Vault runs in Docker. Verify the container is running:
     ```bash
     docker ps | grep vault
     ```
   - If stopped, start it:
     ```bash
     make vault-up
     ```
   - Check status:
     ```bash
     make vault-status
     ```
   - **Important for dev mode:** If the Vault container was recreated, memory state is reset. Re-run bootstrap:
     ```bash
     make vault-bootstrap
     ```

2. **Step 2: Verify k3s service status:**
   ```bash
   sudo systemctl status k3s
   ```
   Ensure port 6443 is listening:
   ```bash
   sudo ss -tulpn | grep 6443
   ```

3. **Step 3: Uncordon the node:**
   ```bash
   kubectl uncordon homelab-vps
   ```

4. **Step 4: Verify core platform workloads:**
   From your local workstation or host:
   ```bash
   make verify
   ```
   Verify Traefik ingress controller:
   ```bash
   kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
   ```
   Verify Cloudflare Tunnel connector:
   ```bash
   make logs APP=cloudflared
   ```
   Verify External Secrets Operator:
   ```bash
   kubectl get pods -n external-secrets
   kubectl describe clustersecretstore vault-backend
   ```

5. **Step 5: Verify Argo CD synchronization:**
   Check application statuses:
   ```bash
   make status
   ```
   If any application remains OutOfSync, trigger a hard refresh:
   ```bash
   kubectl get applications -n argocd -o name | xargs -n1 kubectl -n argocd patch --type merge -p '{"operation":{"sync":{"prune":true}}}'
   ```

---

### 4.3 Disaster Recovery Scenarios

#### Scenario 1: Complete Cluster Loss (Rebuilding from Git)

If the VPS is re-provisioned or formatted from scratch:

1. Clone `homelab-infra` onto the VPS.
2. Run automated provisioning:
   ```bash
   K3_TYPE=k3s K3S_NODE_IP=<vps-ip> make create
   ```
3. Restore SSH deploy keys:
   ```bash
   make repo-secret
   ```
4. Restore application secrets to Vault:
   ```bash
   ./scripts/vault.sh put platform ghcr-token .dockerconfigjson="<b64>"
   ./scripts/vault.sh put cloudflare tunnel TUNNEL_TOKEN="<token>"
   # Restore app secrets:
   ./scripts/vault.sh put my-service database host=... user=... password=... name=...
   ```
5. Argo CD automatically reads `clusters/local/`, creates the platform apps, discovers all apps in `clusters/local/apps/*.yaml`, and brings the entire cluster to the desired state.

#### Scenario 2: TLS Certificate Invalidation or k3s SAN Failure

If `kubectl` reports `x509: certificate is valid for ..., not <HOST>`:
1. Verify `/etc/rancher/k3s/config.yaml` has the expected hostnames under `tls-san`:
   ```bash
   cat /etc/rancher/k3s/config.yaml
   ```
2. Add the missing hostname or IP.
3. Restart k3s:
   ```bash
   sudo systemctl restart k3s
   ```
4. Regenerate local workstation credentials:
   ```bash
   SERVER=<host> REMOTE_HOST=root@<vps-ip> make access
   ```
