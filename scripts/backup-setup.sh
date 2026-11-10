#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_SCRIPT="${VAULT_SCRIPT:-${SCRIPT_DIR}/vault.sh}"
RCLONE_CONFIG="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive}"
CRYPT_REMOTE="${CRYPT_REMOTE:-gdrive-crypt}"
CRYPT_REMOTE_PATH="${CRYPT_REMOTE_PATH:-${GDRIVE_REMOTE}:homelab-backup}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"
DRY_RUN="${DRY_RUN:-false}"
ACTION="setup"

show_usage() {
  cat <<'EOF'
Usage: backup-setup.sh [COMMAND] [OPTIONS]

Install and configure rclone on headless hosts and verify encrypted Google Drive backups.

Commands:
  setup           Install rclone (if missing) and generate configuration from Vault (default)
  install         Install rclone binary only
  configure       Generate rclone.conf from Vault secrets
  check           Run pre-flight connectivity check against gdrive and gdrive-crypt remotes

Options:
  -c, --config <PATH>          Target rclone.conf path (default: ~/.config/rclone/rclone.conf)
      --vault-script <PATH>    Path to vault.sh helper (default: scripts/vault.sh)
      --gdrive-remote <NAME>   Remote name for Google Drive (default: gdrive)
      --crypt-remote <NAME>    Remote name for encrypted overlay (default: gdrive-crypt)
      --crypt-remote-path <P>  Storage path for crypt remote (default: gdrive:homelab-backup)
      --skip-install           Skip rclone installation even if binary is missing
      --dry-run                Show proposed actions without modifying filesystem
  -h, --help                   Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      setup|install|configure|check)
        ACTION="$1"
        shift
        ;;
      -c|--config)
        test $# -ge 2 || { echo "Error: --config requires a path argument" >&2; exit 1; }
        RCLONE_CONFIG="$2"
        shift 2
        ;;
      --vault-script)
        test $# -ge 2 || { echo "Error: --vault-script requires a path argument" >&2; exit 1; }
        VAULT_SCRIPT="$2"
        shift 2
        ;;
      --gdrive-remote)
        test $# -ge 2 || { echo "Error: --gdrive-remote requires a name argument" >&2; exit 1; }
        GDRIVE_REMOTE="$2"
        shift 2
        ;;
      --crypt-remote)
        test $# -ge 2 || { echo "Error: --crypt-remote requires a name argument" >&2; exit 1; }
        CRYPT_REMOTE="$2"
        shift 2
        ;;
      --crypt-remote-path)
        test $# -ge 2 || { echo "Error: --crypt-remote-path requires a path argument" >&2; exit 1; }
        CRYPT_REMOTE_PATH="$2"
        shift 2
        ;;
      --skip-install)
        SKIP_INSTALL=true
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
        echo "Error: Unknown argument '$1'" >&2
        show_usage >&2
        exit 1
        ;;
    esac
  done
}

install_rclone() {
  if command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
    echo "Rclone is already installed: $(command -v "${RCLONE_BIN}") ($("${RCLONE_BIN}" version 2>/dev/null | head -n 1))"
    return 0
  fi

  if [ "${SKIP_INSTALL}" = "true" ]; then
    echo "Error: rclone is not installed and --skip-install was requested." >&2
    return 1
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    echo "[dry-run] Would download and run official rclone installer"
    return 0
  fi

  echo "Installing rclone via official installer..."
  if [ "$(id -u)" -eq 0 ]; then
    curl -fsSL https://rclone.org/install.sh | bash
  elif command -v sudo >/dev/null 2>&1; then
    curl -fsSL https://rclone.org/install.sh | sudo bash
  else
    echo "Error: Cannot install rclone without root or sudo privileges." >&2
    return 1
  fi
}

obscure_password() {
  local pass="$1"
  if [ -z "$pass" ]; then
    echo ""
    return 0
  fi

  if command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
    if "${RCLONE_BIN}" reveal "$pass" >/dev/null 2>&1; then
      echo "$pass"
      return 0
    fi
    "${RCLONE_BIN}" obscure "$pass"
  else
    echo "$pass"
  fi
}

configure_rclone() {
  if [ ! -x "${VAULT_SCRIPT}" ]; then
    echo "Error: Vault helper script not found or not executable at '${VAULT_SCRIPT}'" >&2
    return 1
  fi

  local gdrive_json
  if ! gdrive_json=$("${VAULT_SCRIPT}" get homelab/backup gdrive --format json 2>&1); then
    echo "Error: Failed to retrieve 'secret/homelab/backup/gdrive' from Vault:" >&2
    echo "${gdrive_json}" >&2
    echo "Ensure Vault is running and secrets are stored via:" >&2
    echo "  ${VAULT_SCRIPT} backup-put gdrive client_id=... client_secret=... token='{...}'" >&2
    return 1
  fi

  local crypt_json
  if ! crypt_json=$("${VAULT_SCRIPT}" get homelab/backup crypt --format json 2>&1); then
    echo "Error: Failed to retrieve 'secret/homelab/backup/crypt' from Vault:" >&2
    echo "${crypt_json}" >&2
    echo "Ensure Vault is running and secrets are stored via:" >&2
    echo "  ${VAULT_SCRIPT} backup-put crypt password=... [password2=...]" >&2
    return 1
  fi

  local client_id client_secret scope token team_drive password password2
  client_id=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("client_id", ""))' "$gdrive_json")
  client_secret=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("client_secret", ""))' "$gdrive_json")
  scope=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("scope", "drive"))' "$gdrive_json")
  token=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("token", ""))' "$gdrive_json")
  team_drive=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("team_drive", ""))' "$gdrive_json")

  if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$token" ]; then
    echo "Error: Vault secret 'secret/homelab/backup/gdrive' is missing required fields (client_id, client_secret, token)." >&2
    return 1
  fi

  password=$(python3 -c 'import sys, json; print(json.loads(sys.argv[1]).get("password", ""))' "$crypt_json")
  password2=$(python3 -c 'import sys, json; d=json.loads(sys.argv[1]); print(d.get("password2", d.get("salt", "")))' "$crypt_json")

  if [ -z "$password" ]; then
    echo "Error: Vault secret 'secret/homelab/backup/crypt' is missing required field 'password'." >&2
    return 1
  fi

  local obs_password obs_password2
  obs_password=$(obscure_password "$password")
  obs_password2=""
  if [ -n "$password2" ]; then
    obs_password2=$(obscure_password "$password2")
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    echo "[dry-run] Would write rclone config to: ${RCLONE_CONFIG} (mode 0600)"
    echo "[dry-run] Remote [${GDRIVE_REMOTE}]: type=drive client_id=${client_id} scope=${scope}"
    echo "[dry-run] Remote [${CRYPT_REMOTE}]: type=crypt remote=${CRYPT_REMOTE_PATH}"
    return 0
  fi

  python3 -c '
import configparser, os, stat, sys

config_path = sys.argv[1]
gdrive_name = sys.argv[2]
crypt_name = sys.argv[3]
crypt_remote = sys.argv[4]
client_id = sys.argv[5]
client_secret = sys.argv[6]
scope = sys.argv[7]
token = sys.argv[8]
team_drive = sys.argv[9]
password = sys.argv[10]
password2 = sys.argv[11]

cfg = configparser.RawConfigParser()
cfg.optionxform = str

if os.path.exists(config_path):
    cfg.read(config_path)

if not cfg.has_section(gdrive_name):
    cfg.add_section(gdrive_name)
cfg[gdrive_name]["type"] = "drive"
cfg[gdrive_name]["client_id"] = client_id
cfg[gdrive_name]["client_secret"] = client_secret
cfg[gdrive_name]["scope"] = scope
cfg[gdrive_name]["token"] = token
if team_drive:
    cfg[gdrive_name]["team_drive"] = team_drive

if not cfg.has_section(crypt_name):
    cfg.add_section(crypt_name)
cfg[crypt_name]["type"] = "crypt"
cfg[crypt_name]["remote"] = crypt_remote
cfg[crypt_name]["filename_encryption"] = "standard"
cfg[crypt_name]["directory_name_encryption"] = "true"
cfg[crypt_name]["password"] = password
if password2:
    cfg[crypt_name]["password2"] = password2
elif "password2" in cfg[crypt_name]:
    del cfg[crypt_name]["password2"]

cfg_dir = os.path.dirname(os.path.abspath(config_path))
if not os.path.exists(cfg_dir):
    os.makedirs(cfg_dir, mode=0o700, exist_ok=True)
else:
    try:
        os.chmod(cfg_dir, 0o700)
    except OSError:
        pass

flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
fd = os.open(config_path, flags, 0o600)
with open(fd, "w") as f:
    cfg.write(f)
os.chmod(config_path, 0o600)
' "$RCLONE_CONFIG" "$GDRIVE_REMOTE" "$CRYPT_REMOTE" "$CRYPT_REMOTE_PATH" \
  "$client_id" "$client_secret" "$scope" "$token" "$team_drive" \
  "$obs_password" "$obs_password2"

  chmod 600 "${RCLONE_CONFIG}"
  echo "Rclone configuration generated at: ${RCLONE_CONFIG} (permissions 600)"
}

check_connectivity() {
  if ! command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
    echo "Error: '${RCLONE_BIN}' binary not found. Install rclone first." >&2
    return 1
  fi

  if [ ! -f "${RCLONE_CONFIG}" ]; then
    echo "Error: Rclone configuration file not found at '${RCLONE_CONFIG}'." >&2
    echo "Run 'backup-setup.sh configure' to generate it from Vault." >&2
    return 1
  fi

  local perms
  perms=$(stat -c "%a" "${RCLONE_CONFIG}" 2>/dev/null || stat -f "%Lp" "${RCLONE_CONFIG}" 2>/dev/null || echo "")
  if [ -n "$perms" ] && [ "$perms" != "600" ]; then
    echo "Warning: Insecure permissions on '${RCLONE_CONFIG}': ${perms} (expected 600). Enforcing 600..."
    chmod 600 "${RCLONE_CONFIG}"
  fi

  echo "==> Verifying rclone configuration: ${RCLONE_CONFIG}"
  echo "==> Testing connection to Google Drive remote '${GDRIVE_REMOTE}:'..."
  if ! "${RCLONE_BIN}" --config "${RCLONE_CONFIG}" about "${GDRIVE_REMOTE}:" >/dev/null 2>&1; then
    echo "Error: Unable to connect to Google Drive remote '${GDRIVE_REMOTE}:'." >&2
    echo "Verify client credentials and token validity in ${RCLONE_CONFIG}." >&2
    return 1
  fi

  echo "==> Testing encrypted remote '${CRYPT_REMOTE}:'..."
  "${RCLONE_BIN}" --config "${RCLONE_CONFIG}" mkdir "${CRYPT_REMOTE}:" >/dev/null 2>&1 || true

  if ! "${RCLONE_BIN}" --config "${RCLONE_CONFIG}" lsd "${CRYPT_REMOTE}:" >/dev/null 2>&1; then
    echo "Error: Failed to interact with encrypted remote '${CRYPT_REMOTE}:'." >&2
    return 1
  fi

  echo "==> Rclone backup pre-flight check SUCCESSFUL!"
  return 0
}

main() {
  parse_args "$@"

  case "${ACTION}" in
    install)
      install_rclone
      ;;
    configure)
      configure_rclone
      ;;
    check)
      check_connectivity
      ;;
    setup)
      install_rclone
      configure_rclone
      ;;
  esac
}

main "$@"
