#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_BACKUP_SCRIPT="${VAULT_BACKUP_SCRIPT:-${SCRIPT_DIR}/backup-vault.sh}"
K3S_BACKUP_SCRIPT="${K3S_BACKUP_SCRIPT:-${SCRIPT_DIR}/backup-k3s.sh}"
BACKUP_SETUP_SCRIPT="${BACKUP_SETUP_SCRIPT:-${SCRIPT_DIR}/backup-setup.sh}"

RCLONE_CONFIG="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
BASE_REMOTE="${BASE_REMOTE:-gdrive-crypt:homelab-backups}"
KEEP_DAYS="${KEEP_DAYS:-7}"
KEEP_WEEKS="${KEEP_WEEKS:-4}"
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y%m%d_%H%M%S")}"
DRY_RUN="${DRY_RUN:-false}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-false}"
SKIP_VAULT="${SKIP_VAULT:-false}"
SKIP_K3S="${SKIP_K3S:-false}"
SKIP_PRUNE="${SKIP_PRUNE:-false}"
SKIP_DB="${SKIP_DB:-false}"
SKIP_PVC="${SKIP_PVC:-false}"
SOURCE_MODE="${SOURCE_MODE:-auto}"
SOURCE_DIR="${SOURCE_DIR:-}"
STORAGE_DIR="${STORAGE_DIR:-}"
VAULT_ADDR="${VAULT_ADDR:-}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_CONTAINER="${VAULT_CONTAINER:-}"
VAULT_VOLUME="${VAULT_VOLUME:-}"
ACTION="all"

VAULT_REMOTE_DEST=""
K3S_REMOTE_DEST=""

show_usage() {
  cat <<'EOF'
Usage: backup.sh [COMMAND] [OPTIONS]

Unified backup orchestrator for Homelab infrastructure (HashiCorp Vault & K3s cluster).

Commands:
  all             Run full backup pipeline for Vault and K3s (default)
  vault           Run Vault backup pipeline only
  k3s             Run K3s backup pipeline only (databases and PVCs)
  status          Show backup status and remote inventory for Vault and K3s
  prune           Prune remote backups according to retention policy
  check           Run pre-flight connectivity check to encrypted storage

Options:
  -c, --config <PATH>          Path to rclone.conf (default: ~/.config/rclone/rclone.conf)
  -r, --remote <NAME_OR_PATH>  Base remote or directory (default: gdrive-crypt:homelab-backups)
      --keep-days <N>          Daily retention count (default: 7)
      --keep-weeks <N>         Weekly retention count (default: 4)
      --timestamp <TS>         Timestamp override (format: YYYYMMDD_HHMMSS)
      --skip-vault             Skip Vault backup during 'all'
      --skip-k3s               Skip K3s backup during 'all'
      --skip-prune             Skip retention pruning on remote
      --skip-db                Skip K3s database dumps
      --skip-pvc               Skip K3s PVC archives
      --source-mode <MODE>     Vault storage mode (auto, raft, docker, volume, dir)
      --source-dir <PATH>      Vault storage source directory (for dir mode)
      --storage-dir <DIR>      K3s PVC storage directory (/var/lib/rancher/k3s/storage)
      --vault-addr <URL>       Vault server address override
      --vault-token <TOKEN>    Vault root/admin token override
      --vault-container <NAME> Vault container name override
      --vault-volume <NAME>    Vault Docker volume override
      --kubectl-bin <PATH>     Path to kubectl binary
      --rclone-bin <PATH>      Path to rclone binary
      --continue-on-error      Proceed with remaining components if one fails
      --dry-run                Simulate actions without writing or uploading data
  -h, --help                   Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      all|vault|k3s|status|prune|check)
        ACTION="$1"
        shift
        ;;
      -c|--config)
        test $# -ge 2 || { echo "Error: --config requires a path argument" >&2; exit 1; }
        RCLONE_CONFIG="$2"
        shift 2
        ;;
      -r|--remote)
        test $# -ge 2 || { echo "Error: --remote requires a destination argument" >&2; exit 1; }
        BASE_REMOTE="$2"
        shift 2
        ;;
      --keep-days)
        test $# -ge 2 || { echo "Error: --keep-days requires an integer argument" >&2; exit 1; }
        KEEP_DAYS="$2"
        shift 2
        ;;
      --keep-weeks)
        test $# -ge 2 || { echo "Error: --keep-weeks requires an integer argument" >&2; exit 1; }
        KEEP_WEEKS="$2"
        shift 2
        ;;
      --timestamp)
        test $# -ge 2 || { echo "Error: --timestamp requires a timestamp argument" >&2; exit 1; }
        TIMESTAMP="$2"
        shift 2
        ;;
      --skip-vault)
        SKIP_VAULT=true
        shift
        ;;
      --skip-k3s)
        SKIP_K3S=true
        shift
        ;;
      --skip-prune)
        SKIP_PRUNE=true
        shift
        ;;
      --skip-db)
        SKIP_DB=true
        shift
        ;;
      --skip-pvc)
        SKIP_PVC=true
        shift
        ;;
      --source-mode)
        test $# -ge 2 || { echo "Error: --source-mode requires a mode argument" >&2; exit 1; }
        SOURCE_MODE="$2"
        shift 2
        ;;
      --source-dir)
        test $# -ge 2 || { echo "Error: --source-dir requires a path argument" >&2; exit 1; }
        SOURCE_DIR="$2"
        shift 2
        ;;
      --storage-dir)
        test $# -ge 2 || { echo "Error: --storage-dir requires a path argument" >&2; exit 1; }
        STORAGE_DIR="$2"
        shift 2
        ;;
      --vault-addr)
        test $# -ge 2 || { echo "Error: --vault-addr requires a URL argument" >&2; exit 1; }
        VAULT_ADDR="$2"
        shift 2
        ;;
      --vault-token)
        test $# -ge 2 || { echo "Error: --vault-token requires a token argument" >&2; exit 1; }
        VAULT_TOKEN="$2"
        shift 2
        ;;
      --vault-container)
        test $# -ge 2 || { echo "Error: --vault-container requires a name argument" >&2; exit 1; }
        VAULT_CONTAINER="$2"
        shift 2
        ;;
      --vault-volume)
        test $# -ge 2 || { echo "Error: --vault-volume requires a name argument" >&2; exit 1; }
        VAULT_VOLUME="$2"
        shift 2
        ;;
      --kubectl-bin)
        test $# -ge 2 || { echo "Error: --kubectl-bin requires a path argument" >&2; exit 1; }
        KUBECTL_BIN="$2"
        shift 2
        ;;
      --rclone-bin)
        test $# -ge 2 || { echo "Error: --rclone-bin requires a path argument" >&2; exit 1; }
        RCLONE_BIN="$2"
        shift 2
        ;;
      --continue-on-error)
        CONTINUE_ON_ERROR=true
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

  if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]]; then
    echo "Error: --keep-days must be a non-negative integer" >&2
    exit 1
  fi

  if ! [[ "$KEEP_WEEKS" =~ ^[0-9]+$ ]]; then
    echo "Error: --keep-weeks must be a non-negative integer" >&2
    exit 1
  fi
}

resolve_remotes() {
  local base="$1"
  if [[ "$base" == *:* ]]; then
    local remote_name="${base%%:*}"
    local path_part="${base#*:}"
    path_part="${path_part#/}"
    path_part="${path_part%/}"
    if [[ -z "$path_part" ]]; then
      path_part="homelab-backups"
    fi
    VAULT_REMOTE_DEST="${remote_name}:${path_part}/vault"
    K3S_REMOTE_DEST="${remote_name}:${path_part}/k3s"
  elif [[ "$base" == /* || "$base" == ./* || "$base" == ../* ]]; then
    local clean_path="${base%/}"
    VAULT_REMOTE_DEST="${clean_path}/vault"
    K3S_REMOTE_DEST="${clean_path}/k3s"
  else
    VAULT_REMOTE_DEST="${base}:homelab-backups/vault"
    K3S_REMOTE_DEST="${base}:homelab-backups/k3s"
  fi
}

verify_prerequisites() {
  if [ ! -x "${VAULT_BACKUP_SCRIPT}" ]; then
    echo "Error: Vault backup script not found or not executable at '${VAULT_BACKUP_SCRIPT}'" >&2
    exit 1
  fi
  if [ ! -x "${K3S_BACKUP_SCRIPT}" ]; then
    echo "Error: K3s backup script not found or not executable at '${K3S_BACKUP_SCRIPT}'" >&2
    exit 1
  fi
}

run_vault_backup() {
  echo "=================================================="
  echo "==> Starting Vault Backup Pipeline"
  echo "=================================================="
  local args=()

  if [[ "$SKIP_PRUNE" == "true" ]]; then
    args+=("upload")
  else
    args+=("backup")
  fi

  args+=("--dest" "${VAULT_REMOTE_DEST}")
  args+=("--keep-days" "${KEEP_DAYS}")
  args+=("--keep-weeks" "${KEEP_WEEKS}")
  args+=("--timestamp" "${TIMESTAMP}")
  args+=("-c" "${RCLONE_CONFIG}")

  if [[ -n "${SOURCE_MODE}" ]]; then
    args+=("--source-mode" "${SOURCE_MODE}")
  fi
  if [[ -n "${SOURCE_DIR}" ]]; then
    args+=("--source-dir" "${SOURCE_DIR}")
  fi
  if [[ -n "${VAULT_ADDR}" ]]; then
    args+=("--vault-addr" "${VAULT_ADDR}")
  fi
  if [[ -n "${VAULT_TOKEN}" ]]; then
    args+=("--vault-token" "${VAULT_TOKEN}")
  fi
  if [[ -n "${VAULT_CONTAINER}" ]]; then
    args+=("--vault-container" "${VAULT_CONTAINER}")
  fi
  if [[ -n "${VAULT_VOLUME}" ]]; then
    args+=("--vault-volume" "${VAULT_VOLUME}")
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    args+=("--dry-run")
  fi

  RCLONE_BIN="${RCLONE_BIN}" "${VAULT_BACKUP_SCRIPT}" "${args[@]}"
}

run_k3s_backup() {
  echo "=================================================="
  echo "==> Starting K3s Cluster Backup Pipeline"
  echo "=================================================="
  local args=("all")

  args+=("--remote" "${K3S_REMOTE_DEST}")
  args+=("--retention-daily" "${KEEP_DAYS}")
  args+=("--retention-weekly" "${KEEP_WEEKS}")
  args+=("--timestamp" "${TIMESTAMP}")
  args+=("-c" "${RCLONE_CONFIG}")
  args+=("--kubectl-bin" "${KUBECTL_BIN}")
  args+=("--rclone-bin" "${RCLONE_BIN}")

  if [[ -n "${STORAGE_DIR}" ]]; then
    args+=("--storage-dir" "${STORAGE_DIR}")
  fi
  if [[ "$SKIP_DB" == "true" ]]; then
    args+=("--skip-db")
  fi
  if [[ "$SKIP_PVC" == "true" ]]; then
    args+=("--skip-pvc")
  fi
  if [[ "$SKIP_PRUNE" == "true" ]]; then
    args+=("--skip-prune")
  fi
  if [[ "$CONTINUE_ON_ERROR" == "true" ]]; then
    args+=("--continue-on-error")
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    args+=("--dry-run")
  fi

  "${K3S_BACKUP_SCRIPT}" "${args[@]}"
}

run_status() {
  echo "=================================================="
  echo "==> Vault Backup Inventory & Status"
  echo "=================================================="
  local vault_status_args=("status" "--dest" "${VAULT_REMOTE_DEST}" "-c" "${RCLONE_CONFIG}")
  if [[ -n "${VAULT_ADDR}" ]]; then
    vault_status_args+=("--vault-addr" "${VAULT_ADDR}")
  fi
  RCLONE_BIN="${RCLONE_BIN}" "${VAULT_BACKUP_SCRIPT}" "${vault_status_args[@]}" || true

  echo ""
  echo "=================================================="
  echo "==> K3s Backup Inventory & Retention Status"
  echo "=================================================="
  local k3s_status_args=("list" "--remote" "${K3S_REMOTE_DEST}" "-c" "${RCLONE_CONFIG}" "--rclone-bin" "${RCLONE_BIN}")
  "${K3S_BACKUP_SCRIPT}" "${k3s_status_args[@]}" || true
}

run_prune() {
  echo "=================================================="
  echo "==> Pruning Remote Vault Backups"
  echo "=================================================="
  local vault_prune_args=("prune" "--dest" "${VAULT_REMOTE_DEST}" "--keep-days" "${KEEP_DAYS}" "--keep-weeks" "${KEEP_WEEKS}" "-c" "${RCLONE_CONFIG}")
  if [[ "$DRY_RUN" == "true" ]]; then
    vault_prune_args+=("--dry-run")
  fi
  RCLONE_BIN="${RCLONE_BIN}" "${VAULT_BACKUP_SCRIPT}" "${vault_prune_args[@]}"

  echo ""
  echo "=================================================="
  echo "==> Pruning Remote K3s Backups"
  echo "=================================================="
  local k3s_prune_args=("prune" "--remote" "${K3S_REMOTE_DEST}" "--retention-daily" "${KEEP_DAYS}" "--retention-weekly" "${KEEP_WEEKS}" "-c" "${RCLONE_CONFIG}" "--rclone-bin" "${RCLONE_BIN}")
  if [[ "$DRY_RUN" == "true" ]]; then
    k3s_prune_args+=("--dry-run")
  fi
  "${K3S_BACKUP_SCRIPT}" "${k3s_prune_args[@]}"
}

run_check() {
  if [ -x "${BACKUP_SETUP_SCRIPT}" ]; then
    "${BACKUP_SETUP_SCRIPT}" check -c "${RCLONE_CONFIG}"
  else
    echo "Error: Backup setup script not found at '${BACKUP_SETUP_SCRIPT}'" >&2
    exit 1
  fi
}

main() {
  parse_args "$@"
  resolve_remotes "${BASE_REMOTE}"
  verify_prerequisites

  case "$ACTION" in
    check)
      run_check
      exit $?
      ;;
    status)
      run_status
      exit $?
      ;;
    prune)
      run_prune
      exit $?
      ;;
    vault)
      run_vault_backup
      exit $?
      ;;
    k3s)
      run_k3s_backup
      exit $?
      ;;
    all)
      ;;
  esac

  local start_epoch
  start_epoch=$(date +%s)
  local vault_status="SKIPPED"
  local vault_duration="0s"
  local k3s_status="SKIPPED"
  local k3s_duration="0s"
  local overall_failure=false

  if [[ "$SKIP_VAULT" != "true" ]]; then
    local v_start
    v_start=$(date +%s)
    if run_vault_backup; then
      vault_status="SUCCESS"
    else
      vault_status="FAILED"
      overall_failure=true
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        echo "Error: Vault backup failed; aborting pipeline." >&2
        exit 1
      fi
    fi
    local v_end
    v_end=$(date +%s)
    vault_duration="$((v_end - v_start))s"
  fi

  if [[ "$SKIP_K3S" != "true" ]]; then
    local k_start
    k_start=$(date +%s)
    if run_k3s_backup; then
      k3s_status="SUCCESS"
    else
      k3s_status="FAILED"
      overall_failure=true
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        echo "Error: K3s backup failed; aborting pipeline." >&2
        exit 1
      fi
    fi
    local k_end
    k_end=$(date +%s)
    k3s_duration="$((k_end - k_start))s"
  fi

  local total_end
  total_end=$(date +%s)
  local total_duration="$((total_end - start_epoch))s"

  echo ""
  echo "=================================================="
  echo "              HOMELAB BACKUP SUMMARY              "
  echo "=================================================="
  echo "Timestamp:     ${TIMESTAMP}"
  echo "Target Remote: ${BASE_REMOTE}"
  echo "Dry Run:       ${DRY_RUN}"
  echo "--------------------------------------------------"
  printf "%-14s %-12s %s\n" "Component" "Status" "Duration"
  echo "--------------------------------------------------"
  printf "%-14s %-12s %s\n" "Vault" "${vault_status}" "${vault_duration}"
  printf "%-14s %-12s %s\n" "K3s" "${k3s_status}" "${k3s_duration}"
  echo "--------------------------------------------------"
  if [[ "$overall_failure" == "true" ]]; then
    echo "Overall:       FAILED (Total time: ${total_duration})"
    echo "=================================================="
    exit 1
  else
    echo "Overall:       SUCCESS (Total time: ${total_duration})"
    echo "=================================================="
    exit 0
  fi
}

main "$@"
