#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCLONE_CONFIG="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
BASE_REMOTE="${BASE_REMOTE:-gdrive-crypt:homelab-backups}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/homelab-restore-downloads}"
STORAGE_DIR="${STORAGE_DIR:-/var/lib/rancher/k3s/storage}"
TARGET_DIR="${TARGET_DIR:-}"
LIVE_RESTORE="${LIVE_RESTORE:-false}"
DRY_RUN="${DRY_RUN:-false}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-false}"
SKIP_DB="${SKIP_DB:-false}"
SKIP_PVC="${SKIP_PVC:-false}"
VAULT_FILE="${VAULT_FILE:-}"
K3S_FILE="${K3S_FILE:-}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
VAULT_VOLUME="${VAULT_VOLUME:-vault-data}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
ACTION="all"
TARGET_NAMESPACES=()

VAULT_REMOTE_DEST=""
K3S_REMOTE_DEST=""

show_usage() {
  cat <<'EOF'
Usage: restore.sh [COMMAND] [OPTIONS]

Homelab disaster recovery and restore pipeline for HashiCorp Vault and K3s cluster.

Commands:
  all             Restore both Vault storage and K3s cluster state (default)
  vault           Download and restore Vault snapshot only
  k3s             Download and restore K3s databases and PVCs only
  list            List available remote backups for Vault and K3s
  download        Download latest or specified backup archives to local staging

Options:
  -c, --config <PATH>          Path to rclone.conf (default: ~/.config/rclone/rclone.conf)
  -r, --remote <NAME_OR_PATH>  Base remote or directory (default: gdrive-crypt:homelab-backups)
  -t, --target-dir <DIR>       Extract and restore into target directory (default: /tmp/homelab-restore)
      --live                   Restore directly to running Vault container and live K3s storage/pods
      --vault-file <PATH>      Specific Vault snapshot archive filename or local path (default: latest)
      --k3s-file <PATH>        Specific K3s bundle archive filename or local path (default: latest)
      --download-dir <DIR>     Directory for downloading archives (default: /tmp/homelab-restore-downloads)
      --storage-dir <DIR>      K3s PVC destination directory (default: /var/lib/rancher/k3s/storage)
      --vault-container <NAME> Vault container name (default: vault)
      --vault-volume <NAME>    Vault volume name (default: vault-data)
      --vault-addr <URL>       Vault server address (default: http://127.0.0.1:8200)
      --vault-token <TOKEN>    Vault root/admin token (default: root)
  -n, --namespace <NAME>       Filter K3s restore to specific namespace (comma-separated or multiple)
      --skip-db                Skip restoring database dumps
      --skip-pvc               Skip restoring PVC archives
      --keep-downloads         Preserve downloaded archives after restore
      --kubectl-bin <PATH>     Path to kubectl binary (default: kubectl)
      --rclone-bin <PATH>      Path to rclone binary (default: rclone)
      --dry-run                Simulate actions without writing files or restoring data
  -h, --help                   Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      all|vault|k3s|list|download)
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
      -t|--target-dir)
        test $# -ge 2 || { echo "Error: --target-dir requires a directory argument" >&2; exit 1; }
        TARGET_DIR="$2"
        shift 2
        ;;
      --live)
        LIVE_RESTORE=true
        shift
        ;;
      --vault-file)
        test $# -ge 2 || { echo "Error: --vault-file requires a file path argument" >&2; exit 1; }
        VAULT_FILE="$2"
        shift 2
        ;;
      --k3s-file)
        test $# -ge 2 || { echo "Error: --k3s-file requires a file path argument" >&2; exit 1; }
        K3S_FILE="$2"
        shift 2
        ;;
      --download-dir)
        test $# -ge 2 || { echo "Error: --download-dir requires a directory argument" >&2; exit 1; }
        DOWNLOAD_DIR="$2"
        shift 2
        ;;
      --storage-dir)
        test $# -ge 2 || { echo "Error: --storage-dir requires a directory argument" >&2; exit 1; }
        STORAGE_DIR="$2"
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
      -n|--namespace)
        test $# -ge 2 || { echo "Error: --namespace requires a namespace argument" >&2; exit 1; }
        IFS=',' read -ra ADDR <<< "$2"
        for ns in "${ADDR[@]}"; do
          [[ -n "$ns" ]] && TARGET_NAMESPACES+=("$ns")
        done
        shift 2
        ;;
      --skip-db)
        SKIP_DB=true
        shift
        ;;
      --skip-pvc)
        SKIP_PVC=true
        shift
        ;;
      --keep-downloads)
        KEEP_DOWNLOADS=true
        shift
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

  if [[ "$LIVE_RESTORE" != "true" && -z "$TARGET_DIR" ]]; then
    TARGET_DIR="/tmp/homelab-restore"
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

run_rclone() {
  local cmd=("$RCLONE_BIN")
  if [ -n "${RCLONE_CONFIG}" ] && [ -f "${RCLONE_CONFIG}" ]; then
    cmd+=("--config" "${RCLONE_CONFIG}")
  fi
  "${cmd[@]}" "$@"
}

verify_prerequisites() {
  if ! command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
    echo "Error: rclone binary not found at '${RCLONE_BIN}'." >&2
    exit 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    echo "Error: tar binary not found in PATH." >&2
    exit 1
  fi
  if ! command -v gzip >/dev/null 2>&1; then
    echo "Error: gzip binary not found in PATH." >&2
    exit 1
  fi
  if [[ "$LIVE_RESTORE" == "true" && "$ACTION" =~ ^(all|k3s)$ ]] && [[ "$SKIP_DB" != "true" ]]; then
    if ! command -v "${KUBECTL_BIN}" >/dev/null 2>&1; then
      echo "Error: kubectl binary not found at '${KUBECTL_BIN}'." >&2
      exit 1
    fi
  fi
}

list_files_in_dest() {
  local dest="$1"
  local pattern="$2"
  if [[ "$dest" != *:* ]] && [ -d "$dest" ]; then
    find "$dest" -maxdepth 1 -type f -name "$pattern" -exec basename {} \; 2>/dev/null || true
  else
    run_rclone lsf "$dest" --files-only 2>/dev/null | grep -E "${pattern//\*/.*}" || true
  fi
}

list_remote_inventory() {
  echo "=================================================="
  echo "==> Vault Remote Backups (${VAULT_REMOTE_DEST})"
  echo "=================================================="
  local vault_files
  vault_files=$(list_files_in_dest "${VAULT_REMOTE_DEST}" "vault-backup-*.tar.gz" | sort -r || true)
  if [[ -z "$vault_files" ]]; then
    echo "No Vault backups found in remote destination."
  else
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      echo " - $f"
    done <<< "$vault_files"
  fi

  echo ""
  echo "=================================================="
  echo "==> K3s Remote Backups (${K3S_REMOTE_DEST})"
  echo "=================================================="
  local k3s_files
  k3s_files=$(list_files_in_dest "${K3S_REMOTE_DEST}" "k3s-backup-*.tar.gz" | sort -r || true)
  if [[ -z "$k3s_files" ]]; then
    echo "No K3s backups found in remote destination."
  else
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      echo " - $f"
    done <<< "$k3s_files"
  fi
}

find_latest_backup() {
  local dest="$1"
  local pattern="$2"
  list_files_in_dest "$dest" "$pattern" | sort -r | head -n 1
}

fetch_archive() {
  local remote_dest="$1"
  local file_ref="$2"
  local fallback_pattern="$3"
  local component_name="$4"

  if [[ -f "$file_ref" ]]; then
    echo "$file_ref"
    return 0
  fi

  local target_filename="$file_ref"
  if [[ -z "$target_filename" ]]; then
    target_filename=$(find_latest_backup "$remote_dest" "$fallback_pattern")
    if [[ -z "$target_filename" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] No ${component_name} backup archives found at '${remote_dest}'." >&2
        return 0
      fi
      echo "Error: No ${component_name} backup archives found at '${remote_dest}'." >&2
      return 1
    fi
    echo "Selected latest ${component_name} backup: ${target_filename}" >&2
  fi

  local local_path="${DOWNLOAD_DIR}/${target_filename}"
  mkdir -p "${DOWNLOAD_DIR}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would download '${remote_dest}/${target_filename}' to '${local_path}'" >&2
    echo "${local_path}"
    return 0
  fi

  echo "==> Downloading ${component_name} archive: ${target_filename}..." >&2
  if [[ "$remote_dest" != *:* ]] && [ -d "$remote_dest" ]; then
    cp "${remote_dest}/${target_filename}" "${local_path}"
    if [ -f "${remote_dest}/${target_filename}.sha256" ]; then
      cp "${remote_dest}/${target_filename}.sha256" "${DOWNLOAD_DIR}/"
    fi
  else
    run_rclone copy "${remote_dest}/${target_filename}" "${DOWNLOAD_DIR}/"
    run_rclone copy "${remote_dest}/${target_filename}.sha256" "${DOWNLOAD_DIR}/" 2>/dev/null || true
  fi

  if [ ! -f "$local_path" ]; then
    echo "Error: Downloaded file '${local_path}' not found." >&2
    return 1
  fi

  if [ -f "${local_path}.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    echo "Verifying SHA256 checksum for ${target_filename}..." >&2
    if ! (cd "${DOWNLOAD_DIR}" && sha256sum -c "${target_filename}.sha256" >/dev/null 2>&1); then
      echo "Error: SHA256 checksum verification failed for ${target_filename}." >&2
      rm -f "${local_path}" "${local_path}.sha256"
      return 1
    fi
    echo "Checksum verified for ${target_filename}." >&2
  fi

  echo "$local_path"
}

restore_vault() {
  echo "=================================================="
  echo "==> Restoring HashiCorp Vault Snapshot"
  echo "=================================================="

  local archive_path
  if ! archive_path=$(fetch_archive "${VAULT_REMOTE_DEST}" "${VAULT_FILE}" "vault-backup-*.tar.gz" "Vault"); then
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$archive_path" ]]; then
      echo "[dry-run] Would inspect archive '${archive_path}' and restore Vault state."
      if [[ -f "$archive_path" ]]; then
        tar -tzf "$archive_path" || true
      fi
    else
      echo "[dry-run] No Vault snapshot available to simulate restore."
    fi
    return 0
  fi

  local staging_dir
  staging_dir=$(mktemp -d /tmp/vault-restore-stage.XXXXXX)

  if ! tar -xzf "$archive_path" -C "$staging_dir"; then
    rm -rf "$staging_dir"
    echo "Error: Failed to decompress Vault archive '${archive_path}'." >&2
    return 1
  fi

  local storage_type="dir"
  if [ -f "${staging_dir}/metadata.json" ] && command -v jq >/dev/null 2>&1; then
    storage_type=$(jq -r '.storage_type // "dir"' "${staging_dir}/metadata.json" 2>/dev/null || echo "dir")
  fi
  echo "Detected Vault snapshot storage type: ${storage_type}"

  if [[ -n "$TARGET_DIR" ]]; then
    local dest_dir="${TARGET_DIR}/vault"
    mkdir -p "$dest_dir"
    cp -a "${staging_dir}/." "${dest_dir}/"
    echo "Vault snapshot safely restored to target directory: ${dest_dir}"
  fi

  if [[ "$LIVE_RESTORE" == "true" ]]; then
    if [[ "$storage_type" == "raft" || -f "${staging_dir}/vault.snap" ]]; then
      local snap_file="${staging_dir}/vault.snap"
      test -f "$snap_file" || { rm -rf "$staging_dir"; echo "Error: Raft snapshot file 'vault.snap' missing in archive." >&2; return 1; }
      echo "Restoring Raft storage snapshot to live Vault instance (${VAULT_ADDR})..."
      if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/storage/raft/snapshot-force" -X POST --data-binary @"$snap_file" 2>/dev/null; then
        echo "Vault Raft snapshot restored successfully via API."
      elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${VAULT_CONTAINER}"; then
        docker cp "$snap_file" "${VAULT_CONTAINER}:/tmp/vault.snap"
        docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" vault operator raft snapshot restore -force /tmp/vault.snap
        docker exec "${VAULT_CONTAINER}" rm -f /tmp/vault.snap || true
        echo "Vault Raft snapshot restored successfully via Docker container."
      else
        rm -rf "$staging_dir"
        echo "Error: Unable to connect to Vault to restore Raft snapshot." >&2
        return 1
      fi
    else
      echo "Restoring Vault file storage to container '${VAULT_CONTAINER}'..."
      if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${VAULT_CONTAINER}"; then
        if [ -d "${staging_dir}/data" ]; then
          tar -czf - -C "${staging_dir}/data" . | docker exec -i "${VAULT_CONTAINER}" tar -xzf - -C /vault/file/
          echo "Vault file storage restored into container '${VAULT_CONTAINER}'."
        fi
      else
        echo "Warning: Container '${VAULT_CONTAINER}' is not running. Live file restore skipped." >&2
      fi
    fi
  fi

  rm -rf "$staging_dir"
  return 0
}

restore_k3s() {
  echo "=================================================="
  echo "==> Restoring K3s Cluster State (PVCs & Databases)"
  echo "=================================================="

  local bundle_path
  if ! bundle_path=$(fetch_archive "${K3S_REMOTE_DEST}" "${K3S_FILE}" "k3s-backup-*.tar.gz" "K3s"); then
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$bundle_path" ]]; then
      echo "[dry-run] Would inspect K3s bundle '${bundle_path}' and restore PVCs and databases."
      if [[ -f "$bundle_path" ]]; then
        tar -tzf "$bundle_path" | head -n 30 || true
      fi
    else
      echo "[dry-run] No K3s bundle available to simulate restore."
    fi
    return 0
  fi

  local staging_dir
  staging_dir=$(mktemp -d /tmp/k3s-restore-stage.XXXXXX)

  if ! tar -xzf "$bundle_path" -C "$staging_dir"; then
    rm -rf "$staging_dir"
    echo "Error: Failed to decompress K3s bundle archive '${bundle_path}'." >&2
    return 1
  fi

  local bundle_root
  bundle_root=$(find "$staging_dir" -mindepth 1 -maxdepth 1 -type d -name 'k3s-backup-*' | head -n 1 || true)
  if [[ -z "$bundle_root" ]]; then
    bundle_root="$staging_dir"
  fi

  if [ -f "${bundle_root}/manifest.json" ]; then
    echo "Backup manifest loaded: $(basename "$bundle_path")"
  fi

  if [[ "$SKIP_PVC" != "true" && -d "${bundle_root}/pvcs" ]]; then
    echo "==> Restoring Persistent Volume Claims (PVCs)..."
    local pvc_archives=()
    while IFS= read -r -d $'\0' f; do
      [[ -z "$f" ]] && continue
      pvc_archives+=("$f")
    done < <(find "${bundle_root}/pvcs" -maxdepth 1 -type f -name '*.tar.gz' -print0 2>/dev/null || true)

    if [[ ${#pvc_archives[@]} -eq 0 ]]; then
      echo "No PVC archives found in bundle."
    else
      for pvc_tar in "${pvc_archives[@]}"; do
        local pvc_name
        pvc_name="$(basename "$pvc_tar" .tar.gz)"

        if [[ ${#TARGET_NAMESPACES[@]} -gt 0 ]]; then
          local matched=false
          for ns in "${TARGET_NAMESPACES[@]}"; do
            if [[ "$pvc_name" == *"_${ns}_"* || "$pvc_name" == "${ns}"* || "$pvc_name" == *"_${ns}" ]]; then
              matched=true
              break
            fi
          done
          if [[ "$matched" != "true" ]]; then
            continue
          fi
        fi

        if [[ -n "$TARGET_DIR" ]]; then
          local target_pvc_dir="${TARGET_DIR}/k3s/storage"
          mkdir -p "$target_pvc_dir"
          tar -xzf "$pvc_tar" -C "$target_pvc_dir"
          echo "Restored PVC '${pvc_name}' -> ${target_pvc_dir}/${pvc_name}"
        fi

        if [[ "$LIVE_RESTORE" == "true" ]]; then
          mkdir -p "${STORAGE_DIR}"
          tar -xzf "$pvc_tar" -C "${STORAGE_DIR}"
          echo "Restored PVC '${pvc_name}' -> ${STORAGE_DIR}/${pvc_name}"
        fi
      done
    fi
  fi

  if [[ "$SKIP_DB" != "true" && -d "${bundle_root}/databases" ]]; then
    echo "==> Restoring Database Dumps..."
    local db_dumps=()
    while IFS= read -r -d $'\0' f; do
      [[ -z "$f" ]] && continue
      db_dumps+=("$f")
    done < <(find "${bundle_root}/databases" -maxdepth 1 -type f -name '*.sql.gz' -print0 2>/dev/null || true)

    if [[ ${#db_dumps[@]} -eq 0 ]]; then
      echo "No database dumps found in bundle."
    else
      for db_dump in "${db_dumps[@]}"; do
        local stem
        stem="$(basename "$db_dump" .sql.gz)"
        local ns
        ns=$(echo "$stem" | cut -d'_' -f1)
        local db_type
        db_type=$(echo "$stem" | awk -F'_' '{print $NF}')
        local pod
        pod=$(echo "$stem" | sed -E "s/^${ns}_(.*)_${db_type}$/\1/")

        if [[ ${#TARGET_NAMESPACES[@]} -gt 0 ]]; then
          local matched=false
          for target_ns in "${TARGET_NAMESPACES[@]}"; do
            if [[ "$ns" == "$target_ns" ]]; then
              matched=true
              break
            fi
          done
          if [[ "$matched" != "true" ]]; then
            continue
          fi
        fi

        if [[ -n "$TARGET_DIR" ]]; then
          local target_db_dir="${TARGET_DIR}/k3s/databases"
          mkdir -p "$target_db_dir"
          cp "$db_dump" "${target_db_dir}/"
          gunzip -k -f "${target_db_dir}/$(basename "$db_dump")"
          echo "Restored SQL dump '${stem}' -> ${target_db_dir}/${stem}.sql"
        fi

        if [[ "$LIVE_RESTORE" == "true" ]]; then
          if "${KUBECTL_BIN}" get pod -n "$ns" "$pod" >/dev/null 2>&1; then
            echo "Applying SQL dump to live pod ${ns}/${pod} (${db_type})..."
            if [[ "$db_type" == "postgres" ]]; then
              gunzip -c "$db_dump" | "${KUBECTL_BIN}" exec -i -n "$ns" "$pod" -- sh -c '
                USER="${POSTGRES_USER:-postgres}"
                psql -U "$USER" -f -
              '
              echo "PostgreSQL database restored on ${ns}/${pod}."
            elif [[ "$db_type" == "mysql" ]]; then
              gunzip -c "$db_dump" | "${KUBECTL_BIN}" exec -i -n "$ns" "$pod" -- sh -c '
                PASS_ARG=""
                if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
                  PASS_ARG="-p${MYSQL_ROOT_PASSWORD}"
                elif [ -n "${MARIADB_ROOT_PASSWORD:-}" ]; then
                  PASS_ARG="-p${MARIADB_ROOT_PASSWORD}"
                fi
                USER="${MYSQL_USER:-root}"
                mysql -u "$USER" ${PASS_ARG}
              '
              echo "MySQL/MariaDB database restored on ${ns}/${pod}."
            fi
          else
            echo "Warning: Live pod ${ns}/${pod} not found. SQL dump restore skipped." >&2
          fi
        fi
      done
    fi
  fi

  rm -rf "$staging_dir"
  return 0
}

cleanup() {
  if [[ "$KEEP_DOWNLOADS" != "true" && -d "$DOWNLOAD_DIR" ]]; then
    rm -rf "$DOWNLOAD_DIR"
  fi
}

trap cleanup EXIT

main() {
  parse_args "$@"
  resolve_remotes "${BASE_REMOTE}"
  verify_prerequisites

  case "$ACTION" in
    list)
      list_remote_inventory
      exit 0
      ;;
    download)
      echo "=================================================="
      echo "==> Downloading Latest Backup Archives"
      echo "=================================================="
      KEEP_DOWNLOADS=true
      local v_file
      v_file=$(fetch_archive "${VAULT_REMOTE_DEST}" "${VAULT_FILE}" "vault-backup-*.tar.gz" "Vault")
      echo "Vault archive downloaded: ${v_file}"
      local k_file
      k_file=$(fetch_archive "${K3S_REMOTE_DEST}" "${K3S_FILE}" "k3s-backup-*.tar.gz" "K3s")
      echo "K3s bundle downloaded: ${k_file}"
      exit 0
      ;;
    vault)
      restore_vault
      exit $?
      ;;
    k3s)
      restore_k3s
      exit $?
      ;;
    all)
      ;;
  esac

  local start_epoch
  start_epoch=$(date +%s)
  local vault_status="SUCCESS"
  local k3s_status="SUCCESS"

  if ! restore_vault; then
    vault_status="FAILED"
  fi

  if ! restore_k3s; then
    k3s_status="FAILED"
  fi

  local total_end
  total_end=$(date +%s)
  local total_duration="$((total_end - start_epoch))s"

  echo ""
  echo "=================================================="
  echo "              HOMELAB RESTORE SUMMARY             "
  echo "=================================================="
  echo "Source Remote:  ${BASE_REMOTE}"
  echo "Target Dir:     ${TARGET_DIR:-N/A}"
  echo "Live Restore:   ${LIVE_RESTORE}"
  echo "Dry Run:        ${DRY_RUN}"
  echo "--------------------------------------------------"
  printf "%-14s %-12s\n" "Component" "Status"
  echo "--------------------------------------------------"
  printf "%-14s %-12s\n" "Vault" "${vault_status}"
  printf "%-14s %-12s\n" "K3s" "${k3s_status}"
  echo "--------------------------------------------------"
  if [[ "$vault_status" == "FAILED" || "$k3s_status" == "FAILED" ]]; then
    echo "Overall:        FAILED (Total time: ${total_duration})"
    echo "=================================================="
    exit 1
  else
    echo "Overall:        SUCCESS (Total time: ${total_duration})"
    echo "=================================================="
    exit 0
  fi
}

main "$@"
