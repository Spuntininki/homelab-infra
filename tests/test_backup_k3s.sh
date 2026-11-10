#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_K3S="${REPO_ROOT}/scripts/backup-k3s.sh"

TEST_TMP="$(mktemp -d /tmp/backup-k3s-test.XXXXXX)"
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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$haystack" != *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected content NOT to contain '$needle')" >&2
    exit 1
  fi
}

echo "Running tests for backup-k3s.sh pipeline..."

# 1. Help and usage
output=$("${BACKUP_K3S}" --help)
assert_contains "$output" "Usage: backup-k3s.sh" "Help displays usage"
assert_contains "$output" "--storage-dir" "Help documents --storage-dir"
assert_contains "$output" "--retention-daily" "Help documents --retention-daily"
assert_contains "$output" "--retention-weekly" "Help documents --retention-weekly"

# 2. CLI argument validation
set +e
err=$("${BACKUP_K3S}" --invalid-flag 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Unknown flag exits with code 1"
assert_contains "$err" "Error: Unknown argument" "Error reported for unknown flag"

set +e
err=$("${BACKUP_K3S}" --backup-dir 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing --backup-dir argument exits with code 1"
assert_contains "$err" "requires a directory argument" "Error reported for missing dir value"

set +e
err=$("${BACKUP_K3S}" --storage-dir 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing --storage-dir argument exits with code 1"

set +e
err=$("${BACKUP_K3S}" --namespace 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing --namespace argument exits with code 1"

set +e
err=$("${BACKUP_K3S}" --retention-daily 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing --retention-daily argument exits with code 1"

# 3. Missing tool prerequisite validation
set +e
err=$("${BACKUP_K3S}" dump-db --kubectl-bin "${TEST_TMP}/nonexistent-kubectl" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing kubectl fails dump-db"
assert_contains "$err" "kubectl binary not found" "Reports missing kubectl"

set +e
err=$("${BACKUP_K3S}" upload --rclone-bin "${TEST_TMP}/nonexistent-rclone" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing rclone fails upload"
assert_contains "$err" "rclone binary not found" "Reports missing rclone"

# Missing rclone.conf fails upload/prune if not in dry-run
MOCK_RCLONE_BIN="${TEST_TMP}/mock-rclone.sh"
cat <<'EOF' > "$MOCK_RCLONE_BIN"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_RCLONE_BIN"

set +e
err=$("${BACKUP_K3S}" prune --rclone-bin "$MOCK_RCLONE_BIN" --config "${TEST_TMP}/missing.conf" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing rclone config fails prune"
assert_contains "$err" "Rclone config file not found" "Reports missing rclone config"

# 4. Dry-run mode does not modify state or execute remote commands
DRY_STAGING="${TEST_TMP}/dry-staging"
dry_out=$("${BACKUP_K3S}" all \
  --dry-run \
  --backup-dir "$DRY_STAGING" \
  --storage-dir "${TEST_TMP}/nonexistent-storage" \
  --skip-db \
  --timestamp "20261110_120000")
assert_contains "$dry_out" "[dry-run] Would package bundle archive" "Dry-run announces bundle packaging"
assert_contains "$dry_out" "[dry-run] Would upload" "Dry-run announces remote upload"
test ! -d "$DRY_STAGING"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# 5. Database detection and dump execution with mock kubectl
MOCK_KUBECTL="${TEST_TMP}/mock-kubectl.sh"
cat <<'EOF' > "$MOCK_KUBECTL"
#!/usr/bin/env bash
cmd="$1"
shift

if [[ "$cmd" == "get" ]]; then
  subcmd="$1"
  shift
  if [[ "$subcmd" == "namespaces" ]]; then
    echo "default mimirflow imobimanager kube-system"
    exit 0
  fi
  if [[ "$subcmd" == "pods" ]]; then
    ns=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-n" ]]; then
        ns="$2"
        shift 2
      else
        shift
      fi
    done
    if [[ "$ns" == "mimirflow" ]]; then
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
    elif [[ "$ns" == "imobimanager" ]]; then
      cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "name": "imobi-mysql-0",
        "namespace": "imobimanager",
        "labels": { "app": "mysql" }
      },
      "status": { "phase": "Running" },
      "spec": {
        "containers": [
          { "name": "mysql", "image": "mysql:8.0" }
        ]
      }
    }
  ]
}
JSON
      exit 0
    else
      echo '{"items": []}'
      exit 0
    fi
  fi
fi

if [[ "$cmd" == "exec" ]]; then
  # Simulate successful SQL dump stream
  echo "-- MOCK DATABASE DUMP FOR $@"
  echo "CREATE TABLE test_data (id int, name varchar(50));"
  echo "INSERT INTO test_data VALUES (1, 'homelab');"
  exit 0
fi

exit 0
EOF
chmod +x "$MOCK_KUBECTL"

DB_TEST_STAGING="${TEST_TMP}/db-staging"
db_dump_out=$("${BACKUP_K3S}" dump-db \
  --kubectl-bin "$MOCK_KUBECTL" \
  --backup-dir "$DB_TEST_STAGING" \
  --timestamp "20261110_130000")

assert_contains "$db_dump_out" "Discovered 2 database workload(s)" "Discovered postgres and mysql workloads"
assert_contains "$db_dump_out" "Successfully dumped mimirflow/mimirflow-postgres-0" "Postgres dumped successfully"
assert_contains "$db_dump_out" "Successfully dumped imobimanager/imobi-mysql-0" "MySQL dumped successfully"

PG_DUMP="${DB_TEST_STAGING}/k3s-backup-20261110_130000/databases/mimirflow_mimirflow-postgres-0_postgres.sql.gz"
MYSQL_DUMP="${DB_TEST_STAGING}/k3s-backup-20261110_130000/databases/imobimanager_imobi-mysql-0_mysql.sql.gz"

test -f "$PG_DUMP"
gzip -t "$PG_DUMP"
pg_content=$(gzip -dc "$PG_DUMP")
assert_contains "$pg_content" "MOCK DATABASE DUMP" "Postgres dump contains uncompressed SQL payload"

test -f "$MYSQL_DUMP"
gzip -t "$MYSQL_DUMP"
mysql_content=$(gzip -dc "$MYSQL_DUMP")
assert_contains "$mysql_content" "test_data" "MySQL dump contains valid SQL payload"

# 6. Database dump error handling and --continue-on-error
MOCK_KUBECTL_FAIL="${TEST_TMP}/mock-kubectl-fail.sh"
cat <<'EOF' > "$MOCK_KUBECTL_FAIL"
#!/usr/bin/env bash
if [[ "$1" == "get" ]]; then
  if [[ "$2" == "namespaces" ]]; then
    echo "mimirflow"
    exit 0
  fi
  cat <<'JSON'
{
  "items": [
    {
      "metadata": { "name": "failing-db", "namespace": "mimirflow" },
      "status": { "phase": "Running" },
      "spec": { "containers": [{ "name": "postgres", "image": "postgres:16" }] }
    }
  ]
}
JSON
  exit 0
fi
if [[ "$1" == "exec" ]]; then
  echo "Simulated network failure" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$MOCK_KUBECTL_FAIL"

set +e
err=$("${BACKUP_K3S}" dump-db \
  --kubectl-bin "$MOCK_KUBECTL_FAIL" \
  --backup-dir "${TEST_TMP}/fail-staging" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Database dump failure without --continue-on-error exits with 1"
assert_contains "$err" "Error: Database dump failed" "Failure message printed"

# With --continue-on-error
set +e
continue_out=$("${BACKUP_K3S}" dump-db \
  --kubectl-bin "$MOCK_KUBECTL_FAIL" \
  --backup-dir "${TEST_TMP}/continue-staging" \
  --continue-on-error 2>&1)
code=$?
set -e
assert_eq "0" "$code" "Database dump failure with --continue-on-error exits with 0"
assert_contains "$continue_out" "continuing due to --continue-on-error" "Warning printed and proceeds"

# 7. PVC discovery, archiving, compression integrity, and namespace filtering
MOCK_STORAGE="${TEST_TMP}/k3s-storage"
mkdir -p "${MOCK_STORAGE}/pvc-111_mimirflow_data"
mkdir -p "${MOCK_STORAGE}/pvc-222_imobimanager_media"
mkdir -p "${MOCK_STORAGE}/pvc-333_unrelated_logs"

echo "mimirflow pvc data content" > "${MOCK_STORAGE}/pvc-111_mimirflow_data/app.db"
echo "imobimanager media file" > "${MOCK_STORAGE}/pvc-222_imobimanager_media/photo.jpg"
echo "unrelated log data" > "${MOCK_STORAGE}/pvc-333_unrelated_logs/audit.log"

PVC_STAGING="${TEST_TMP}/pvc-staging"

# Targeted namespace filtering
pvc_out_filter=$("${BACKUP_K3S}" backup-pvc \
  --storage-dir "$MOCK_STORAGE" \
  --backup-dir "$PVC_STAGING" \
  --namespace "mimirflow" \
  --timestamp "20261110_140000")

assert_contains "$pvc_out_filter" "Found 1 PVC storage director(ies)" "Only matching namespace PVC discovered"
assert_contains "$pvc_out_filter" "Archiving PVC 'pvc-111_mimirflow_data'" "Target PVC archived"

MIMIR_TAR="${PVC_STAGING}/k3s-backup-20261110_140000/pvcs/pvc-111_mimirflow_data.tar.gz"
test -f "$MIMIR_TAR"
tar -tzf "$MIMIR_TAR" | grep -q "app.db"
test ! -f "${PVC_STAGING}/k3s-backup-20261110_140000/pvcs/pvc-222_imobimanager_media.tar.gz"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# All namespaces PVC archiving
PVC_ALL_STAGING="${TEST_TMP}/pvc-all-staging"
pvc_out_all=$("${BACKUP_K3S}" backup-pvc \
  --storage-dir "$MOCK_STORAGE" \
  --backup-dir "$PVC_ALL_STAGING" \
  --timestamp "20261110_140000")

assert_contains "$pvc_out_all" "Found 3 PVC storage director(ies)" "All PVC directories found"
test -f "${PVC_ALL_STAGING}/k3s-backup-20261110_140000/pvcs/pvc-111_mimirflow_data.tar.gz"
test -f "${PVC_ALL_STAGING}/k3s-backup-20261110_140000/pvcs/pvc-222_imobimanager_media.tar.gz"
test -f "${PVC_ALL_STAGING}/k3s-backup-20261110_140000/pvcs/pvc-333_unrelated_logs.tar.gz"
tar -tzf "${PVC_ALL_STAGING}/k3s-backup-20261110_140000/pvcs/pvc-222_imobimanager_media.tar.gz" | grep -q "photo.jpg"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# 8. Bundle creation and manifest verification
BUNDLE_STAGING="${TEST_TMP}/bundle-staging"
mkdir -p "${BUNDLE_STAGING}/k3s-backup-20261110_150000/databases"
mkdir -p "${BUNDLE_STAGING}/k3s-backup-20261110_150000/pvcs"
echo "dummy db" | gzip -c > "${BUNDLE_STAGING}/k3s-backup-20261110_150000/databases/mimirflow_db.sql.gz"
echo "dummy pvc" | gzip -c > "${BUNDLE_STAGING}/k3s-backup-20261110_150000/pvcs/mimirflow_pvc.tar.gz"

bundle_out=$("${BACKUP_K3S}" bundle \
  --backup-dir "$BUNDLE_STAGING" \
  --timestamp "20261110_150000")

assert_contains "$bundle_out" "Consolidated archive created" "Bundle archive created message"
BUNDLE_FILE="${BUNDLE_STAGING}/k3s-backup-20261110_150000.tar.gz"
BUNDLE_SHA="${BUNDLE_STAGING}/k3s-backup-20261110_150000.tar.gz.sha256"

test -f "$BUNDLE_FILE"
test -f "$BUNDLE_SHA"
tar -tzf "$BUNDLE_FILE" | grep -q "manifest.json"
tar -tzf "$BUNDLE_FILE" | grep -q "databases/mimirflow_db.sql.gz"
tar -tzf "$BUNDLE_FILE" | grep -q "pvcs/mimirflow_pvc.tar.gz"

# Verify manifest JSON structure
manifest_content=$(tar -xzf "$BUNDLE_FILE" -O "k3s-backup-20261110_150000/manifest.json")
assert_contains "$manifest_content" '"timestamp": "20261110_150000"' "Manifest contains timestamp"
assert_contains "$manifest_content" "mimirflow_db.sql.gz" "Manifest lists dumped database"
assert_contains "$manifest_content" "mimirflow_pvc.tar.gz" "Manifest lists archived PVC"

# Verify sha256 checksum integrity
(cd "$BUNDLE_STAGING" && sha256sum -c "k3s-backup-20261110_150000.tar.gz.sha256")
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# 9. Upload and staging cleanup behavior
MOCK_RCLONE_UPLOAD="${TEST_TMP}/mock-rclone-upload.sh"
RCLONE_LOG="${TEST_TMP}/rclone-ops.log"
cat <<EOF > "$MOCK_RCLONE_UPLOAD"
#!/usr/bin/env bash
echo "\$@" >> "$RCLONE_LOG"
exit 0
EOF
chmod +x "$MOCK_RCLONE_UPLOAD"

MOCK_CONFIG="${TEST_TMP}/rclone.conf"
touch "$MOCK_CONFIG"

# Upload with keep-local=true
"${BACKUP_K3S}" upload \
  --rclone-bin "$MOCK_RCLONE_UPLOAD" \
  --config "$MOCK_CONFIG" \
  --backup-dir "$BUNDLE_STAGING" \
  --timestamp "20261110_150000" \
  --keep-local

test -f "$BUNDLE_FILE"
assert_contains "$(cat "$RCLONE_LOG")" "copy $BUNDLE_FILE" "Rclone copy invoked with bundle file"

# Upload with keep-local=false (default): cleans staging files
"${BACKUP_K3S}" upload \
  --rclone-bin "$MOCK_RCLONE_UPLOAD" \
  --config "$MOCK_CONFIG" \
  --backup-dir "$BUNDLE_STAGING" \
  --timestamp "20261110_150000"

test ! -f "$BUNDLE_FILE"
test ! -d "${BUNDLE_STAGING}/k3s-backup-20261110_150000"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# 10. Retention policy simulation (7 daily, 4 weekly)
MOCK_RCLONE_RETENTION="${TEST_TMP}/mock-rclone-retention.sh"
RCLONE_DELETED="${TEST_TMP}/rclone-deleted.log"

cat <<EOF > "$MOCK_RCLONE_RETENTION"
#!/usr/bin/env bash
if [[ "\$*" == *"lsf"* ]]; then
  # 14 simulated daily backups from 2026-11-10 backwards to 2026-10-28
  cat <<'LIST'
k3s-backup-20261110_120000.tar.gz
k3s-backup-20261109_120000.tar.gz
k3s-backup-20261108_120000.tar.gz
k3s-backup-20261107_120000.tar.gz
k3s-backup-20261106_120000.tar.gz
k3s-backup-20261105_120000.tar.gz
k3s-backup-20261104_120000.tar.gz
k3s-backup-20261103_120000.tar.gz
k3s-backup-20261102_120000.tar.gz
k3s-backup-20261101_120000.tar.gz
k3s-backup-20261031_120000.tar.gz
k3s-backup-20261030_120000.tar.gz
k3s-backup-20261029_120000.tar.gz
k3s-backup-20261028_120000.tar.gz
LIST
  exit 0
fi

if [[ "\$*" == *"deletefile"* ]]; then
  echo "\$*" >> "$RCLONE_DELETED"
  exit 0
fi

exit 0
EOF
chmod +x "$MOCK_RCLONE_RETENTION"

# Prune dry-run
dry_prune=$("${BACKUP_K3S}" prune \
  --rclone-bin "$MOCK_RCLONE_RETENTION" \
  --config "$MOCK_CONFIG" \
  --retention-daily 7 \
  --retention-weekly 4 \
  --dry-run)

assert_contains "$dry_prune" "[dry-run] Would prune remote backup" "Dry-run announces pruning"
test ! -f "$RCLONE_DELETED"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# Prune actual run
prune_out=$("${BACKUP_K3S}" prune \
  --rclone-bin "$MOCK_RCLONE_RETENTION" \
  --config "$MOCK_CONFIG" \
  --retention-daily 7 \
  --retention-weekly 4)

assert_contains "$prune_out" "6 backup(s) pruned" "Pruned 6 backups exceeding retention"
assert_contains "$prune_out" "8 backup(s) retained" "Retained 8 backups matching daily/weekly rules"

deleted_log=$(cat "$RCLONE_DELETED")
# 2026-11-10 to 2026-11-04 (7 days) must NOT be deleted
assert_not_contains "$deleted_log" "20261110_120000" "Newest daily backup retained"
assert_not_contains "$deleted_log" "20261104_120000" "7th daily backup retained"
# 2026-11-01 was weekly representative for week 44, must NOT be deleted
assert_not_contains "$deleted_log" "20261101_120000" "Weekly backup retained"
# Backups exceeding threshold must be deleted
assert_contains "$deleted_log" "20261028_120000" "Old backup pruned"
assert_contains "$deleted_log" "20261029_120000" "Old backup pruned"

# List action test
list_out=$("${BACKUP_K3S}" list \
  --rclone-bin "$MOCK_RCLONE_RETENTION" \
  --config "$MOCK_CONFIG" \
  --retention-daily 7 \
  --retention-weekly 4)
assert_contains "$list_out" "k3s-backup-20261110_120000.tar.gz" "List displays backups"
assert_contains "$list_out" "KEEP" "List displays KEEP status"
assert_contains "$list_out" "PRUNE" "List displays PRUNE status"

# 11. End-to-end full pipeline execution
E2E_STAGING="${TEST_TMP}/e2e-staging"
e2e_out=$("${BACKUP_K3S}" all \
  --kubectl-bin "$MOCK_KUBECTL" \
  --rclone-bin "$MOCK_RCLONE_UPLOAD" \
  --config "$MOCK_CONFIG" \
  --storage-dir "$MOCK_STORAGE" \
  --backup-dir "$E2E_STAGING" \
  --namespace "mimirflow" \
  --timestamp "20261110_160000")

assert_contains "$e2e_out" "K3s backup pipeline completed successfully" "End-to-end pipeline finished cleanly"
assert_contains "$e2e_out" "mimirflow/mimirflow-postgres-0" "End-to-end included database dump"
assert_contains "$e2e_out" "pvc-111_mimirflow_data" "End-to-end included PVC archive"
assert_contains "$e2e_out" "Consolidated archive created" "End-to-end created bundle"
assert_contains "$e2e_out" "Upload complete" "End-to-end uploaded bundle"

echo "All ${TESTS_PASSED}/${TESTS_RUN} unit tests passed successfully."
