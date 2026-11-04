#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
CONTEXT_NAME=""
USER_NAME=""
SERVER="${SERVER:-${K3S_ENDPOINT:-${K3S_NODE_IP:-127.0.0.1}}}"
REMOTE_HOST="${REMOTE_HOST:-}"
SOURCE_FILE="${SOURCE_FILE:-}"
OUTPUT_FILE=""
DO_MERGE=false
SWITCH_CONTEXT=true
SKIP_VALIDATION=false
DRY_RUN=false

show_usage() {
  cat <<'EOF'
Usage: setup-access.sh [OPTIONS]

Configure persistent and resilient local kubectl access to a k3s cluster
without requiring background SSH tunnels.

Options:
  -s, --server <HOST|IP|URL>   k3s API address (default: $SERVER, $K3S_NODE_IP, or 127.0.0.1)
  -r, --remote-host <SSH_HOST> Fetch /etc/rancher/k3s/k3s.yaml via SSH (e.g. root@187.77.241.62)
  -f, --source <PATH>          Source k3s.yaml file path or '-' for stdin
  -o, --output <PATH>          Target kubeconfig path (default: ~/.kube/config-k3s-<cluster>)
  -c, --cluster-name <NAME>    Cluster name in kubeconfig (default: homelab)
      --context <NAME>         Context name in kubeconfig (default: k3s-<cluster>)
  -m, --merge                  Safely merge cluster into ~/.kube/config
      --no-switch-context      Do not switch active context when merging
  -n, --skip-validation        Skip connection test (cluster-info and get nodes)
      --dry-run                Print generated kubeconfig without saving
  -h, --help                   Show this help message

Examples:
  # Configure access via public IP / domain with TLS SAN:
  ./scripts/setup-access.sh --remote-host root@187.77.241.62 --server k8s.sputinik.tech

  # Configure access via Tailscale mesh IP:
  ./scripts/setup-access.sh --remote-host root@187.77.241.62 --server 100.64.0.5

  # Run locally on the k3s server node:
  ./scripts/setup-access.sh --server 187.77.241.62 --merge
EOF
}

normalize_server_url() {
  local raw="$1"
  local url="$raw"

  if [[ "$url" =~ ^https?:// ]]; then
    url="${url#*://}"
  fi

  if [[ "$url" != *:* ]]; then
    url="${url}:6443"
  fi

  echo "https://${url}"
}

extract_credential() {
  local key="$1"
  local content="$2"
  echo "$content" | awk -v k="$key" '$1 == k { print $2; exit }'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--server)
        SERVER="$2"
        shift 2
        ;;
      -r|--remote-host)
        REMOTE_HOST="$2"
        shift 2
        ;;
      -f|--source)
        SOURCE_FILE="$2"
        shift 2
        ;;
      -o|--output)
        OUTPUT_FILE="$2"
        shift 2
        ;;
      -c|--cluster-name)
        CLUSTER_NAME="$2"
        shift 2
        ;;
      --context)
        CONTEXT_NAME="$2"
        shift 2
        ;;
      -m|--merge)
        DO_MERGE=true
        shift
        ;;
      --no-switch-context)
        SWITCH_CONTEXT=false
        shift
        ;;
      -n|--skip-validation)
        SKIP_VALIDATION=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        show_usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "$CONTEXT_NAME" ]]; then
    CONTEXT_NAME="k3s-${CLUSTER_NAME}"
  fi
  USER_NAME="${CLUSTER_NAME}-admin"

  if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="${HOME}/.kube/config-k3s-${CLUSTER_NAME}"
  fi
}

load_source_config() {
  local raw_config=""

  if [[ -n "$SOURCE_FILE" ]]; then
    if [[ "$SOURCE_FILE" == "-" ]]; then
      raw_config="$(cat)"
    elif [[ -f "$SOURCE_FILE" ]]; then
      raw_config="$(cat "$SOURCE_FILE")"
    else
      echo "Error: source file '$SOURCE_FILE' does not exist." >&2
      exit 1
    fi
  elif [[ -n "$REMOTE_HOST" ]]; then
    if ! command -v ssh >/dev/null 2>&1; then
      echo "Error: 'ssh' is required to fetch remote kubeconfig." >&2
      exit 1
    fi
    raw_config="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE_HOST" "sudo cat /etc/rancher/k3s/k3s.yaml" 2>/dev/null)" || {
      raw_config="$(ssh "$REMOTE_HOST" "sudo cat /etc/rancher/k3s/k3s.yaml")"
    }
  elif [[ -f "/etc/rancher/k3s/k3s.yaml" ]]; then
    if [[ -r "/etc/rancher/k3s/k3s.yaml" ]]; then
      raw_config="$(cat /etc/rancher/k3s/k3s.yaml)"
    else
      raw_config="$(sudo cat /etc/rancher/k3s/k3s.yaml)"
    fi
  else
    echo "Error: no source kubeconfig found." >&2
    echo "Provide --source <path>, --remote-host <host>, or run on the k3s server directly." >&2
    exit 1
  fi

  echo "$raw_config"
}

build_kubeconfig() {
  local raw_yaml="$1"
  local target_server="$2"

  local ca_data client_cert client_key
  ca_data="$(extract_credential "certificate-authority-data:" "$raw_yaml")"
  client_cert="$(extract_credential "client-certificate-data:" "$raw_yaml")"
  client_key="$(extract_credential "client-key-data:" "$raw_yaml")"

  if [[ -z "$ca_data" || -z "$client_cert" || -z "$client_key" ]]; then
    echo "Error: failed to extract cluster credentials from source kubeconfig." >&2
    exit 1
  fi

  cat <<EOF
apiVersion: v1
kind: Config
preferences: {}
clusters:
- cluster:
    certificate-authority-data: ${ca_data}
    server: ${target_server}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${USER_NAME}
  name: ${CONTEXT_NAME}
current-context: ${CONTEXT_NAME}
users:
- name: ${USER_NAME}
  user:
    client-certificate-data: ${client_cert}
    client-key-data: ${client_key}
EOF
}

merge_into_main_config() {
  local new_config_path="$1"
  local main_config="${HOME}/.kube/config"

  mkdir -p "${HOME}/.kube"

  if [[ ! -f "$main_config" ]]; then
    cp "$new_config_path" "$main_config"
    chmod 600 "$main_config"
    return 0
  fi

  local tmp_merged
  tmp_merged="$(mktemp "${HOME}/.kube/config.tmp.XXXXXX")"
  KUBECONFIG="${main_config}:${new_config_path}" kubectl config view --flatten > "$tmp_merged"
  chmod 600 "$tmp_merged"
  mv "$tmp_merged" "$main_config"

  if [[ "$SWITCH_CONTEXT" == "true" ]]; then
    kubectl config use-context "$CONTEXT_NAME" --kubeconfig "$main_config" >/dev/null
  fi
}

validate_cluster_access() {
  local kubeconfig_path="$1"
  local target_server="$2"

  echo "Verifying cluster connectivity at ${target_server}..."
  if kubectl --kubeconfig "$kubeconfig_path" cluster-info --request-timeout=10s >/dev/null 2>&1; then
    echo "Connection verified successfully."
    kubectl --kubeconfig "$kubeconfig_path" get nodes
  else
    echo "Warning: connection failed to k3s API at ${target_server}" >&2
    echo "Troubleshooting steps:" >&2
    echo "  1. Check k3s status on host: sudo systemctl status k3s" >&2
    echo "  2. Confirm firewall allows port 6443: sudo ufw status" >&2
    echo "  3. Verify TLS SANs in /etc/rancher/k3s/config.yaml include '${SERVER}'" >&2
    echo "  4. If using Tailscale / VPN, verify connection: tailscale status" >&2
    return 1
  fi
}

main() {
  parse_args "$@"

  local server_url
  server_url="$(normalize_server_url "$SERVER")"

  local raw_config
  raw_config="$(load_source_config)"

  local formatted_config
  formatted_config="$(build_kubeconfig "$raw_config" "$server_url")"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$formatted_config"
    return 0
  fi

  mkdir -p "$(dirname "$OUTPUT_FILE")"
  echo "$formatted_config" > "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
  echo "Wrote cluster kubeconfig to: ${OUTPUT_FILE}"

  if [[ "$DO_MERGE" == "true" ]]; then
    merge_into_main_config "$OUTPUT_FILE"
    echo "Merged context '${CONTEXT_NAME}' into ~/.kube/config"
  fi

  if [[ "$SKIP_VALIDATION" != "true" ]]; then
    validate_cluster_access "$OUTPUT_FILE" "$server_url"
  fi

  echo ""
  echo "k3s API access configured successfully."
  echo "To use this context directly:"
  echo "  export KUBECONFIG=${OUTPUT_FILE}"
  echo "  kubectl get nodes"
}

main "$@"
