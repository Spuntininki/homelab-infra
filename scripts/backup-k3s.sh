#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive-crypt:homelab-backups/k3s}"
STORAGE_DIR="${STORAGE_DIR:-${K3S_STORAGE_DIR:-/var/lib/rancher/k3s/storage}}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/k3s-backup}"
BACKUP_TIMESTAMP="${BACKUP_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
RETENTION_DAILY="${RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-4}"
SKIP_DB="${SKIP_DB:-false}"
SKIP_PVC="${SKIP_PVC:-false}"
SKIP_UPLOAD="${SKIP_UPLOAD:-false}"
SKIP_PRUNE="${SKIP_PRUNE:-false}"
KEEP_LOCAL="${KEEP_LOCAL:-false}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-false}"
DRY_RUN="${DRY_RUN:-false}"
ACTION="all"

TARGET_NAMESPACES=()
SYSTEM_NAMESPACES=("kube-system" "kube-public" "kube-node-lease" "cert-manager" "external-secrets")

show_usage() {
  cat <<'EOF'
Usage: backup-k3s.sh [COMMAND] [OPTIONS]

K3s persistent volume and database dump pipeline with encrypted remote sync.

Commands:
  all             Run full pipeline: dump DBs, archive PVCs, bundle, upload, and prune (default)
  dump-db         Run database dumps only
  backup-pvc      Run PVC archives only
  bundle          Create compressed backup bundle from staged artifacts
  upload          Upload existing bundle to remote storage
  prune           Run retention pruning against remote storage
  list            List remote backups and their retention status

Options:
  -c, --config <PATH>          Path to rclone.conf (default: ~/.config/rclone/rclone.conf)
  -r, --remote <REMOTE:PATH>   Destination remote path (default: gdrive-crypt:homelab-backups/k3s)
  -d, --backup-dir <DIR>       Staging and output directory (default: /tmp/k3s-backup)
  -s, --storage-dir <DIR>      Path to local-path PVC storage (default: /var/lib/rancher/k3s/storage)
  -n, --namespace <NAME>       Target specific namespace (can be specified multiple times)
      --retention-daily <N>    Number of daily backups to retain (default: 7)
      --retention-weekly <N>   Number of weekly backups to retain (default: 4)
      --timestamp <TS>         Custom timestamp for backup naming (format: YYYYMMDD_HHMMSS)
      --kubectl-bin <PATH>     Path to kubectl binary (default: kubectl)
      --rclone-bin <PATH>      Path to rclone binary (default: rclone)
      --skip-db                Skip database dumps
      --skip-pvc               Skip persistent volume archives
      --skip-upload            Skip remote upload step
      --skip-prune             Skip remote retention pruning step
      --keep-local             Keep local backup staging directory after upload
      --continue-on-error      Log errors and proceed rather than failing immediately
      --dry-run                Simulate actions without writing archives or modifying remote
  -h, --help                   Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      all|dump-db|backup-pvc|bundle|upload|prune|list)
        ACTION="$1"
        shift
        ;;
      -c|--config)
        test $# -ge 2 || { echo "Error: --config requires a path argument" >&2; exit 1; }
        RCLONE_CONFIG="$2"
        shift 2
        ;;
      -r|--remote|--remote-path)
        test $# -ge 2 || { echo "Error: $1 requires a remote path argument" >&2; exit 1; }
        RCLONE_REMOTE="$2"
        shift 2
        ;;
      -d|--backup-dir)
        test $# -ge 2 || { echo "Error: --backup-dir requires a directory argument" >&2; exit 1; }
        BACKUP_DIR="$2"
        shift 2
        ;;
      -s|--storage-dir)
        test $# -ge 2 || { echo "Error: --storage-dir requires a directory argument" >&2; exit 1; }
        STORAGE_DIR="$2"
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
      --retention-daily)
        test $# -ge 2 || { echo "Error: --retention-daily requires an integer argument" >&2; exit 1; }
        RETENTION_DAILY="$2"
        shift 2
        ;;
      --retention-weekly)
        test $# -ge 2 || { echo "Error: --retention-weekly requires an integer argument" >&2; exit 1; }
        RETENTION_WEEKLY="$2"
        shift 2
        ;;
      --timestamp)
        test $# -ge 2 || { echo "Error: --timestamp requires a timestamp argument" >&2; exit 1; }
        BACKUP_TIMESTAMP="$2"
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
      --skip-db)
        SKIP_DB=true
        shift
        ;;
      --skip-pvc)
        SKIP_PVC=true
        shift
        ;;
      --skip-upload)
        SKIP_UPLOAD=true
        shift
        ;;
      --skip-prune)
        SKIP_PRUNE=true
        shift
        ;;
      --keep-local)
        KEEP_LOCAL=true
        shift
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
}

get_staging_dir() {
  echo "${BACKUP_DIR}/k3s-backup-${BACKUP_TIMESTAMP}"
}

get_bundle_path() {
  echo "${BACKUP_DIR}/k3s-backup-${BACKUP_TIMESTAMP}.tar.gz"
}

is_system_namespace() {
  local target="$1"
  for sys in "${SYSTEM_NAMESPACES[@]}"; do
    if [[ "$target" == "$sys" ]]; then
      return 0
    fi
  done
  return 1
}

verify_prerequisites() {
  local required_tools=()

  if [[ "$ACTION" =~ ^(all|dump-db)$ ]] && [[ "$SKIP_DB" != "true" ]]; then
    required_tools+=("${KUBECTL_BIN}" "jq" "gzip")
  fi

  if [[ "$ACTION" =~ ^(all|backup-pvc|bundle)$ ]]; then
    required_tools+=("tar" "gzip")
  fi

  if [[ "$ACTION" =~ ^(all|upload|prune|list)$ ]] && [[ "$SKIP_UPLOAD" != "true" || "$ACTION" == "prune" || "$ACTION" == "list" ]]; then
    required_tools+=("${RCLONE_BIN}")
  fi

  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      if [[ "$tool" == "${RCLONE_BIN}" ]]; then
        echo "Error: rclone binary not found at '${RCLONE_BIN}'." >&2
        echo "Run 'make backup-setup' or 'scripts/backup-setup.sh' to install and configure it." >&2
      elif [[ "$tool" == "${KUBECTL_BIN}" ]]; then
        echo "Error: kubectl binary not found at '${KUBECTL_BIN}'. Ensure kubectl is installed or pass --skip-db." >&2
      else
        echo "Error: Required command '$tool' is not installed or not in PATH." >&2
      fi
      return 1
    fi
  done

  if [[ "$ACTION" =~ ^(all|upload|prune|list)$ ]] && [[ "$DRY_RUN" != "true" ]]; then
    if [[ "$SKIP_UPLOAD" != "true" || "$ACTION" == "prune" || "$ACTION" == "list" ]]; then
      if [[ -n "${RCLONE_CONFIG}" && ! -f "${RCLONE_CONFIG}" ]]; then
        echo "Error: Rclone config file not found at '${RCLONE_CONFIG}'." >&2
        echo "Run 'make backup-setup' to generate configuration from Vault." >&2
        return 1
      fi
    fi
  fi

  return 0
}

discover_database_workloads() {
  local namespaces=()
  if [[ ${#TARGET_NAMESPACES[@]} -gt 0 ]]; then
    namespaces=("${TARGET_NAMESPACES[@]}")
  else
    local all_ns
    if ! all_ns=$("${KUBECTL_BIN}" get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); then
      echo "Warning: Unable to list namespaces via kubectl." >&2
      return 1
    fi
    for ns in $all_ns; do
      if ! is_system_namespace "$ns"; then
        namespaces+=("$ns")
      fi
    done
  fi

  for ns in "${namespaces[@]}"; do
    local pod_json
    if ! pod_json=$("${KUBECTL_BIN}" get pods -n "$ns" -o json 2>/dev/null); then
      continue
    fi

    echo "$pod_json" | jq -r '
      .items[]?
      | select(.status.phase == "Running")
      | .metadata.name as $pod
      | .metadata.namespace as $ns
      | .metadata.labels as $labels
      | .spec.containers[]?
      | {
          ns: $ns,
          pod: $pod,
          container: .name,
          image: .image,
          type: (
            if (.image | test("postgres|postgresql"; "i")) or (.name | test("postgres|postgresql"; "i")) or (($labels["app.kubernetes.io/name"] // "") | test("postgres|postgresql"; "i")) or (($labels["app"] // "") | test("postgres|postgresql"; "i")) then
              "postgres"
            elif (.image | test("mysql|mariadb"; "i")) or (.name | test("mysql|mariadb"; "i")) or (($labels["app.kubernetes.io/name"] // "") | test("mysql|mariadb"; "i")) or (($labels["app"] // "") | test("mysql|mariadb"; "i")) then
              "mysql"
            else
              empty
            end
          )
        }
      | select(.type != null)
      | "\(.ns)\t\(.pod)\t\(.container)\t\(.type)"
    '
  done
}

dump_databases() {
  if [[ "$SKIP_DB" == "true" ]]; then
    echo "Skipping database dumps (--skip-db specified)."
    return 0
  fi

  local staging_dir
  staging_dir="$(get_staging_dir)"
  local db_dir="${staging_dir}/databases"
  if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$db_dir"
  fi

  echo "==> Discovering database workloads across K3s namespaces..."
  local discovered=()
  while IFS=$'\t' read -r ns pod container db_type; do
    [[ -z "$ns" ]] && continue
    discovered+=("${ns}:${pod}:${container}:${db_type}")
  done < <(discover_database_workloads || true)

  if [[ ${#discovered[@]} -eq 0 ]]; then
    echo "No running database workloads detected in target namespaces."
    return 0
  fi

  echo "Discovered ${#discovered[@]} database workload(s) for backup."

  for entry in "${discovered[@]}"; do
    IFS=':' read -r ns pod container db_type <<< "$entry"
    local dump_filename="${ns}_${pod}_${db_type}.sql.gz"
    local dump_path="${db_dir}/${dump_filename}"

    echo "Dumping database '${db_type}' from ${ns}/${pod} (container: ${container})..."

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] Would execute application-level dump: ${KUBECTL_BIN} exec -i -n ${ns} ${pod} -c ${container} | gzip > ${dump_path}"
      continue
    fi

    local dump_status=0
    if [[ "$db_type" == "postgres" ]]; then
      set +e
      "${KUBECTL_BIN}" exec -i -n "${ns}" "${pod}" -c "${container}" -- sh -c '
        USER="${POSTGRES_USER:-postgres}"
        if command -v pg_dumpall >/dev/null 2>&1; then
          pg_dumpall -U "$USER" --clean
        else
          pg_dump -U "$USER" "${POSTGRES_DB:-postgres}"
        fi
      ' 2>/dev/null | gzip -c > "${dump_path}"
      dump_status=$?
      set -e
    elif [[ "$db_type" == "mysql" ]]; then
      set +e
      "${KUBECTL_BIN}" exec -i -n "${ns}" "${pod}" -c "${container}" -- sh -c '
        PASS_ARG=""
        if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
          PASS_ARG="-p${MYSQL_ROOT_PASSWORD}"
        elif [ -n "${MARIADB_ROOT_PASSWORD:-}" ]; then
          PASS_ARG="-p${MARIADB_ROOT_PASSWORD}"
        fi
        USER="${MYSQL_USER:-root}"
        if command -v mariadb-dump >/dev/null 2>&1; then
          mariadb-dump --all-databases -u "$USER" ${PASS_ARG} --single-transaction --quick
        else
          mysqldump --all-databases -u "$USER" ${PASS_ARG} --single-transaction --quick
        fi
      ' 2>/dev/null | gzip -c > "${dump_path}"
      dump_status=$?
      set -e
    fi

    if [[ $dump_status -ne 0 || ! -s "${dump_path}" ]]; then
      rm -f "${dump_path}"
      echo "Error: Database dump failed for ${ns}/${pod} (${db_type})." >&2
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        return 1
      fi
      echo "Warning: Database dump failed for ${ns}/${pod}; continuing due to --continue-on-error." >&2
      continue
    fi

    if ! gzip -t "${dump_path}" 2>/dev/null; then
      rm -f "${dump_path}"
      echo "Error: Dump archive failed compression integrity test for ${ns}/${pod}." >&2
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        return 1
      fi
      echo "Warning: Database dump integrity check failed for ${ns}/${pod}; continuing due to --continue-on-error." >&2
      continue
    fi

    local dump_size
    dump_size=$(wc -c < "${dump_path}" | tr -d ' ')
    echo "Successfully dumped ${ns}/${pod} (${dump_size} bytes, integrity verified)."
  done

  return 0
}

archive_pvcs() {
  if [[ "$SKIP_PVC" == "true" ]]; then
    echo "Skipping PVC archives (--skip-pvc specified)."
    return 0
  fi

  local staging_dir
  staging_dir="$(get_staging_dir)"
  local pvc_dir="${staging_dir}/pvcs"
  if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$pvc_dir"
  fi

  echo "==> Archiving active local-path PVCs from '${STORAGE_DIR}'..."

  if [[ ! -d "${STORAGE_DIR}" ]]; then
    echo "Notice: Storage directory '${STORAGE_DIR}' does not exist or is not mounted. Skipping PVC archive."
    return 0
  fi

  local pvc_entries=()
  while IFS= read -r -d $'\0' entry; do
    [[ -z "$entry" ]] && continue
    local bname
    bname=$(basename "$entry")
    if [[ ${#TARGET_NAMESPACES[@]} -gt 0 ]]; then
      local matched=false
      for ns in "${TARGET_NAMESPACES[@]}"; do
        if [[ "$bname" == *"_${ns}_"* || "$bname" == "${ns}"* || "$bname" == *"_${ns}" ]]; then
          matched=true
          break
        fi
      done
      if [[ "$matched" == "true" ]]; then
        pvc_entries+=("$bname")
      fi
    else
      pvc_entries+=("$bname")
    fi
  done < <(find "${STORAGE_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  if [[ ${#pvc_entries[@]} -eq 0 ]]; then
    echo "No matching PVC storage directories found in '${STORAGE_DIR}'."
    return 0
  fi

  echo "Found ${#pvc_entries[@]} PVC storage director(ies) to archive."

  for entry_name in "${pvc_entries[@]}"; do
    local tar_filename="${entry_name}.tar.gz"
    local tar_path="${pvc_dir}/${tar_filename}"

    echo "Archiving PVC '${entry_name}'..."

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] Would archive PVC '${STORAGE_DIR}/${entry_name}' -> '${tar_path}'"
      continue
    fi

    set +e
    tar -czf "${tar_path}" -C "${STORAGE_DIR}" "${entry_name}" 2>/dev/null
    local tar_status=$?
    set -e

    if [[ $tar_status -ne 0 || ! -s "${tar_path}" ]]; then
      rm -f "${tar_path}"
      echo "Error: Failed to create archive for PVC '${entry_name}'." >&2
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        return 1
      fi
      echo "Warning: Failed to create archive for PVC '${entry_name}'; continuing due to --continue-on-error." >&2
      continue
    fi

    if ! tar -tzf "${tar_path}" >/dev/null 2>&1; then
      rm -f "${tar_path}"
      echo "Error: PVC archive '${entry_name}' failed tar integrity check." >&2
      if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
        return 1
      fi
      echo "Warning: PVC archive '${entry_name}' failed tar integrity check; continuing due to --continue-on-error." >&2
      continue
    fi

    local tar_size
    tar_size=$(wc -c < "${tar_path}" | tr -d ' ')
    echo "Successfully archived PVC '${entry_name}' (${tar_size} bytes)."
  done

  return 0
}

create_bundle() {
  local staging_dir
  staging_dir="$(get_staging_dir)"
  local bundle_path
  bundle_path="$(get_bundle_path)"
  local bundle_name
  bundle_name=$(basename "$bundle_path")
  local manifest_path="${staging_dir}/manifest.json"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would package bundle archive '${bundle_path}' from '${staging_dir}'"
    return 0
  fi

  mkdir -p "$staging_dir"

  echo "==> Generating backup manifest and consolidated bundle..."

  local db_files=()
  if [[ -d "${staging_dir}/databases" ]]; then
    while IFS= read -r -d $'\0' f; do
      [[ -z "$f" ]] && continue
      db_files+=("$(basename "$f")")
    done < <(find "${staging_dir}/databases" -maxdepth 1 -type f -name '*.sql.gz' -print0 2>/dev/null || true)
  fi

  local pvc_files=()
  if [[ -d "${staging_dir}/pvcs" ]]; then
    while IFS= read -r -d $'\0' f; do
      [[ -z "$f" ]] && continue
      pvc_files+=("$(basename "$f")")
    done < <(find "${staging_dir}/pvcs" -maxdepth 1 -type f -name '*.tar.gz' -print0 2>/dev/null || true)
  fi

  local db_json="[]"
  if [[ ${#db_files[@]} -gt 0 ]]; then
    db_json=$(printf '%s\n' "${db_files[@]}" | jq -R . | jq -s .)
  fi

  local pvc_json="[]"
  if [[ ${#pvc_files[@]} -gt 0 ]]; then
    pvc_json=$(printf '%s\n' "${pvc_files[@]}" | jq -R . | jq -s .)
  fi

  cat <<EOF > "$manifest_path"
{
  "timestamp": "${BACKUP_TIMESTAMP}",
  "created_at": "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)",
  "bundle_name": "${bundle_name}",
  "databases": ${db_json},
  "pvcs": ${pvc_json}
}
EOF

  local staging_basename
  staging_basename=$(basename "$staging_dir")
  tar -czf "${bundle_path}" -C "${BACKUP_DIR}" "${staging_basename}"
  tar -tzf "${bundle_path}" >/dev/null

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "${BACKUP_DIR}" && sha256sum "${bundle_name}" > "${bundle_path}.sha256")
  fi

  local bundle_size
  bundle_size=$(wc -c < "${bundle_path}" | tr -d ' ')
  echo "Consolidated archive created: ${bundle_path} (${bundle_size} bytes)."
}

upload_bundle() {
  if [[ "$SKIP_UPLOAD" == "true" ]]; then
    echo "Skipping remote upload (--skip-upload specified)."
    return 0
  fi

  local bundle_path
  bundle_path="$(get_bundle_path)"
  local staging_dir
  staging_dir="$(get_staging_dir)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] Would upload '${bundle_path}' to '${RCLONE_REMOTE}/'"
    return 0
  fi

  if [[ ! -f "$bundle_path" ]]; then
    echo "Error: Bundle archive not found at '${bundle_path}'." >&2
    return 1
  fi

  echo "==> Uploading backup archive to '${RCLONE_REMOTE}/' via rclone..."
  local rclone_args=()
  if [[ -f "${RCLONE_CONFIG}" ]]; then
    rclone_args+=("--config" "${RCLONE_CONFIG}")
  fi

  "${RCLONE_BIN}" "${rclone_args[@]}" copy "${bundle_path}" "${RCLONE_REMOTE}/"
  if [[ -f "${bundle_path}.sha256" ]]; then
    "${RCLONE_BIN}" "${rclone_args[@]}" copy "${bundle_path}.sha256" "${RCLONE_REMOTE}/"
  fi

  echo "Upload complete: $(basename "${bundle_path}") successfully transferred to ${RCLONE_REMOTE}/"

  if [[ "$KEEP_LOCAL" != "true" ]]; then
    rm -rf "$staging_dir" "$bundle_path" "${bundle_path}.sha256"
  fi

  return 0
}

get_date_from_filename() {
  local filename="$1"
  local stem="${filename#k3s-backup-}"
  local ts="${stem%%.tar.gz}"
  local ymd="${ts%%_*}"
  echo "${ymd:0:4}-${ymd:4:2}-${ymd:6:2}"
}

get_week_from_date() {
  local date_str="$1"
  date -d "$date_str" +%Y-W%V 2>/dev/null || echo "${date_str:0:4}-W00"
}

compute_retention() {
  local rclone_args=()
  if [[ -f "${RCLONE_CONFIG}" ]]; then
    rclone_args+=("--config" "${RCLONE_CONFIG}")
  fi

  local raw_files
  raw_files=$("${RCLONE_BIN}" "${rclone_args[@]}" lsf "${RCLONE_REMOTE}" --files-only 2>/dev/null || true)

  local backup_files=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^k3s-backup-[0-9]{8}_[0-9]{6}\.tar\.gz$ ]]; then
      backup_files+=("$line")
    fi
  done <<< "$raw_files"

  if [[ ${#backup_files[@]} -eq 0 ]]; then
    return 0
  fi

  readarray -t sorted < <(printf '%s\n' "${backup_files[@]}" | sort -r)

  declare -A seen_days
  declare -A seen_weeks
  local kept_daily_count=0
  local kept_weekly_count=0
  local latest_day=""

  for f in "${sorted[@]}"; do
    local d
    d=$(get_date_from_filename "$f")
    local w
    w=$(get_week_from_date "$d")
    local keep=false
    local reason=""

    if [[ -z "$latest_day" ]]; then
      latest_day="$d"
    fi

    if [[ "$d" == "$latest_day" ]]; then
      keep=true
      reason="latest-day"
    fi

    if [[ -z "${seen_days[$d]:-}" ]]; then
      seen_days[$d]=1
      if [[ $kept_daily_count -lt $RETENTION_DAILY ]]; then
        kept_daily_count=$((kept_daily_count + 1))
        keep=true
        reason="${reason:+$reason,}daily"
      fi
    fi

    if [[ -z "${seen_weeks[$w]:-}" ]]; then
      seen_weeks[$w]=1
      if [[ $kept_weekly_count -lt $RETENTION_WEEKLY ]]; then
        kept_weekly_count=$((kept_weekly_count + 1))
        keep=true
        reason="${reason:+$reason,}weekly"
      fi
    fi

    if [[ "$keep" == "true" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "KEEP" "${f}" "${reason}" "${d}" "${w}"
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "PRUNE" "${f}" "exceeded-retention" "${d}" "${w}"
    fi
  done
}

prune_remote_backups() {
  if [[ "$SKIP_PRUNE" == "true" ]]; then
    echo "Skipping retention pruning (--skip-prune specified)."
    return 0
  fi

  if [[ "$RETENTION_DAILY" -eq 0 && "$RETENTION_WEEKLY" -eq 0 ]]; then
    echo "Retention pruning disabled (thresholds set to 0)."
    return 0
  fi

  echo "==> Evaluating remote backup retention policy (keep last ${RETENTION_DAILY} daily, ${RETENTION_WEEKLY} weekly)..."

  local rclone_args=()
  if [[ -f "${RCLONE_CONFIG}" ]]; then
    rclone_args+=("--config" "${RCLONE_CONFIG}")
  fi

  local pruned_count=0
  local kept_count=0

  while IFS=$'\t' read -r action file reason d w; do
    [[ -z "$action" ]] && continue
    if [[ "$action" == "PRUNE" ]]; then
      pruned_count=$((pruned_count + 1))
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[dry-run] Would prune remote backup: ${RCLONE_REMOTE}/${file} (${reason}, date=${d})"
      else
        echo "Pruning remote backup: ${file} (${reason}, date=${d})..."
        "${RCLONE_BIN}" "${rclone_args[@]}" deletefile "${RCLONE_REMOTE}/${file}"
        "${RCLONE_BIN}" "${rclone_args[@]}" deletefile "${RCLONE_REMOTE}/${file}.sha256" 2>/dev/null || true
      fi
    elif [[ "$action" == "KEEP" ]]; then
      kept_count=$((kept_count + 1))
    fi
  done < <(compute_retention)

  echo "Retention evaluation complete: ${kept_count} backup(s) retained, ${pruned_count} backup(s) pruned."
}

list_remote_backups() {
  echo "==> Remote backups at '${RCLONE_REMOTE}':"
  printf "%-35s %-12s %-10s %-8s %s\n" "ARCHIVE" "DATE" "WEEK" "STATUS" "REASON"
  printf "%s\n" "----------------------------------------------------------------------------------"

  local total=0
  while IFS=$'\t' read -r action file reason d w; do
    [[ -z "$action" ]] && continue
    total=$((total + 1))
    printf "%-35s %-12s %-10s %-8s %s\n" "$file" "$d" "$w" "$action" "$reason"
  done < <(compute_retention)

  if [[ $total -eq 0 ]]; then
    echo "No remote backups found at '${RCLONE_REMOTE}'."
  fi
}

main() {
  parse_args "$@"
  verify_prerequisites

  case "$ACTION" in
    all)
      dump_databases
      archive_pvcs
      create_bundle
      upload_bundle
      prune_remote_backups
      echo "K3s backup pipeline completed successfully."
      ;;
    dump-db)
      dump_databases
      ;;
    backup-pvc)
      archive_pvcs
      ;;
    bundle)
      create_bundle
      ;;
    upload)
      upload_bundle
      ;;
    prune)
      prune_remote_backups
      ;;
    list)
      list_remote_backups
      ;;
  esac
}

main "$@"
