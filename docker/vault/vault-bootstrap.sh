#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
VAULT_TOKEN=${VAULT_TOKEN:-root}

export VAULT_ADDR VAULT_TOKEN

cleanup_ca() {
  docker exec vault rm -f /tmp/k8s-ca.crt >/dev/null 2>&1 || true
}
trap cleanup_ca EXIT

echo "==> Aguardando Vault ficar pronto em ${VAULT_ADDR}..."
for i in {1..30}; do
  if docker exec -e VAULT_ADDR="${VAULT_ADDR}" vault vault status >/dev/null 2>&1; then
    echo "==> Vault pronto."
    break
  fi
  echo "    Tentativa ${i}/30..."
  sleep 2
done

if ! docker exec -e VAULT_ADDR="${VAULT_ADDR}" vault vault status >/dev/null 2>&1; then
  echo "==> ERRO: Vault não ficou pronto a tempo." >&2
  exit 1
fi

echo "==> Habilitando KV v2 em 'secret/'..."
docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault secrets enable -path=secret -version=2 kv || true

echo "==> Criando policy 'external-secrets-policy'..."
docker exec -i -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault policy write external-secrets-policy - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
EOF

echo "==> Habilitando auth engine 'kubernetes'..."
AUTH_LIST=$(docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault auth list 2>/dev/null || true)
if ! echo "${AUTH_LIST}" | grep -q '^kubernetes/'; then
  docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault auth enable kubernetes
fi

echo "==> Configurando auth engine 'kubernetes'..."
CLUSTER_NAME=${CLUSTER_NAME:-homelab}
if [ -z "${KUBERNETES_HOST:-}" ]; then
  if [ -n "${K3S_NODE_IP:-}" ]; then
    KUBERNETES_HOST="https://${K3S_NODE_IP}:6443"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "k3d-${CLUSTER_NAME}-server"; then
    KUBERNETES_HOST="https://k3d-${CLUSTER_NAME}-server-0:6443"
  else
    KUBERNETES_HOST="https://kubernetes.default.svc:443"
  fi
fi

K8S_CA_CERT=${K8S_CA_CERT:-}
if [ -z "${K8S_CA_CERT}" ] && command -v kubectl >/dev/null 2>&1; then
  K8S_CA_CERT=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -z "${K8S_CA_CERT}" ]; then
    CA_FILE=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)
    if [ -n "${CA_FILE}" ] && [ -f "${CA_FILE}" ]; then
      K8S_CA_CERT=$(cat "${CA_FILE}")
    fi
  fi
fi

VAULT_CONFIG_ARGS=("kubernetes_host=${KUBERNETES_HOST}" "disable_iss_validation=true")

if [ -n "${K8S_CA_CERT}" ]; then
  printf '%s\n' "${K8S_CA_CERT}" | docker exec -i vault tee /tmp/k8s-ca.crt >/dev/null
  VAULT_CONFIG_ARGS+=("kubernetes_ca_cert=@/tmp/k8s-ca.crt")
fi

if [ -n "${TOKEN_REVIEWER_JWT:-}" ]; then
  VAULT_CONFIG_ARGS+=("token_reviewer_jwt=${TOKEN_REVIEWER_JWT}")
fi

docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault write auth/kubernetes/config "${VAULT_CONFIG_ARGS[@]}"

cleanup_ca

echo "==> Configurando role 'external-secrets' no auth/kubernetes..."
docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  ttl=1h

if command -v kubectl >/dev/null 2>&1; then
  echo "==> Aplicando ClusterRoleBinding 'system:auth-delegator'..."
  kubectl create clusterrolebinding external-secrets-auth-delegator \
    --clusterrole=system:auth-delegator \
    --serviceaccount=external-secrets:external-secrets \
    --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
fi

mkdir -p "${SCRIPT_DIR}"
printf '%s' "kubernetes-auth" > "${SCRIPT_DIR}/eso-token.txt"
chmod 600 "${SCRIPT_DIR}/eso-token.txt"

echo "==> Vault configurado com sucesso com Kubernetes ServiceAccount auth."
