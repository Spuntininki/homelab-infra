#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_SH="${REPO_ROOT}/scripts/backup.sh"
RESTORE_SH="${REPO_ROOT}/scripts/restore.sh"

TEST_TMP="$(mktemp -d /tmp/backup-restore-test.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

TESTS_RUN=0
TESTS_PASSED=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected content to contain '$needle')" >&2
    exit 1
  fi
}

assert_file_exists() {
  local file="$1"
  local msg="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$file" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected file '$file' to exist)" >&2
    exit 1
  fi
}

echo "Running tests for backup.sh and restore.sh pipelines..."

# 1. CLI argument validation for backup.sh
output=$("${BACKUP_SH}" --help)
assert_contains "$output" "Usage: backup.sh" "backup.sh help displays usage"
assert_contains "$output" "all" "backup.sh documents 'all' command"
assert_contains "$output" "vault" "backup.sh documents 'vault' command"
assert_contains "$output" "k3s" "backup.sh documents 'k3s' command"
assert_contains "$output" "--keep-days" "backup.sh documents --keep-days"

set +e
err=$("${BACKUP_SH}" --unknown-option 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Unknown flag fails backup.sh"
assert_contains "$err" "Error: Unknown argument" "backup.sh reports unknown argument"

set +e
err=$("${BACKUP_SH}" --keep-days abc 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Non-numeric keep-days fails backup.sh"
assert_contains "$err" "--keep-days must be a non-negative integer" "Validates keep-days"

set +e
err=$("${BACKUP_SH}" --keep-weeks -2 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Negative keep-weeks fails backup.sh"
assert_contains "$err" "--keep-weeks must be a non-negative integer" "Validates keep-weeks"

# 2. CLI argument validation for restore.sh
output=$("${RESTORE_SH}" --help)
assert_contains "$output" "Usage: restore.sh" "restore.sh help displays usage"
assert_contains "$output" "all" "restore.sh documents 'all' command"
assert_contains "$output" "vault" "restore.sh documents 'vault' command"
assert_contains "$output" "k3s" "restore.sh documents 'k3s' command"
assert_contains "$output" "list" "restore.sh documents 'list' command"
assert_contains "$output" "download" "restore.sh documents 'download' command"

set +e
err=$("${RESTORE_SH}" --invalid-flag 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Unknown flag fails restore.sh"
assert_contains "$err" "Error: Unknown argument" "restore.sh reports unknown argument"

# 3. Dry-run mode for backup and restore
DRY_REMOTE="${TEST_TMP}/dry-remote"
mkdir -p "$DRY_REMOTE"
dry_backup_out=$("${BACKUP_SH}" all --remote "$DRY_REMOTE" --dry-run --skip-db --timestamp "20261110_120000")
assert_contains "$dry_backup_out" "HOMELAB BACKUP SUMMARY" "Dry-run backup outputs summary"
assert_contains "$dry_backup_out" "SUCCESS" "Dry-run backup completes with success status"
assert_eq "0" "$(find "$DRY_REMOTE" -type f | wc -l)" "Dry-run backup creates no remote files"

dry_restore_out=$("${RESTORE_SH}" all --remote "$DRY_REMOTE" --dry-run)
assert_contains "$dry_restore_out" "HOMELAB RESTORE SUMMARY" "Dry-run restore outputs summary"

# 4. Status and listing against empty and populated stores
empty_status=$("${BACKUP_SH}" status --remote "$DRY_REMOTE")
assert_contains "$empty_status" "Vault Backup Inventory" "Status command queries Vault"
assert_contains "$empty_status" "K3s Backup Inventory" "Status command queries K3s"

empty_list=$("${RESTORE_SH}" list --remote "$DRY_REMOTE")
assert_contains "$empty_list" "No Vault backups found" "List command notes missing Vault backups"
assert_contains "$empty_list" "No K3s backups found" "List command notes missing K3s backups"

# 5. Hermetic End-to-End: Backup execution -> Mock Upload -> Download -> Target Restore
MOCK_REMOTE="${TEST_TMP}/mock-cloud-storage"
mkdir -p "$MOCK_REMOTE"

# Setup mock Vault fixture
MOCK_VAULT_SRC="${TEST_TMP}/mock-vault-data"
mkdir -p "${MOCK_VAULT_SRC}/core" "${MOCK_VAULT_SRC}/sys"
echo "secret-root-vault-payload" > "${MOCK_VAULT_SRC}/core/secret.db"
echo '{"cluster_name":"homelab-vault"}' > "${MOCK_VAULT_SRC}/sys/cluster.json"

# Setup mock K3s PVC storage fixture
MOCK_K3S_STORAGE="${TEST_TMP}/mock-k3s-storage"
MOCK_PVC_DIR="${MOCK_K3S_STORAGE}/pvc-99a038f4-mimirflow-data"
mkdir -p "$MOCK_PVC_DIR"
echo "sqlite-mimirflow-database-records" > "${MOCK_PVC_DIR}/flow.db"

# Setup mock kubectl for database dump
MOCK_KUBECTL="${TEST_TMP}/mock-kubectl.sh"
cat <<'EOF' > "$MOCK_KUBECTL"
#!/usr/bin/env bash
cmd="$1"
shift

if [[ "$cmd" == "get" ]]; then
  subcmd="$1"
  shift
  if [[ "$subcmd" == "namespaces" ]]; then
    echo "mimirflow"
    exit 0
  fi
  if [[ "$subcmd" == "pods" ]]; then
    cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "name": "mimirflow-postgres-0",
        "namespace": "mimirflow",
        "labels": { "app.kubernetes.io/name": "postgresql" }
      },
      "status": { "phase": "Running" },
      "spec": {
        "containers": [
          { "name": "postgresql", "image": "docker.io/bitnami/postgresql:16" }
        ]
      }
    }
  ]
}
JSON
    exit 0
  fi
  if [[ "$subcmd" == "pod" ]]; then
    exit 0
  fi
fi

if [[ "$cmd" == "exec" ]]; then
  echo "CREATE TABLE test_table (id INT); INSERT INTO test_table VALUES (42);"
  exit 0
fi

exit 0
EOF
chmod +x "$MOCK_KUBECTL"

# Execute unified backup
TS="20261110_193000"
backup_run_out=$("${BACKUP_SH}" all \
  --remote "$MOCK_REMOTE" \
  --source-mode dir \
  --source-dir "$MOCK_VAULT_SRC" \
  --storage-dir "$MOCK_K3S_STORAGE" \
  --kubectl-bin "$MOCK_KUBECTL" \
  --timestamp "$TS")

assert_contains "$backup_run_out" "HOMELAB BACKUP SUMMARY" "Unified backup produces summary"
assert_contains "$backup_run_out" "Vault          SUCCESS" "Vault backup succeeded"
assert_contains "$backup_run_out" "K3s            SUCCESS" "K3s backup succeeded"
assert_contains "$backup_run_out" "Overall:       SUCCESS" "Overall backup succeeded"

# Verify uploaded archives and checksums exist in mock remote
VAULT_ARCHIVE="${MOCK_REMOTE}/vault/vault-backup-${TS}.tar.gz"
K3S_ARCHIVE="${MOCK_REMOTE}/k3s/k3s-backup-${TS}.tar.gz"
K3S_SHA="${MOCK_REMOTE}/k3s/k3s-backup-${TS}.tar.gz.sha256"

assert_file_exists "$VAULT_ARCHIVE" "Vault backup archive uploaded to remote"
assert_file_exists "$K3S_ARCHIVE" "K3s backup bundle uploaded to remote"
assert_file_exists "$K3S_SHA" "K3s checksum uploaded to remote"

# Test restore listing with populated remote
list_out=$("${RESTORE_SH}" list --remote "$MOCK_REMOTE")
assert_contains "$list_out" "vault-backup-${TS}.tar.gz" "restore.sh lists remote vault backup"
assert_contains "$list_out" "k3s-backup-${TS}.tar.gz" "restore.sh lists remote k3s backup"

# Execute unified restore to isolated target destination
RESTORE_TARGET="${TEST_TMP}/restored-output"
mkdir -p "$RESTORE_TARGET"

restore_run_out=$("${RESTORE_SH}" all \
  --remote "$MOCK_REMOTE" \
  --target-dir "$RESTORE_TARGET" \
  --kubectl-bin "$MOCK_KUBECTL")

assert_contains "$restore_run_out" "HOMELAB RESTORE SUMMARY" "Restore produces summary"
assert_contains "$restore_run_out" "Vault          SUCCESS" "Vault restore succeeded"
assert_contains "$restore_run_out" "K3s            SUCCESS" "K3s restore succeeded"
assert_contains "$restore_run_out" "Overall:        SUCCESS" "Overall restore succeeded"

# Verify Vault restored files and content integrity
RESTORED_SECRET="${RESTORE_TARGET}/vault/data/core/secret.db"
RESTORED_CONFIG="${RESTORE_TARGET}/vault/data/sys/cluster.json"
assert_file_exists "$RESTORED_SECRET" "Vault secret data file restored"
assert_file_exists "$RESTORED_CONFIG" "Vault cluster config file restored"
assert_eq "secret-root-vault-payload" "$(cat "$RESTORED_SECRET")" "Vault secret content matches source"

# Verify K3s restored PVC files and content integrity
RESTORED_PVC_DB="${RESTORE_TARGET}/k3s/storage/pvc-99a038f4-mimirflow-data/flow.db"
assert_file_exists "$RESTORED_PVC_DB" "K3s PVC volume restored"
assert_eq "sqlite-mimirflow-database-records" "$(cat "$RESTORED_PVC_DB")" "K3s PVC file content matches source"

# Verify K3s restored database dump
RESTORED_SQL="${RESTORE_TARGET}/k3s/databases/mimirflow_mimirflow-postgres-0_postgres.sql"
assert_file_exists "$RESTORED_SQL" "Database SQL dump extracted and uncompressed"
assert_contains "$(cat "$RESTORED_SQL")" "INSERT INTO test_table VALUES (42);" "SQL dump content intact"

# 6. Component-specific restore
VAULT_ONLY_TARGET="${TEST_TMP}/vault-only-restore"
mkdir -p "$VAULT_ONLY_TARGET"
vault_only_out=$("${RESTORE_SH}" vault --remote "$MOCK_REMOTE" --target-dir "$VAULT_ONLY_TARGET")
assert_contains "$vault_only_out" "Vault snapshot safely restored" "Vault only restore succeeded"
assert_file_exists "${VAULT_ONLY_TARGET}/vault/data/core/secret.db" "Vault-only target has Vault secret"
test ! -d "${VAULT_ONLY_TARGET}/k3s"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

K3S_ONLY_TARGET="${TEST_TMP}/k3s-only-restore"
mkdir -p "$K3S_ONLY_TARGET"
k3s_only_out=$("${RESTORE_SH}" k3s --remote "$MOCK_REMOTE" --target-dir "$K3S_ONLY_TARGET" --kubectl-bin "$MOCK_KUBECTL")
assert_contains "$k3s_only_out" "Restoring Persistent Volume Claims" "K3s only restore succeeded"
assert_file_exists "${K3S_ONLY_TARGET}/k3s/storage/pvc-99a038f4-mimirflow-data/flow.db" "K3s-only target has PVC"
test ! -d "${K3S_ONLY_TARGET}/vault"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# 7. Checksum verification failure detection
CORRUPT_REMOTE="${TEST_TMP}/corrupt-remote"
mkdir -p "${CORRUPT_REMOTE}/vault" "${CORRUPT_REMOTE}/k3s"
cp "$VAULT_ARCHIVE" "${CORRUPT_REMOTE}/vault/"
echo "badchecksum0000000000000000000000000000000000000000000000000000000  vault-backup-${TS}.tar.gz" > "${CORRUPT_REMOTE}/vault/vault-backup-${TS}.tar.gz.sha256"

set +e
err=$("${RESTORE_SH}" vault --remote "$CORRUPT_REMOTE" --target-dir "${TEST_TMP}/corrupt-target" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Corrupted checksum fails restore"

# 8. Continue on error flag in backup.sh
set +e
continue_out=$("${BACKUP_SH}" all \
  --remote "$MOCK_REMOTE" \
  --source-mode dir \
  --source-dir "${TEST_TMP}/nonexistent-vault-source" \
  --storage-dir "$MOCK_K3S_STORAGE" \
  --kubectl-bin "$MOCK_KUBECTL" \
  --continue-on-error 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Backup with component failure exits with code 1"
assert_contains "$continue_out" "Vault          FAILED" "Vault marked as FAILED"
assert_contains "$continue_out" "K3s            SUCCESS" "K3s marked as SUCCESS despite Vault failure"
assert_contains "$continue_out" "Overall:       FAILED" "Overall marked as FAILED"

# 9. Systemd unit definitions validation
SERVICE_FILE="${REPO_ROOT}/systemd/homelab-backup.service"
TIMER_FILE="${REPO_ROOT}/systemd/homelab-backup.timer"

assert_file_exists "$SERVICE_FILE" "systemd service file exists"
assert_file_exists "$TIMER_FILE" "systemd timer file exists"

service_content=$(cat "$SERVICE_FILE")
assert_contains "$service_content" "ExecStart=/opt/homelab-infra/scripts/backup.sh" "Service executes backup.sh"
assert_contains "$service_content" "Type=oneshot" "Service configured as oneshot"

timer_content=$(cat "$TIMER_FILE")
assert_contains "$timer_content" "OnCalendar=*-*-* 03:00:00 UTC" "Timer configured for daily 03:00 UTC"
assert_contains "$timer_content" "Persistent=true" "Timer configured with catch-up persistence"

if command -v systemd-analyze >/dev/null 2>&1; then
  cal_check=$(systemd-analyze calendar "*-*-* 03:00:00 UTC")
  assert_contains "$cal_check" "Normalized form: *-*-* 03:00:00 UTC" "systemd-analyze parses calendar schedule"
fi

echo "All ${TESTS_PASSED}/${TESTS_RUN} unit and integration tests passed successfully."
