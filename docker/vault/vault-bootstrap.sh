#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}
VAULT_TOKEN=${VAULT_TOKEN:-root}

export VAULT_ADDR VAULT_TOKEN

echo "==> Aguardando Vault ficar pronto em ${VAULT_ADDR}..."
for i in {1..30}; do
  if docker exec vault vault status >/dev/null 2>&1; then
    echo "==> Vault pronto."
    break
  fi
  echo "    Tentativa ${i}/30..."
  sleep 2
done

if ! docker exec vault vault status >/dev/null 2>&1; then
  echo "==> ERRO: Vault não ficou pronto a tempo." >&2
  exit 1
fi

echo "==> Habilitando KV v2 em 'secret/'..."
docker exec -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault secrets enable -path=secret -version=2 kv || true

echo "==> Criando policy 'external-secrets-policy'..."
docker exec -i -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault policy write external-secrets-policy - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
EOF

echo "==> Criando token para o External Secrets Operator..."
ESO_TOKEN=$(docker exec -e VAULT_TOKEN="${VAULT_TOKEN}" vault vault token create \
  -policy=external-secrets-policy \
  -display-name=external-secrets \
  -no-default-policy \
  -field=client_token)

mkdir -p "${SCRIPT_DIR}"
printf '%s' "${ESO_TOKEN}" > "${SCRIPT_DIR}/eso-token.txt"
chmod 600 "${SCRIPT_DIR}/eso-token.txt"

echo "==> Token salvo em: ${SCRIPT_DIR}/eso-token.txt"
echo "==> Para aplicar no cluster, execute:"
echo "     kubectl create secret generic vault-token -n external-secrets --from-literal=token=\$(cat ${SCRIPT_DIR}/eso-token.txt) --dry-run=client -o yaml | kubectl apply -f -"
