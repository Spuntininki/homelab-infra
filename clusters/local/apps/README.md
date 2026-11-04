# Automated Application Onboarding (`clusters/local/apps/`)

This directory is monitored by the Argo CD `ApplicationSet` (`apps/platform/argocd/applicationset.yaml`).

## How to Onboard a New Application

To deploy a new application into the homelab cluster:

1. Copy [`sample-app.yaml.example`](sample-app.yaml.example) to `<your-app-name>.yaml` in this directory:
   ```bash
   cp clusters/local/apps/sample-app.yaml.example clusters/local/apps/my-service.yaml
   ```

2. Edit `my-service.yaml` with your repository URL and target namespace:
   ```yaml
   name: my-service
   repoURL: git@github.com:Spuntininki/my-service.git
   targetRevision: HEAD
   path: deploy/k8s
   namespace: my-service
   ```

3. Commit and push:
   ```bash
   git add clusters/local/apps/my-service.yaml
   git commit -m "feat(apps): onboard my-service via ApplicationSet"
   git push origin <branch>
   ```

Argo CD automatically discovers the file, instantiates the `Application` resource with automated self-healing, ServerSideApply, and creates the target namespace.
