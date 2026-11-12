# Application Base Template (`app-base`)

A standardized, production-ready Kubernetes manifest template for deploying applications onto the homelab cluster. This template embeds all platform conventions, operational lessons learned, and security practices out of the box.

---

## ⚡ 5-Minute Quickstart

Follow these steps to scaffold and deploy a new service in under 5 minutes.

### 1. Copy Manifests to your Application Repository

Following the homelab convention (seen in `opus-askesis` and `imobimanager`), application manifests live in the application repository under `deploy/k8s/`:

```bash
mkdir -p deploy/k8s
cp -r /path/to/homelab-infra/templates/app-base/* deploy/k8s/
cd deploy/k8s/
```

*(Alternatively, consume `templates/app-base` directly as a remote Kustomize base—see [Kustomize Inheritance](#kustomize-inheritance) below).*

### 2. Customize Placeholders

Replace the following placeholder values across `deploy/k8s/`:

| Placeholder | Example Value | Target Files |
|---|---|---|
| `app-template` | `my-service` | All manifests, `dashboards/overview.json` |
| `ghcr.io/spuntininki/app-template:latest` | `ghcr.io/spuntininki/my-service:v1.0.0` | `deployment.yaml` |
| `app.sputinik.tech` | `my-service.sputinik.tech` | `ingress.yaml` |
| `secret/app-template/database` | `secret/my-service/database` | `external-secret.yaml` |

Quick search-and-replace command:

```bash
sed -i 's/app-template/my-service/g' *.yaml dashboards/*.json
sed -i 's/app\.sputinik\.tech/my-service.sputinik.tech/g' ingress.yaml
```

### 3. Provision Secrets in Vault

Create the database secret (and any required application secrets) in Vault:

```bash
docker exec -it vault vault kv put secret/my-service/database \
  host=postgres.database.svc.cluster.local \
  port=5432 \
  user=myuser \
  password='StrongP@ssw0rd!#$' \
  name=mydb
```

### 4. Register in Argo CD

Create `clusters/local/my-service-application.yaml` in `homelab-infra`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:Spuntininki/my-service.git
    targetRevision: HEAD
    path: deploy/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: my-service
  ignoreDifferences:
    - group: external-secrets.io
      kind: ExternalSecret
      jsonPointers:
        - /spec/target/template
        - /status
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Commit and push. Argo CD synchronizes the application, cert-manager issues the TLS certificate, and the service is live.

### 5. Access Grafana Dashboard & Verify Observability

The template includes out-of-the-box observability scaffolding:
- Prometheus pod scraping annotations in `deployment.yaml` (`prometheus.io/scrape: "true"`).
- A pre-configured Grafana dashboard in `dashboards/overview.json`.
- Automatic dashboard provisioning via Kustomize `configMapGenerator` labeled `grafana_dashboard: "1"`.

Once deployed, access Grafana at `https://grafana.sputinik.tech` and find the dashboard under **Dashboards** -> **Application Overview** (or search for your service name).

---

## 🏛️ Platform Conventions & Rationale

### 1. `enableServiceLinks: false`

- **Problem**: Kubernetes automatically injects environment variables for every active `Service` in the cluster or namespace (e.g. `POSTGRES_PORT="tcp://10.43.12.34:5432"`, `REDIS_PORT="tcp://10.43.56.78:6379"`). If your application expects a numeric port like `POSTGRES_PORT=5432`, the injected TCP socket URI collides with your environment variable and crashes the container at startup.
- **Solution**: `deployment.yaml` explicitly sets `enableServiceLinks: false` in the pod spec. Standard Kubernetes DNS service discovery (`my-service.namespace.svc.cluster.local`) is unaffected and continues to work normally.

### 2. Password URL-Encoding with Sprig (`urlquery`)

- **Problem**: Database passwords frequently contain reserved URL characters such as `@`, `#`, `!`, `:`, `/`, or `?`. When concatenating a connection string like `postgresql://user:pass@host:5432/db`, unencoded characters corrupt the connection URI and cause database connection failures.
- **Solution**: The `ExternalSecret` manifest uses External Secrets Operator `engineVersion: v2` with Sprig templating:
  ```yaml
  template:
    engineVersion: v2
    data:
      DATABASE_URL: "postgresql://{{ .db_user }}:{{ .db_password | urlquery }}@{{ .db_host }}:{{ .db_port }}/{{ .db_name }}"
  ```
  This guarantees that special characters in `db_password` are escaped safely for connection URIs while `DB_PASSWORD` preserves the raw unencoded string.

### 3. Traefik Ingress & Automatic TLS

- **Routing**: Configured with `traefik.ingress.kubernetes.io/router.entrypoints: websecure` to ensure HTTPS-only traffic on port 443.
- **Certificates**: Annotated with `cert-manager.io/cluster-issuer: letsencrypt-prod`. Cert-manager automatically obtains and renews certificates via ACME HTTP-01 challenges, storing the secret in `<app-name>-tls`.
- **IngressClass**: Explicitly set to `ingressClassName: traefik` matching the cluster controller.

### 4. External Secrets & Vault Integration

- **ClusterSecretStore**: Connects to the cluster-wide `vault-backend` ClusterSecretStore (authenticated via Kubernetes ServiceAccount).
- **Lifecycle**: `creationPolicy: Owner` and `deletionPolicy: Retain` ensure Kubernetes secrets are cleaned up if the application namespace is removed, while avoiding accidental secret deletion during rolling redeployments.
- **Argo CD Diffing**: External Secrets Operator populates defaulted fields in `spec.target.template`. Always specify `ignoreDifferences` in the Argo CD `Application` for `/spec/target/template` and `/status` to prevent false "Out of Sync" warnings.

### 5. Private Image Pulls (`registry-ghcr`)

- `deployment.yaml` preconfigures `imagePullSecrets: [{ name: registry-ghcr }]`.
- The homelab platform automatically replicates the `registry-ghcr` Docker credential across all application namespaces. Applications do not need to manage individual image pull secrets.

### 6. Baseline Compute Quotas & Health Probes

- **Resource Baseline**: Default requests are `cpu: 50m`, `memory: 64Mi`; default limits are `cpu: 200m`, `memory: 256Mi`. This fits comfortably within Hostinger VPS resources while preventing runaway memory leaks from triggering node-wide OOM kills.
- **Probes**: Configured for `/healthz` on the HTTP container port. Adjust paths to `/` or the application's actual health check endpoint as needed.

### 7. Observability: Prometheus Scraping & Automated Grafana Dashboard Provisioning

#### Pod Scraping Annotations
Standardized Prometheus scrape annotations are embedded directly into `deployment.yaml` (`spec.template.metadata.annotations`):
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```
- `prometheus.io/scrape: "true"`: Instructs the Prometheus scraper to scrape metrics from this pod.
- `prometheus.io/port: "8080"`: Points to the container's HTTP listening port where `/metrics` is served.
- `prometheus.io/path: "/metrics"`: Path to the Prometheus metrics endpoint.

#### Grafana Sidecar Discovery
The homelab's `kube-prometheus-stack` deployment runs Grafana with the KiwiGrid `k8s-sidecar` enabled (`searchNamespace: ALL`), configured to watch for ConfigMaps labeled `grafana_dashboard: "1"`.

In `kustomization.yaml`:
```yaml
configMapGenerator:
  - name: app-template-dashboard
    files:
      - dashboards/overview.json
    options:
      labels:
        grafana_dashboard: "1"
```
When this ConfigMap is synchronized into the cluster:
1. Grafana's sidecar controller immediately detects the `grafana_dashboard: "1"` label.
2. The sidecar extracts each file from the ConfigMap's `data` section (`dashboards/overview.json`) and writes it to Grafana's internal provisioning directory (`/tmp/dashboards/`).
3. Grafana automatically loads and serves the dashboard without requiring a pod restart or manual UI import.

#### Developer Workflow: Exporting & Customizing Dashboards
Developers can design dashboards in the Grafana UI and persist them in Git:

1. **Design & Iterate**: Open Grafana at `https://grafana.sputinik.tech` and build or modify panels (CPU, memory, custom business metrics).
2. **Parameterize Queries**: Use templated dashboard variables such as `$namespace` and `$app` (as defined in `dashboards/overview.json`) so the dashboard works across environments.
3. **Export Dashboard JSON**:
   - In Grafana, click the **Share** button (or **Dashboard Settings** -> **JSON Model**).
   - Select the **Export** tab and click **Save to file** (or copy the JSON Model text).
4. **Save to Repository**:
   - Place the exported JSON file in your repository under `deploy/k8s/dashboards/` (e.g. `deploy/k8s/dashboards/overview.json`).
5. **Register in Kustomize**:
   - Verify that `deploy/k8s/kustomization.yaml` has the `configMapGenerator` referencing the file with label `grafana_dashboard: "1"`.
6. **Commit & Deploy**:
   - Push to Git. Argo CD synchronizes the updated ConfigMap, and Grafana's sidecar picks up the changes in real-time.

---

## 🔀 Kustomize Inheritance

If you prefer inheriting from `templates/app-base/` rather than copying files, create a `kustomization.yaml` in your application repository that patches the base:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - https://github.com/Spuntininki/homelab-infra//templates/app-base?ref=main

namePrefix: my-service-
namespace: my-service

patches:
  - target:
      kind: Deployment
      name: app-template
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: ghcr.io/spuntininki/my-service:v1.0.0
  - target:
      kind: Ingress
      name: app-template
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: my-service.sputinik.tech
      - op: replace
        path: /spec/tls/0/hosts/0
        value: my-service.sputinik.tech
```

---

## 🧪 Verification

Validate the rendered manifests locally before committing:

```bash
# 1. Build manifests with Kustomize
kubectl kustomize templates/app-base/

# 2. Verify dashboard ConfigMap and labels
kubectl kustomize templates/app-base/ | grep -A 5 "grafana_dashboard: \"1\""

# 3. Dry-run validation against Kubernetes API schema
kubectl apply --dry-run=client -f templates/app-base/deployment.yaml -f templates/app-base/service.yaml -f templates/app-base/ingress.yaml
```
