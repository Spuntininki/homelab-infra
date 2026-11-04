#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
VAULT_BACKEND="${VAULT_BACKEND:-auto}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
VAULT_MOUNT="${VAULT_MOUNT:-secret}"

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

normalize_path() {
  local app="$1"
  local secret_name="${2:-}"

  local base_path
  if [[ "$app" == "${VAULT_MOUNT}/"* ]]; then
    base_path="${app#${VAULT_MOUNT}/}"
  elif [[ "$app" == "${VAULT_MOUNT}" ]]; then
    base_path=""
  else
    base_path="$app"
  fi

  if [ -n "$secret_name" ]; then
    if [ -n "$base_path" ]; then
      echo "${base_path}/${secret_name}"
    else
      echo "${secret_name}"
    fi
  else
    echo "${base_path}"
  fi
}

cmd_put() {
  if [ $# -lt 3 ]; then
    echo "Error: 'put' requires <app>, <secret_name>, and at least one KEY=VAL pair." >&2
    echo "Usage: $0 put <app> <secret_name> KEY=VAL [KEY2=VAL2...]" >&2
    exit 1
  fi

  local app="$1"
  local secret_name="$2"
  shift 2

  local path
  path=$(normalize_path "$app" "$secret_name")

  for pair in "$@"; do
    if [[ "$pair" != *=* ]]; then
      echo "Error: Invalid key-value argument '$pair'. Expected format: KEY=VALUE" >&2
      exit 1
    fi
  done

  local backend
  backend=$(detect_backend)

  case "$backend" in
    docker)
      docker exec -i -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
        vault kv put "${VAULT_MOUNT}/${path}" "$@"
      ;;
    cli)
      VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" vault kv put "${VAULT_MOUNT}/${path}" "$@"
      ;;
    api)
      local payload
      payload=$(python3 -c '
import sys, json
data = {}
for arg in sys.argv[1:]:
    k, v = arg.split("=", 1)
    data[k] = v
print(json.dumps({"data": data}))
' "$@")

      local resp_file
      resp_file=$(mktemp)
      local http_code
      http_code=$(curl -s -o "${resp_file}" -w "%{http_code}" -X POST "${VAULT_ADDR}/v1/${VAULT_MOUNT}/data/${path}" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}")

      if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        echo "Error: Vault API request failed with HTTP ${http_code}" >&2
        cat "${resp_file}" >&2
        rm -f "${resp_file}"
        exit 1
      fi
      rm -f "${resp_file}"
      echo "Secret stored at ${VAULT_MOUNT}/${path}"
      ;;
  esac
}

cmd_get() {
  local app=""
  local secret_name=""
  local format="json"
  local key=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --format|-f)
        if [ $# -lt 2 ]; then
          echo "Error: --format requires an argument (json, kv, or raw)" >&2
          exit 1
        fi
        format="$2"
        shift 2
        ;;
      --format=*)
        format="${1#--format=}"
        shift
        ;;
      --key|-k)
        if [ $# -lt 2 ]; then
          echo "Error: --key requires an argument" >&2
          exit 1
        fi
        key="$2"
        shift 2
        ;;
      --key=*)
        key="${1#--key=}"
        shift
        ;;
      --json)
        format="json"
        shift
        ;;
      --kv)
        format="kv"
        shift
        ;;
      --raw)
        format="raw"
        shift
        ;;
      -*)
        echo "Error: Unknown option for get: $1" >&2
        exit 1
        ;;
      *)
        if [ -z "$app" ]; then
          app="$1"
        elif [ -z "$secret_name" ]; then
          secret_name="$1"
        elif [ -z "$key" ]; then
          key="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [ -z "$app" ] || [ -z "$secret_name" ]; then
    echo "Error: 'get' requires <app> and <secret_name>." >&2
    echo "Usage: $0 get <app> <secret_name> [--format json|kv|raw] [--key KEY]" >&2
    exit 1
  fi

  local path
  path=$(normalize_path "$app" "$secret_name")

  local backend
  backend=$(detect_backend)

  local raw_output
  case "$backend" in
    docker)
      raw_output=$(docker exec -i -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
        vault kv get -format=json "${VAULT_MOUNT}/${path}")
      ;;
    cli)
      raw_output=$(VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
        vault kv get -format=json "${VAULT_MOUNT}/${path}")
      ;;
    api)
      local resp_file
      resp_file=$(mktemp)
      local http_code
      http_code=$(curl -s -o "${resp_file}" -w "%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/${VAULT_MOUNT}/data/${path}")

      if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        echo "Error: Vault API request failed with HTTP ${http_code}" >&2
        cat "${resp_file}" >&2
        rm -f "${resp_file}"
        exit 1
      fi
      raw_output=$(cat "${resp_file}")
      rm -f "${resp_file}"
      ;;
  esac

  python3 -c '
import sys, json

try:
    obj = json.loads(sys.argv[1])
except Exception as e:
    sys.stderr.write(f"Error parsing Vault JSON response: {e}\n")
    sys.exit(1)

data = obj.get("data", {})
if isinstance(data, dict) and "data" in data and isinstance(data["data"], dict):
    data = data["data"]

fmt = sys.argv[2]
target_key = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

if target_key:
    if target_key in data:
        print(data[target_key])
    else:
        sys.stderr.write(f"Error: Key \"{target_key}\" not found in secret\n")
        sys.exit(1)
elif fmt == "kv":
    for k in sorted(data.keys()):
        print(f"{k}={data[k]}")
elif fmt == "raw":
    print(json.dumps(obj, indent=2))
else:
    print(json.dumps(data, indent=2))
' "$raw_output" "$format" "$key"
}

cmd_list() {
  local target_path=""
  local format="text"

  while [ $# -gt 0 ]; do
    case "$1" in
      --json)
        format="json"
        shift
        ;;
      -*)
        echo "Error: Unknown option for list: $1" >&2
        exit 1
        ;;
      *)
        if [ -z "$target_path" ]; then
          target_path="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  local subpath
  subpath=$(normalize_path "$target_path")

  local full_vault_path
  if [ -n "$subpath" ]; then
    full_vault_path="${VAULT_MOUNT}/${subpath}"
  else
    full_vault_path="${VAULT_MOUNT}"
  fi

  local backend
  backend=$(detect_backend)

  local raw_output
  case "$backend" in
    docker)
      raw_output=$(docker exec -i -e VAULT_ADDR="${VAULT_ADDR}" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" \
        vault kv list -format=json "${full_vault_path}" 2>/dev/null || echo "[]")
      ;;
    cli)
      raw_output=$(VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" \
        vault kv list -format=json "${full_vault_path}" 2>/dev/null || echo "[]")
      ;;
    api)
      local api_path
      if [ -n "$subpath" ]; then
        api_path="${VAULT_MOUNT}/metadata/${subpath}?list=true"
      else
        api_path="${VAULT_MOUNT}/metadata?list=true"
      fi

      local resp_file
      resp_file=$(mktemp)
      local http_code
      http_code=$(curl -s -o "${resp_file}" -w "%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/${api_path}")

      if [ "$http_code" -eq 404 ]; then
        raw_output='{"data":{"keys":[]}}'
      elif [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        echo "Error: Vault API request failed with HTTP ${http_code}" >&2
        cat "${resp_file}" >&2
        rm -f "${resp_file}"
        exit 1
      else
        raw_output=$(cat "${resp_file}")
      fi
      rm -f "${resp_file}"
      ;;
  esac

  python3 -c '
import sys, json

try:
    obj = json.loads(sys.argv[1])
except Exception:
    obj = []

keys = []
if isinstance(obj, list):
    keys = obj
elif isinstance(obj, dict):
    data = obj.get("data", {})
    if isinstance(data, dict):
        keys = data.get("keys", [])
    elif isinstance(data, list):
        keys = data

fmt = sys.argv[2]
if fmt == "json":
    print(json.dumps(keys, indent=2))
else:
    for k in keys:
        print(k)
' "$raw_output" "$format"
}

cmd_generate_dockerconfig() {
  local username=""
  local token=""
  local server="ghcr.io"
  local store_app=""
  local store_secret=""
  local raw_output=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --server)
        if [ $# -lt 2 ]; then
          echo "Error: --server requires an argument" >&2
          exit 1
        fi
        server="$2"
        shift 2
        ;;
      --server=*)
        server="${1#--server=}"
        shift
        ;;
      --store|--save-to)
        if [ $# -lt 3 ]; then
          echo "Error: --store requires <app> and <secret_name>" >&2
          exit 1
        fi
        store_app="$2"
        store_secret="$3"
        shift 3
        ;;
      --raw)
        raw_output=1
        shift
        ;;
      -*)
        echo "Error: Unknown option for generate-dockerconfig: $1" >&2
        exit 1
        ;;
      *)
        if [ -z "$username" ]; then
          username="$1"
        elif [ -z "$token" ]; then
          token="$1"
        else
          echo "Error: Unexpected argument: $1" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [ -z "$username" ] || [ -z "$token" ]; then
    echo "Error: 'generate-dockerconfig' requires <username> and <token>." >&2
    echo "Usage: $0 generate-dockerconfig <username> <token> [--server <server>] [--store <app> <secret_name>] [--raw]" >&2
    exit 1
  fi

  local auth
  auth=$(printf '%s:%s' "$username" "$token" | base64 | tr -d '\r\n')

  local config_json
  config_json=$(python3 -c '
import sys, json
server = sys.argv[1]
username = sys.argv[2]
password = sys.argv[3]
auth = sys.argv[4]
config = {
    "auths": {
        server: {
            "username": username,
            "password": password,
            "auth": auth
        }
    }
}
print(json.dumps(config, indent=2))
' "$server" "$username" "$token" "$auth")

  local config_b64
  config_b64=$(printf '%s' "$config_json" | base64 | tr -d '\r\n')

  if [ -n "$store_app" ] && [ -n "$store_secret" ]; then
    cmd_put "$store_app" "$store_secret" \
      ".dockerconfigjson=${config_b64}" \
      "dockerconfigjson=${config_b64}"
    echo "Stored dockerconfigjson in ${VAULT_MOUNT}/${store_app}/${store_secret}"
    echo "Base64 value: ${config_b64}"
  elif [ "$raw_output" -eq 1 ]; then
    echo "$config_json"
  else
    echo "$config_b64"
  fi
}

usage() {
  cat <<'EOF'
Vault and Homelab Secret Management Helper

Usage:
  scripts/vault.sh <command> [arguments...]

Commands:
  put <app> <secret_name> KEY=VAL [KEY2=VAL2...]
      Store one or more key-value secrets under secret/<app>/<secret_name>.

  get <app> <secret_name> [--format json|kv|raw] [--key KEY]
      Retrieve secrets for <app>/<secret_name>. Defaults to clean JSON.

  list [path] [--json]
      List secret keys at the specified path (defaults to root: secret/).

  generate-dockerconfig <username> <token> [--server <registry>] [--store <app> <secret_name>] [--raw]
      Generate base64-encoded dockerconfigjson for container registries (default: ghcr.io).
      Optionally store directly into Vault with --store.

Environment Variables:
  VAULT_ADDR       Vault server address (default: http://127.0.0.1:8200)
  VAULT_TOKEN      Vault token (default: root)
  VAULT_BACKEND    Execution backend: auto, docker, cli, or api (default: auto)
  VAULT_CONTAINER  Docker container name for docker backend (default: vault)
  VAULT_MOUNT      KV secrets engine mount path (default: secret)

Options:
  -h, --help       Show this help message and exit
EOF
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

case "$1" in
  -h|--help|help)
    usage
    exit 0
    ;;
  put)
    shift
    cmd_put "$@"
    ;;
  get)
    shift
    cmd_get "$@"
    ;;
  list)
    shift
    cmd_list "$@"
    ;;
  generate-dockerconfig)
    shift
    cmd_generate_dockerconfig "$@"
    ;;
  *)
    echo "Error: Unknown command '$1'" >&2
    usage >&2
    exit 1
    ;;
esac
