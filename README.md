# homelab-infra

GitOps base for `k3d` + `Argo CD`.

## Structure

```text
bootstrap/
  argocd/
clusters/
  local/
apps/
  platform/
charts/
manifests/
  common/
```

## Flow

1. Bring up the cluster with `k3d`.
2. Apply the `Argo CD` bootstrap.
3. `Argo CD` starts reconciling the rest of the repository.
4. Platform components live under `apps/platform`.
5. Ad hoc resources live under `manifests`.
