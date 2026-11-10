#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RCLONE_CONFIG="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
REMOTE="${REMOTE:-gdrive-crypt}"
REMOTE_PATH="${REMOTE_PATH:-homelab-backups/vault}"
DEST="${DEST:-}"
TARGET=""
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/vault-backups}"
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y%m%d_%H%M%S")}"
FILENAME="${FILENAME:-vault-backup-${TIMESTAMP}.tar.gz}"
EXPLICIT_FILE="${EXPLICIT_FILE:-}"
KEEP_DAYS="${KEEP_DAYS:-7}"
KEEP_WEEKS="${KEEP_WEEKS:-4}"
KEEP_LAST="${KEEP_LAST:-1}"
SOURCE_MODE="${SOURCE_MODE:-auto}"
SOURCE_DIR="${SOURCE_DIR:-}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault}"
VAULT_VOLUME="${VAULT_VOLUME:-vault-data}"
KEEP_LOCAL="${KEEP_LOCAL:-false}"
DRY_RUN="${DRY_RUN:-false}"
ACTION="backup"

show_usage() {
  cat <<'EOF'
Usage: backup-vault.sh [COMMAND] [OPTIONS]

Consistent Vault snapshot, compression, and encrypted Google Drive backup pipeline.

Commands:
  backup          Run full pipeline: snapshot, compress, upload, verify, and prune (default)
  snapshot        Create local compressed Vault snapshot archive only
  upload          Upload an existing snapshot archive to remote and verify
  prune           Prune remote backups according to retention policy
  status          Display Vault status and list remote backups

Options:
  -c, --config <PATH>          Path to rclone.conf (default: ~/.config/rclone/rclone.conf)
  -r, --remote <NAME>          Target rclone remote (default: gdrive-crypt)
  -p, --remote-path <PATH>     Target remote directory path (default: homelab-backups/vault)
  -d, --dest <TARGET>          Full target destination (e.g. gdrive-crypt:homelab-backups/vault or /path)
  -o, --output-dir <DIR>       Local directory for snapshot archives (default: /tmp/vault-backups)
      --file <PATH>            Snapshot archive file (required for 'upload' command)
      --filename <NAME>        Archive filename override (default: vault-backup-YYYYMMDD_HHMMSS.tar.gz)
      --timestamp <TS>         Timestamp override in format YYYYMMDD_HHMMSS
      --keep-days <N>          Retention count for daily backups (default: 7)
      --keep-weeks <N>         Retention count for weekly backups (default: 4)
      --keep-last <N>          Minimum backups to retain under all conditions (default: 1)
      --source-mode <MODE>     Storage mode: auto, raft, docker, volume, dir (default: auto)
      --source-dir <PATH>      Source storage directory (for dir mode or testing fixtures)
      --vault-addr <URL>       Vault server address (default: http://127.0.0.1:8200)
      --vault-token <TOKEN>    Vault root/admin token (default: root)
      --vault-container <NAME> Vault Docker container name (default: vault)
      --vault-volume <NAME>    Vault Docker volume name (default: vault-data)
      --keep-local             Preserve local snapshot archive after upload
      --dry-run                Simulate actions without modifying filesystem or remote
  -h, --help                   Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      backup|snapshot|upload|prune|status)
        ACTION="$1"
        shift
        ;;
      -c|--config)
        test $# -ge 2 || { echo "Error: --config requires a path argument" >&2; exit 1; }
        RCLONE_CONFIG="$2"
        shift 2
        ;;
      -r|--remote)
        test $# -ge 2 || { echo "Error: --remote requires a name argument" >&2; exit 1; }
        REMOTE="$2"
        shift 2
        ;;
      -p|--remote-path)
        test $# -ge 2 || { echo "Error: --remote-path requires a path argument" >&2; exit 1; }
        REMOTE_PATH="$2"
        shift 2
        ;;
      -d|--dest)
        test $# -ge 2 || { echo "Error: --dest requires a destination argument" >&2; exit 1; }
        DEST="$2"
        shift 2
        ;;
      -o|--output-dir)
        test $# -ge 2 || { echo "Error: --output-dir requires a directory argument" >&2; exit 1; }
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --file)
        test $# -ge 2 || { echo "Error: --file requires a file path argument" >&2; exit 1; }
        EXPLICIT_FILE="$2"
        shift 2
        ;;
      --filename)
        test $# -ge 2 || { echo "Error: --filename requires a filename argument" >&2; exit 1; }
        FILENAME="$2"
        shift 2
        ;;
      --timestamp)
        test $# -ge 2 || { echo "Error: --timestamp requires a timestamp argument" >&2; exit 1; }
        TIMESTAMP="$2"
        FILENAME="vault-backup-${TIMESTAMP}.tar.gz"
        shift 2
        ;;
      --keep-days)
        test $# -ge 2 || { echo "Error: --keep-days requires a number argument" >&2; exit 1; }
        KEEP_DAYS="$2"
        shift 2
        ;;
      --keep-weeks)
        test $# -ge 2 || { echo "Error: --keep-weeks requires a number argument" >&2; exit 1; }
        KEEP_WEEKS="$2"
        shift 2
        ;;
      --keep-last)
        test $# -ge 2 || { echo "Error: --keep-last requires a number argument" >&2; exit 1; }
        KEEP_LAST="$2"
        shift 2
        ;;
      --source-mode)
        test $# -ge 2 || { echo "Error: --source-mode requires a mode argument" >&2; exit 1; }
        SOURCE_MODE="$2"
        shift 2
        ;;
      --source-dir)
        test $# -ge 2 || { echo "Error: --source-dir requires a directory argument" >&2; exit 1; }
        SOURCE_DIR="$2"
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
        test $# -ge 2 || { echo "Error: --vault-container requires a container name argument" >&2; exit 1; }
        VAULT_CONTAINER="$2"
        shift 2
        ;;
      --vault-volume)
        test $# -ge 2 || { echo "Error: --vault-volume requires a volume name argument" >&2; exit 1; }
        VAULT_VOLUME="$2"
        shift 2
        ;;
      --keep-local)
        KEEP_LOCAL=true
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

validate_inputs() {
  if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]]; then
    echo "Error: --keep-days must be a non-negative integer" >&2
    exit 1
  fi
  if ! [[ "$KEEP_WEEKS" =~ ^[0-9]+$ ]]; then
    echo "Error: --keep-weeks must be a non-negative integer" >&2
    exit 1
  fi
  if ! [[ "$KEEP_LAST" =~ ^[0-9]+$ ]]; then
    echo "Error: --keep-last must be a non-negative integer" >&2
    exit 1
  fi

  if ! command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
    echo "Error: '${RCLONE_BIN}' binary not found. Install rclone or run 'make backup-setup'." >&2
    exit 1
  fi

  if [ -n "$DEST" ]; then
    if [[ "$DEST" == *:* ]]; then
      REMOTE="${DEST%%:*}"
      local path_part="${DEST#*:}"
      path_part="${path_part#/}"
      path_part="${path_part%/}"
      REMOTE_PATH="$path_part"
      TARGET="${REMOTE}:${REMOTE_PATH}"
    else
      TARGET="${DEST%/}"
    fi
  else
    local cleaned_path="${REMOTE_PATH#/}"
    cleaned_path="${cleaned_path%/}"
    TARGET="${REMOTE}:${cleaned_path}"
  fi

  if [[ "$TARGET" == *:* ]] && [ ! -f "${RCLONE_CONFIG}" ] && [ "$DRY_RUN" != "true" ]; then
    echo "Error: Rclone configuration file not found at '${RCLONE_CONFIG}'. Run 'make backup-setup' first." >&2
    exit 1
  fi
}

run_rclone() {
  local cmd=("$RCLONE_BIN")
  if [ -n "${RCLONE_CONFIG}" ] && [ -f "${RCLONE_CONFIG}" ]; then
    cmd+=("--config" "${RCLONE_CONFIG}")
  fi
  "${cmd[@]}" "$@"
}

detect_vault_storage_mode() {
  if [ -n "${SOURCE_DIR}" ] && [ -d "${SOURCE_DIR}" ]; then
    echo "dir"
    return 0
  fi

  if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    local storage_type
    storage_type=$(curl -s "${VAULT_ADDR}/v1/sys/health" 2>/dev/null | jq -r '.storage_type // empty' 2>/dev/null || true)
    if [ "$storage_type" = "raft" ]; then
      echo "raft"
      return 0
    fi
  fi

  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${VAULT_CONTAINER}"; then
    echo "docker"
    return 0
  fi

  if command -v docker >/dev/null 2>&1 && docker volume inspect "${VAULT_VOLUME}" >/dev/null 2>&1; then
    echo "volume"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "simulated"
    return 0
  fi

  echo "Error: Could not detect active Vault storage. Ensure Vault is running or specify --source-dir / --source-mode." >&2
  return 1
}

create_snapshot() {
  local out_file="$1"
  local mode="$SOURCE_MODE"

  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] Would create Vault snapshot (${mode}) at: ${out_file}"
    return 0
  fi

  if [ "$mode" = "auto" ]; then
    mode=$(detect_vault_storage_mode)
  fi

  local staging_dir
  staging_dir=$(mktemp -d /tmp/vault-snap-stage.XXXXXX)
  local data_dir="${staging_dir}/data"
  mkdir -p "$data_dir"

  local storage_type="$mode"
  case "$mode" in
    raft)
      echo "Creating Vault Raft storage snapshot..."
      local snap_file="${staging_dir}/vault.snap"
      local saved=false

      if curl -sf -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/storage/raft/snapshot" -o "$snap_file" 2>/dev/null && [ -s "$snap_file" ]; then
        saved=true
      elif command -v vault >/dev/null 2>&1 && VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" vault operator raft snapshot save "$snap_file" >/dev/null 2>&1 && [ -s "$snap_file" ]; then
        saved=true
      elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${VAULT_CONTAINER}"; then
        docker exec -e VAULT_ADDR="http://127.0.0.1:8200" -e VAULT_TOKEN="${VAULT_TOKEN}" "${VAULT_CONTAINER}" vault operator raft snapshot save /tmp/raft.snap >/dev/null 2>&1 || true
        if docker cp "${VAULT_CONTAINER}:/tmp/raft.snap" "$snap_file" 2>/dev/null; then
          docker exec "${VAULT_CONTAINER}" rm -f /tmp/raft.snap >/dev/null 2>&1 || true
          if [ -s "$snap_file" ]; then saved=true; fi
        fi
      fi

      if [ "$saved" != "true" ]; then
        rm -rf "$staging_dir"
        echo "Error: Failed to create Vault Raft snapshot. Ensure Raft storage is configured and unsealed." >&2
        return 1
      fi
      ;;
    docker)
      echo "Archiving Vault file storage from running container '${VAULT_CONTAINER}'..."
      if ! docker exec "${VAULT_CONTAINER}" tar -czf - -C /vault/file . | tar -xzf - -C "$data_dir" 2>/dev/null; then
        rm -rf "$staging_dir"
        echo "Error: Failed to archive /vault/file from container '${VAULT_CONTAINER}'." >&2
        return 1
      fi
      ;;
    volume)
      echo "Archiving Vault Docker volume '${VAULT_VOLUME}' via read-only container mount..."
      if ! docker run --rm -v "${VAULT_VOLUME}:/vault-data:ro" -v "${data_dir}:/backup" alpine cp -a /vault-data/. /backup/ 2>/dev/null; then
        rm -rf "$staging_dir"
        echo "Error: Failed to archive Docker volume '${VAULT_VOLUME}'." >&2
        return 1
      fi
      ;;
    dir|file)
      test -n "${SOURCE_DIR}" || { rm -rf "$staging_dir"; echo "Error: --source-dir required for dir storage mode" >&2; return 1; }
      test -d "${SOURCE_DIR}" || { rm -rf "$staging_dir"; echo "Error: Source directory '${SOURCE_DIR}' does not exist" >&2; return 1; }
      echo "Archiving Vault storage from directory: ${SOURCE_DIR}"
      cp -a "${SOURCE_DIR}/." "$data_dir/"
      ;;
    simulated)
      echo "Simulated dry-run snapshot payload" > "${data_dir}/vault.dryrun"
      ;;
    *)
      rm -rf "$staging_dir"
      echo "Error: Unknown source mode '${mode}'" >&2
      return 1
      ;;
  esac

  local now_iso
  now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat <<METADATA > "${staging_dir}/metadata.json"
{
  "timestamp": "${now_iso}",
  "filename": "$(basename "${out_file}")",
  "storage_type": "${storage_type}",
  "vault_addr": "${VAULT_ADDR}",
  "vault_container": "${VAULT_CONTAINER}",
  "backup_version": "1.0"
}
METADATA

  mkdir -p "$(dirname "$out_file")"
  tar -czf "$out_file" -C "$staging_dir" .
  rm -rf "$staging_dir"

  test -s "$out_file" || { echo "Error: Generated archive '$out_file' is empty." >&2; return 1; }
  echo "Snapshot successfully created at: ${out_file} ($(stat -c "%s" "$out_file" 2>/dev/null || stat -f "%z" "$out_file" 2>/dev/null) bytes)"
}

verify_upload() {
  local local_file="$1"
  local target="$2"
  local filename="$3"

  local local_size
  local_size=$(stat -c "%s" "$local_file" 2>/dev/null || stat -f "%z" "$local_file" 2>/dev/null)

  local remote_files
  remote_files=$(run_rclone lsf --files-only "${target}" 2>/dev/null || true)
  if ! echo "$remote_files" | grep -qx "$filename"; then
    echo "Error: Upload verification failed: '$filename' not found on remote '${target}'." >&2
    return 1
  fi

  local remote_size
  remote_size=$(run_rclone size --json "${target}/${filename}" 2>/dev/null | jq -r '.bytes // empty' 2>/dev/null || true)
  if [ -n "$remote_size" ] && [ "$remote_size" != "null" ]; then
    if [ "$remote_size" -ne "$local_size" ]; then
      echo "Error: Upload verification size mismatch: expected ${local_size} bytes, remote is ${remote_size} bytes." >&2
      return 1
    fi
  fi

  echo "Upload verified successfully: ${target}/${filename} (${local_size} bytes)"
}

upload_snapshot() {
  local archive_path="$1"
  local target="$2"
  local filename="$3"

  if [ "$DRY_RUN" = "true" ]; then
    echo "[dry-run] Would upload ${archive_path} to ${target}/${filename}"
    echo "[dry-run] Would verify remote file ${target}/${filename}"
    return 0
  fi

  test -f "$archive_path" || { echo "Error: Archive '$archive_path' does not exist." >&2; return 1; }
  test -s "$archive_path" || { echo "Error: Archive '$archive_path' is empty." >&2; return 1; }

  local archive_size
  archive_size=$(stat -c "%s" "$archive_path" 2>/dev/null || stat -f "%z" "$archive_path" 2>/dev/null)

  echo "Uploading backup archive (${archive_size} bytes): ${archive_path} -> ${target}/${filename}"

  run_rclone copyto "${archive_path}" "${target}/${filename}"
  verify_upload "${archive_path}" "${target}" "${filename}"
}

prune_backups() {
  local target="$1"
  local keep_days="$2"
  local keep_weeks="$3"
  local keep_last="$4"
  local current_backup="${5:-}"

  echo "Evaluating retention policy on remote: ${target}"
  echo "Retention rules: keep last ${keep_days} daily, ${keep_weeks} weekly, min ${keep_last} backups."

  local raw_files
  raw_files=$(run_rclone lsf --files-only "${target}" 2>/dev/null || true)
  if [ -z "$raw_files" ]; then
    echo "No existing backups found at '${target}'. Nothing to prune."
    return 0
  fi

  local matching_files=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ ^vault-backup-[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
      matching_files+=("$line")
    fi
  done <<< "$raw_files"

  if [ ${#matching_files[@]} -eq 0 ]; then
    echo "No Vault backup archives found at '${target}'. Nothing to prune."
    return 0
  fi

  local sorted_files=()
  IFS=$'\n' sorted_files=($(sort -r <<<"${matching_files[*]}")); unset IFS

  declare -A kept_files
  declare -A seen_days
  declare -A daily_weeks
  declare -A seen_weekly_weeks
  local day_count=0
  local weekly_count=0
  local idx=0

  if [ -n "$current_backup" ]; then
    kept_files["$current_backup"]="current run"
  fi

  for f in "${sorted_files[@]}"; do
    idx=$((idx + 1))
    if [ "$idx" -le "$keep_last" ]; then
      kept_files["$f"]="${kept_files[$f]:-keep-last ($idx/$keep_last)}"
    fi

    local ts="${f#vault-backup-}"
    ts="${ts%.tar.gz}"
    local d="${ts:0:8}"
    local fmt_d="${d:0:4}-${d:4:2}-${d:6:2}"
    local w
    w=$(date -d "$fmt_d" +%G-W%V 2>/dev/null || true)

    if [ -n "$d" ]; then
      if [ -z "${seen_days[$d]:-}" ]; then
        day_count=$((day_count + 1))
        seen_days["$d"]=1
        if [ "$day_count" -le "$keep_days" ]; then
          kept_files["$f"]="${kept_files[$f]:-daily ($fmt_d)}"
          if [ -n "$w" ]; then
            daily_weeks["$w"]=1
          fi
        fi
      fi
    fi
  done

  for f in "${sorted_files[@]}"; do
    if [ -n "${kept_files[$f]:-}" ]; then
      continue
    fi

    local ts="${f#vault-backup-}"
    ts="${ts%.tar.gz}"
    local d="${ts:0:8}"
    local fmt_d="${d:0:4}-${d:4:2}-${d:6:2}"
    local w
    w=$(date -d "$fmt_d" +%G-W%V 2>/dev/null || true)

    if [ -n "$w" ] && [ -z "${daily_weeks[$w]:-}" ]; then
      if [ -z "${seen_weekly_weeks[$w]:-}" ]; then
        weekly_count=$((weekly_count + 1))
        seen_weekly_weeks["$w"]=1
        if [ "$weekly_count" -le "$keep_weeks" ]; then
          kept_files["$f"]="weekly ($w)"
        fi
      fi
    fi
  done

  local pruned_count=0
  for f in "${sorted_files[@]}"; do
    if [ -z "${kept_files[$f]:-}" ]; then
      pruned_count=$((pruned_count + 1))
      if [ "$DRY_RUN" = "true" ]; then
        echo "[dry-run] Would prune remote backup: ${target}/${f}"
      else
        echo "Pruning remote backup: ${target}/${f}"
        run_rclone deletefile "${target}/${f}"
      fi
    fi
  done

  if [ "$pruned_count" -eq 0 ]; then
    echo "No remote backups require pruning."
  else
    echo "Pruning complete: removed ${pruned_count} backup(s)."
  fi
}

cmd_status() {
  echo "==> Vault Status"
  if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
    echo "Vault server: Reachable at ${VAULT_ADDR}"
    curl -s "${VAULT_ADDR}/v1/sys/health" | jq . 2>/dev/null || curl -s "${VAULT_ADDR}/v1/sys/health"
  elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${VAULT_CONTAINER}"; then
    echo "Vault container: '${VAULT_CONTAINER}' is running."
    docker exec "${VAULT_CONTAINER}" vault status 2>/dev/null || true
  else
    echo "Vault server: Not reachable at ${VAULT_ADDR} and container '${VAULT_CONTAINER}' not running."
  fi

  echo ""
  echo "==> Remote Backups at ${TARGET}"
  run_rclone lsf --files-only "${TARGET}" 2>/dev/null || echo "No backups found or target unreachable."
}

cmd_backup() {
  local archive_path="${OUTPUT_DIR}/${FILENAME}"
  mkdir -p "${OUTPUT_DIR}"

  create_snapshot "${archive_path}"
  upload_snapshot "${archive_path}" "${TARGET}" "${FILENAME}"
  prune_backups "${TARGET}" "${KEEP_DAYS}" "${KEEP_WEEKS}" "${KEEP_LAST}" "${FILENAME}"

  if [ "$KEEP_LOCAL" != "true" ] && [ -f "$archive_path" ]; then
    rm -f "$archive_path"
    echo "Cleaned up temporary local archive: ${archive_path}"
  elif [ -f "$archive_path" ]; then
    echo "Preserved local archive at: ${archive_path}"
  fi

  echo "Vault backup completed successfully."
}

cmd_snapshot() {
  local archive_path="${OUTPUT_DIR}/${FILENAME}"
  mkdir -p "${OUTPUT_DIR}"

  create_snapshot "${archive_path}"
  echo "Snapshot archive created at: ${archive_path}"
}

cmd_upload() {
  test -n "$EXPLICIT_FILE" || { echo "Error: 'upload' command requires --file <archive_path>" >&2; exit 1; }
  test -f "$EXPLICIT_FILE" || { echo "Error: File '$EXPLICIT_FILE' not found." >&2; exit 1; }

  local fname
  fname=$(basename "$EXPLICIT_FILE")
  upload_snapshot "$EXPLICIT_FILE" "${TARGET}" "$fname"
  prune_backups "${TARGET}" "${KEEP_DAYS}" "${KEEP_WEEKS}" "${KEEP_LAST}" "$fname"
}

cmd_prune() {
  prune_backups "${TARGET}" "${KEEP_DAYS}" "${KEEP_WEEKS}" "${KEEP_LAST}" ""
}

main() {
  parse_args "$@"
  validate_inputs

  case "$ACTION" in
    backup)
      cmd_backup
      ;;
    snapshot)
      cmd_snapshot
      ;;
    upload)
      cmd_upload
      ;;
    prune)
      cmd_prune
      ;;
    status)
      cmd_status
      ;;
    *)
      echo "Error: Unknown action '${ACTION}'" >&2
      show_usage >&2
      exit 1
      ;;
  esac
}

main "$@"
