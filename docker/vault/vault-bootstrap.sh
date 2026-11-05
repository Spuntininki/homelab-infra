#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
VAULT_BACKEND="${VAULT_BACKEND:-auto}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
CLUSTER_NAME="${CLUSTER_NAME:-homelab}"

export VAULT_ADDR VAULT_TOKEN

detect_backend() {
  if [ "${VAULT_BACKEND}" != "auto" ]; then
    case "${VAULT_BACKEND}" in
      docker|cli|api)
        echo "${VAULT_BACKEND}"
        return 0
        ;;
      *)
        echo "Error: Unknown VAULT_BACKEND '${VAULT_BACKEND}'. Must be auto, docker, cli, or api." >&2
        return 1
        ;;
    esac
  fi

  if [[ "${VAULT_ADDR}" != *"127.0.0.1"* && "${VAULT_ADDR}" != *"localhost"* && "${VAULT_ADDR}" != *"0.0.0.0"* ]]; then
    if command -v vault >/dev/null 2>&1; then
      echo "cli"
      return 0
    elif command -v curl >/dev/null 2>&1; then
      echo "api"
      return 0
    fi
  fi

  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${VAULT_CONTAINER}"; then
    echo "docker"
    return 0
  fi

  if command -v vault >/dev/null 2>&1; then
    echo "cli"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    echo "api"
    return 0
  fi

  echo "Error: No suitable Vault client found. Need running '${VAULT_CONTAINER}' container, 'vault' CLI, or 'curl'." >&2
  return 1
}

BACKEND=$(detect_backend)

echo "==> Aguardando Vault ficar pronto em ${VAULT_ADDR} (backend: ${BACKEND})..."
for i in {1..30}; do
  READY=0
  case "${BACKEND}" in
    docker)
      if docker exec -e VAULT_ADDR="${VAULT_ADDR}" "${VAULT_CONTAINER}" vault status >/dev/null 2>&1; then
        READY=1
      fi
      ;;
    cli)
      if VAULT_ADDR="${VAULT_ADDR}" vault status >/dev/null 2>&1; then
        READY=1
      fi
      ;;
    api)
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || true)
      if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "429" ]; then
        READY=1
      fi
      ;;
  esac

  if [ "${READY}" -eq 1 ]; then
    echo "==> Vault pronto."
    break
  fi
  echo "    Tentativa ${i}/30..."
  sleep 2
done

if [ "${READY:-0}" -ne 1 ]; then
  echo "==> ERRO: Vault não ficou pronto a tempo." >&2
  exit 1
fi

echo "==> Habilitando KV v2 em 'secret/'..."
case "${BACKEND}" in
  docker)
    docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
      vault secrets enable -path=secret -version=2 kv 2>/dev/null || true
    ;;
  cli)
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
      vault secrets enable -path=secret -version=2 kv 2>/dev/null || true
    ;;
  api)
    MOUNTS=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/mounts" 2>/dev/null || true)
    if ! echo "${MOUNTS}" | grep -q '"secret/":'; then
      curl -s -f -X POST "${VAULT_ADDR}/v1/sys/mounts/secret" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"type":"kv","options":{"version":"2"}}' >/dev/null 2>&1 || true
    fi
    ;;
esac

echo "==> Criando policy 'external-secrets-policy'..."
POLICY_CONTENT='path "secret/data/*" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}'

case "${BACKEND}" in
  docker)
    printf '%s\n' "${POLICY_CONTENT}" | docker exec -i -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
      vault policy write external-secrets-policy -
    ;;
  cli)
    printf '%s\n' "${POLICY_CONTENT}" | VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
      vault policy write external-secrets-policy -
    ;;
  api)
    POLICY_PAYLOAD=$(python3 -c '
import sys, json
print(json.dumps({"policy": sys.stdin.read()}))
' <<< "${POLICY_CONTENT}")
    curl -s -f -X PUT "${VAULT_ADDR}/v1/sys/policies/acl/external-secrets-policy" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${POLICY_PAYLOAD}" >/dev/null
    ;;
esac

echo "==> Habilitando auth engine 'kubernetes'..."
case "${BACKEND}" in
  docker)
    AUTH_LIST=$(docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" vault auth list 2>/dev/null || true)
    if ! echo "${AUTH_LIST}" | grep -q '^kubernetes/'; then
      docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" vault auth enable kubernetes
    fi
    ;;
  cli)
    AUTH_LIST=$(VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" vault auth list 2>/dev/null || true)
    if ! echo "${AUTH_LIST}" | grep -q '^kubernetes/'; then
      VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" vault auth enable kubernetes
    fi
    ;;
  api)
    AUTH_LIST=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/auth" 2>/dev/null || true)
    if ! echo "${AUTH_LIST}" | grep -q '"kubernetes/":'; then
      curl -s -f -X POST "${VAULT_ADDR}/v1/sys/auth/kubernetes" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"type":"kubernetes"}' >/dev/null
    fi
    ;;
esac

echo "==> Configurando auth engine 'kubernetes'..."
if [ -z "${KUBERNETES_HOST:-}" ]; then
  if [ -n "${K3S_NODE_IP:-}" ]; then
    KUBERNETES_HOST="https://${K3S_NODE_IP}:6443"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "k3d-${CLUSTER_NAME}-server"; then
    KUBERNETES_HOST="https://k3d-${CLUSTER_NAME}-server-0:6443"
  else
    VAULT_HOST=$(echo "${VAULT_ADDR}" | sed -E 's|^https?://||; s|:[0-9]+$||; s|/.*$||')
    if [[ "${VAULT_HOST}" != "127.0.0.1" && "${VAULT_HOST}" != "localhost" && "${VAULT_HOST}" != "0.0.0.0" && -n "${VAULT_HOST}" ]]; then
      KUBERNETES_HOST="https://${VAULT_HOST}:6443"
    elif command -v kubectl >/dev/null 2>&1; then
      NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
      if [ -n "${NODE_IP}" ]; then
        KUBERNETES_HOST="https://${NODE_IP}:6443"
      else
        KUBERNETES_HOST="https://kubernetes.default.svc:443"
      fi
    else
      KUBERNETES_HOST="https://187.77.241.62:6443"
    fi
  fi
fi

K8S_CA_CERT="${K8S_CA_CERT:-}"
if [ -z "${K8S_CA_CERT}" ] && command -v kubectl >/dev/null 2>&1; then
  K8S_CA_CERT=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -z "${K8S_CA_CERT}" ]; then
    CA_FILE=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)
    if [ -n "${CA_FILE}" ] && [ -f "${CA_FILE}" ]; then
      K8S_CA_CERT=$(cat "${CA_FILE}")
    fi
  fi
fi

case "${BACKEND}" in
  docker)
    CONFIG_ARGS=("kubernetes_host=${KUBERNETES_HOST}" "disable_iss_validation=true")
    if [ -n "${K8S_CA_CERT}" ]; then
      printf '%s\n' "${K8S_CA_CERT}" | docker exec -i "${VAULT_CONTAINER}" tee /tmp/k8s-ca.crt >/dev/null
      CONFIG_ARGS+=("kubernetes_ca_cert=@/tmp/k8s-ca.crt")
    fi
    if [ -n "${TOKEN_REVIEWER_JWT:-}" ]; then
      CONFIG_ARGS+=("token_reviewer_jwt=${TOKEN_REVIEWER_JWT}")
    fi
    docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
      vault write auth/kubernetes/config "${CONFIG_ARGS[@]}"
    docker exec "${VAULT_CONTAINER}" rm -f /tmp/k8s-ca.crt >/dev/null 2>&1 || true
    ;;
  cli)
    CONFIG_ARGS=("kubernetes_host=${KUBERNETES_HOST}" "disable_iss_validation=true")
    TMP_CA=""
    if [ -n "${K8S_CA_CERT}" ]; then
      TMP_CA=$(mktemp)
      printf '%s\n' "${K8S_CA_CERT}" > "${TMP_CA}"
      CONFIG_ARGS+=("kubernetes_ca_cert=@${TMP_CA}")
    fi
    if [ -n "${TOKEN_REVIEWER_JWT:-}" ]; then
      CONFIG_ARGS+=("token_reviewer_jwt=${TOKEN_REVIEWER_JWT}")
    fi
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
      vault write auth/kubernetes/config "${CONFIG_ARGS[@]}"
    if [ -n "${TMP_CA}" ]; then
      rm -f "${TMP_CA}"
    fi
    ;;
  api)
    CONFIG_PAYLOAD=$(python3 -c '
import sys, json

host = sys.argv[1]
ca_cert = sys.argv[2]
jwt = sys.argv[3] if len(sys.argv) > 3 else ""

data = {
    "kubernetes_host": host,
    "disable_iss_validation": True
}
if ca_cert:
    data["kubernetes_ca_cert"] = ca_cert
if jwt:
    data["token_reviewer_jwt"] = jwt

print(json.dumps(data))
' "${KUBERNETES_HOST}" "${K8S_CA_CERT}" "${TOKEN_REVIEWER_JWT:-}")
    curl -s -f -X POST "${VAULT_ADDR}/v1/auth/kubernetes/config" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${CONFIG_PAYLOAD}" >/dev/null
    ;;
esac

echo "==> Configurando role 'external-secrets' no auth/kubernetes..."
case "${BACKEND}" in
  docker)
    docker exec -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
      vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets \
        bound_service_account_namespaces=external-secrets \
        policies=external-secrets-policy \
        ttl=1h
    ;;
  cli)
    VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
      vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets \
        bound_service_account_namespaces=external-secrets \
        policies=external-secrets-policy \
        ttl=1h
    ;;
  api)
    ROLE_PAYLOAD='{
      "bound_service_account_names": ["external-secrets"],
      "bound_service_account_namespaces": ["external-secrets"],
      "policies": ["external-secrets-policy"],
      "ttl": "1h"
    }'
    curl -s -f -X POST "${VAULT_ADDR}/v1/auth/kubernetes/role/external-secrets" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${ROLE_PAYLOAD}" >/dev/null
    ;;
esac

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
