#!/usr/bin/env bash
set -euo pipefail

AUTH_KEY=""
HOSTNAME_ARG="homelab-vps"
ADVERTISE_ROUTES=""
ACCEPT_ROUTES=false
ENABLE_SSH=false
CONFIGURE_K3S_SAN=false
RESTART_K3S=false
DRY_RUN=false
CHECK_STATUS=false

show_usage() {
  cat <<'EOF'
Usage: setup-tailscale.sh [OPTIONS]

Install and configure Tailscale on the k3s server node for secure,
persistent mesh VPN access to the Kubernetes API without public port exposure.

Options:
  -k, --auth-key <KEY>         Tailscale authentication key (tskey-auth-...)
      --hostname <NAME>        Tailscale device name (default: homelab-vps)
      --advertise-routes <CIDR> Subnet routes to advertise (e.g. 10.42.0.0/16,10.43.0.0/16)
      --accept-routes          Accept advertised routes from other peers
      --ssh                    Enable Tailscale SSH
      --configure-k3s-san      Append Tailscale IP and hostname to /etc/rancher/k3s/config.yaml
      --restart-k3s            Restart k3s service after updating TLS SAN
      --status                 Print current Tailscale connection info and assigned IP
      --dry-run                Print commands without making system changes
  -h, --help                   Show this help message

Examples:
  # Authenticate with an ephemeral or pre-auth key:
  sudo ./scripts/setup-tailscale.sh --auth-key tskey-auth-sample --configure-k3s-san

  # Interactive authentication:
  sudo ./scripts/setup-tailscale.sh --hostname homelab-vps --configure-k3s-san

  # Check assigned Tailscale IP:
  ./scripts/setup-tailscale.sh --status
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -k|--auth-key)
        AUTH_KEY="$2"
        shift 2
        ;;
      --hostname)
        HOSTNAME_ARG="$2"
        shift 2
        ;;
      --advertise-routes)
        ADVERTISE_ROUTES="$2"
        shift 2
        ;;
      --accept-routes)
        ACCEPT_ROUTES=true
        shift
        ;;
      --ssh)
        ENABLE_SSH=true
        shift
        ;;
      --configure-k3s-san)
        CONFIGURE_K3S_SAN=true
        shift
        ;;
      --restart-k3s)
        RESTART_K3S=true
        shift
        ;;
      --status)
        CHECK_STATUS=true
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
}

ensure_installed() {
  if command -v tailscale >/dev/null 2>&1; then
    return 0
  fi

  echo "Tailscale is not installed. Installing via official script..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] curl -fsSL https://tailscale.com/install.sh | sh"
    return 0
  fi

  curl -fsSL https://tailscale.com/install.sh | sh
}

configure_k3s_tls_san() {
  local ts_ip="$1"
  local config_file="/etc/rancher/k3s/config.yaml"

  echo "Configuring k3s TLS SAN with Tailscale address..."

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Add ${ts_ip} and ${HOSTNAME_ARG} to ${config_file}"
    return 0
  fi

  mkdir -p /etc/rancher/k3s

  if [[ ! -f "$config_file" ]]; then
    cat <<EOF > "$config_file"
tls-san:
  - "${ts_ip}"
  - "${HOSTNAME_ARG}"
EOF
    echo "Created ${config_file} with TLS SAN entries."
  else
    if grep -qF "$ts_ip" "$config_file"; then
      echo "Tailscale IP ${ts_ip} already present in ${config_file}."
    else
      if ! grep -q "^tls-san:" "$config_file"; then
        printf "\ntls-san:\n" >> "$config_file"
      fi
      printf "  - \"%s\"\n  - \"%s\"\n" "$ts_ip" "$HOSTNAME_ARG" >> "$config_file"
      echo "Appended ${ts_ip} and ${HOSTNAME_ARG} to ${config_file}."
    fi
  fi

  if [[ "$RESTART_K3S" == "true" ]]; then
    echo "Restarting k3s service to regenerate certificates with new SANs..."
    systemctl restart k3s
  else
    echo "Notice: Remember to run 'sudo systemctl restart k3s' to apply new TLS SANs."
  fi
}

main() {
  parse_args "$@"

  if [[ "$CHECK_STATUS" == "true" ]]; then
    if ! command -v tailscale >/dev/null 2>&1; then
      echo "Tailscale is not installed."
      exit 1
    fi
    tailscale status || true
    local current_ip
    current_ip="$(tailscale ip -4 2>/dev/null || echo "unassigned")"
    echo "Tailscale IPv4: ${current_ip}"
    exit 0
  fi

  ensure_installed

  local up_cmd=(tailscale up --hostname="$HOSTNAME_ARG")

  if [[ -n "$AUTH_KEY" ]]; then
    up_cmd+=(--auth-key="$AUTH_KEY")
  fi

  if [[ -n "$ADVERTISE_ROUTES" ]]; then
    up_cmd+=(--advertise-routes="$ADVERTISE_ROUTES")
  fi

  if [[ "$ACCEPT_ROUTES" == "true" ]]; then
    up_cmd+=(--accept-routes)
  fi

  if [[ "$ENABLE_SSH" == "true" ]]; then
    up_cmd+=(--ssh)
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] systemctl enable --now tailscaled"
    echo "[DRY-RUN] ${up_cmd[*]}"
    if [[ "$CONFIGURE_K3S_SAN" == "true" ]]; then
      configure_k3s_tls_san "100.64.0.1"
    fi
    return 0
  fi

  systemctl enable --now tailscaled
  "${up_cmd[@]}"

  local assigned_ip
  assigned_ip="$(tailscale ip -4)"
  echo "Tailscale is connected. Assigned IPv4: ${assigned_ip}"

  if [[ "$CONFIGURE_K3S_SAN" == "true" ]]; then
    configure_k3s_tls_san "$assigned_ip"
  fi

  echo ""
  echo "Setup complete. Configure client workstation access:"
  echo "  ./scripts/setup-access.sh --server ${assigned_ip}"
}

main "$@"
