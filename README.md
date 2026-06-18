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

## Local workflow

### Requirements

- `k3d` => `v5.9.0`
- `kubectl`=> `v1.35.4`

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
