#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_VAULT="${REPO_ROOT}/scripts/backup-vault.sh"

TEST_TMP="$(mktemp -d /tmp/backup-vault-test.XXXXXX)"
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

assert_file_not_exists() {
  local file="$1"
  local msg="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$file" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected file '$file' to NOT exist)" >&2
    exit 1
  fi
}

echo "Running tests for backup-vault.sh pipeline..."

# 1. Help and usage message
output=$("${BACKUP_VAULT}" --help)
assert_contains "$output" "Usage: backup-vault.sh" "Help displays usage header"
assert_contains "$output" "snapshot" "Help documents snapshot command"
assert_contains "$output" "upload" "Help documents upload command"
assert_contains "$output" "prune" "Help documents prune command"
assert_contains "$output" "--keep-days" "Help documents --keep-days option"
assert_contains "$output" "--keep-weeks" "Help documents --keep-weeks option"

# 2. Argument validation & error handling
set +e
err=$("${BACKUP_VAULT}" --unknown-arg 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Unknown flag exits with code 1"
assert_contains "$err" "Error: Unknown argument" "Error message printed for unknown flag"

set +e
err=$("${BACKUP_VAULT}" --keep-days not-a-number 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Non-numeric --keep-days exits with code 1"
assert_contains "$err" "--keep-days must be a non-negative integer" "Validation error for keep-days"

set +e
err=$("${BACKUP_VAULT}" --keep-weeks -5 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Negative --keep-weeks exits with code 1"
assert_contains "$err" "--keep-weeks must be a non-negative integer" "Validation error for keep-weeks"

set +e
err=$("${BACKUP_VAULT}" upload 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Upload command without --file exits with code 1"
assert_contains "$err" "requires --file" "Upload error requires file path"

set +e
err=$("${BACKUP_VAULT}" upload --file "${TEST_TMP}/nonexistent.tar.gz" --dest "${TEST_TMP}/dest" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Upload of non-existent archive exits with code 1"
assert_contains "$err" "not found" "Upload error identifies missing file"

# 3. Snapshot creation from directory storage fixture
MOCK_STORAGE_DIR="${TEST_TMP}/vault-storage-fixture"
mkdir -p "${MOCK_STORAGE_DIR}/core" "${MOCK_STORAGE_DIR}/sys"
echo "vault-key-data-1" > "${MOCK_STORAGE_DIR}/core/data.db"
echo "vault-sys-config" > "${MOCK_STORAGE_DIR}/sys/config.json"

SNAP_OUT_DIR="${TEST_TMP}/snapshots"
mkdir -p "$SNAP_OUT_DIR"

snap_res=$("${BACKUP_VAULT}" snapshot \
  --source-mode dir \
  --source-dir "$MOCK_STORAGE_DIR" \
  --output-dir "$SNAP_OUT_DIR" \
  --timestamp "20261110_120000")

EXPECTED_SNAP="${SNAP_OUT_DIR}/vault-backup-20261110_120000.tar.gz"
assert_file_exists "$EXPECTED_SNAP" "Snapshot archive created with timestamped name"
assert_contains "$snap_res" "Snapshot successfully created" "Snapshot command outputs success"

# Verify archive compression integrity and content
archive_listing=$(tar -tzf "$EXPECTED_SNAP")
assert_contains "$archive_listing" "metadata.json" "Archive contains metadata.json"
assert_contains "$archive_listing" "data/core/data.db" "Archive contains storage core data"
assert_contains "$archive_listing" "data/sys/config.json" "Archive contains storage sys config"

# Extract metadata and verify JSON structure
EXTRACT_DIR="${TEST_TMP}/extract"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$EXPECTED_SNAP" -C "$EXTRACT_DIR"
meta_type=$(jq -r '.storage_type' "${EXTRACT_DIR}/metadata.json")
meta_fn=$(jq -r '.filename' "${EXTRACT_DIR}/metadata.json")
assert_eq "dir" "$meta_type" "Metadata records correct storage type"
assert_eq "vault-backup-20261110_120000.tar.gz" "$meta_fn" "Metadata records matching filename"

# Custom filename override
custom_snap_res=$("${BACKUP_VAULT}" snapshot \
  --source-mode dir \
  --source-dir "$MOCK_STORAGE_DIR" \
  --output-dir "$SNAP_OUT_DIR" \
  --filename "custom-vault.tar.gz")

assert_file_exists "${SNAP_OUT_DIR}/custom-vault.tar.gz" "Custom filename respected"

# 4. Raft storage snapshot simulation via mock Vault CLI
MOCK_BIN_DIR="${TEST_TMP}/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
cat <<'EOF' > "${MOCK_BIN_DIR}/vault"
#!/usr/bin/env bash
if [[ "$*" == *"operator raft snapshot save"* ]]; then
  target_file="${@: -1}"
  echo "mock-binary-raft-snapshot-data-stream" > "$target_file"
  exit 0
fi
echo "mock vault unknown command" >&2
exit 1
EOF
chmod +x "${MOCK_BIN_DIR}/vault"

RAFT_SNAP="${SNAP_OUT_DIR}/vault-backup-raft.tar.gz"
PATH="${MOCK_BIN_DIR}:${PATH}" "${BACKUP_VAULT}" snapshot \
  --source-mode raft \
  --output-dir "$SNAP_OUT_DIR" \
  --filename "vault-backup-raft.tar.gz" >/dev/null

assert_file_exists "$RAFT_SNAP" "Raft snapshot archive successfully created"
raft_listing=$(tar -tzf "$RAFT_SNAP")
assert_contains "$raft_listing" "vault.snap" "Raft archive contains vault.snap"
assert_contains "$raft_listing" "metadata.json" "Raft archive contains metadata.json"

# 5. Upload and remote verification
REMOTE_STORE="${TEST_TMP}/remote-store"
mkdir -p "$REMOTE_STORE"

upload_res=$("${BACKUP_VAULT}" upload \
  --file "$EXPECTED_SNAP" \
  --dest "$REMOTE_STORE")

assert_file_exists "${REMOTE_STORE}/vault-backup-20261110_120000.tar.gz" "Uploaded snapshot exists on target store"
assert_contains "$upload_res" "Upload verified successfully" "Upload command verifies bytes and presence"

# 6. Retention policy pruning simulation
# Populate remote store with mock backups simulating 7 weeks of activity
MOCK_BACKUPS_DIR="${TEST_TMP}/retention-store"
mkdir -p "$MOCK_BACKUPS_DIR"

touch_mock_backup() {
  local name="$1"
  echo "dummy-backup-payload" > "${MOCK_BACKUPS_DIR}/${name}"
}

# Unrelated files that must never be touched
touch "${MOCK_BACKUPS_DIR}/k3s-backup-20261110_120000.tar.gz"
touch "${MOCK_BACKUPS_DIR}/notes.txt"

# Backups across different dates and weeks:
# - Week 46 (Current week)
touch_mock_backup "vault-backup-20261110_150000.tar.gz" # Day 1, newest
touch_mock_backup "vault-backup-20261110_100000.tar.gz" # Day 1, older intraday -> prune
touch_mock_backup "vault-backup-20261109_120000.tar.gz" # Day 2 -> keep
# - Week 45 (1 week ago)
touch_mock_backup "vault-backup-20261108_200000.tar.gz" # Day 3, evening -> keep
touch_mock_backup "vault-backup-20261108_080000.tar.gz" # Day 3, morning intraday -> prune
touch_mock_backup "vault-backup-20261107_120000.tar.gz" # Day 4 -> keep
touch_mock_backup "vault-backup-20261106_120000.tar.gz" # Day 5 -> keep
touch_mock_backup "vault-backup-20261105_120000.tar.gz" # Day 6 -> keep
touch_mock_backup "vault-backup-20261104_120000.tar.gz" # Day 7 -> keep
# - Week 44 (2 weeks ago)
touch_mock_backup "vault-backup-20261026_120000.tar.gz" # Weekly candidate 1 -> keep
# - Week 43 (3 weeks ago)
touch_mock_backup "vault-backup-20261019_120000.tar.gz" # Weekly candidate 2 -> keep
# - Week 42 (4 weeks ago)
touch_mock_backup "vault-backup-20261012_120000.tar.gz" # Weekly candidate 3 -> keep
# - Week 41 (5 weeks ago)
touch_mock_backup "vault-backup-20261005_120000.tar.gz" # Weekly candidate 4 -> keep
# - Week 38 (8 weeks ago, exceeds 4 weekly retention)
touch_mock_backup "vault-backup-20260920_120000.tar.gz" # Exceeds retention -> prune

# Execute pruning: keep 7 daily, 4 weekly, min 1
prune_out=$("${BACKUP_VAULT}" prune \
  --dest "$MOCK_BACKUPS_DIR" \
  --keep-days 7 \
  --keep-weeks 4 \
  --keep-last 1)

assert_contains "$prune_out" "Pruning complete: removed 3 backup(s)" "Pruned expected 3 backups"

# Verify non-vault files intact
assert_file_exists "${MOCK_BACKUPS_DIR}/k3s-backup-20261110_120000.tar.gz" "Non-vault backup untouched"
assert_file_exists "${MOCK_BACKUPS_DIR}/notes.txt" "Unrelated text file untouched"

# Verify pruned files deleted
assert_file_not_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261110_100000.tar.gz" "Older intraday backup pruned"
assert_file_not_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261108_080000.tar.gz" "Older intraday backup on day 3 pruned"
assert_file_not_exists "${MOCK_BACKUPS_DIR}/vault-backup-20260920_120000.tar.gz" "Backup exceeding 4 weeks pruned"

# Verify kept daily backups
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261110_150000.tar.gz" "Kept latest daily (Day 1)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261109_120000.tar.gz" "Kept daily (Day 2)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261108_200000.tar.gz" "Kept daily (Day 3)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261107_120000.tar.gz" "Kept daily (Day 4)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261106_120000.tar.gz" "Kept daily (Day 5)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261105_120000.tar.gz" "Kept daily (Day 6)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261104_120000.tar.gz" "Kept daily (Day 7)"

# Verify kept weekly backups
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261026_120000.tar.gz" "Kept weekly backup (Week 44)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261019_120000.tar.gz" "Kept weekly backup (Week 43)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261012_120000.tar.gz" "Kept weekly backup (Week 42)"
assert_file_exists "${MOCK_BACKUPS_DIR}/vault-backup-20261005_120000.tar.gz" "Kept weekly backup (Week 41)"

# 7. Pruning edge case: empty destination
EMPTY_STORE="${TEST_TMP}/empty-store"
mkdir -p "$EMPTY_STORE"
empty_prune_out=$("${BACKUP_VAULT}" prune --dest "$EMPTY_STORE")
assert_contains "$empty_prune_out" "No existing backups found" "Empty target handled gracefully"

# 8. Dry-run mode
DRY_STORE="${TEST_TMP}/dry-store"
mkdir -p "$DRY_STORE"
touch "${DRY_STORE}/vault-backup-20200101_120000.tar.gz"

dry_prune_out=$("${BACKUP_VAULT}" prune --dest "$DRY_STORE" --keep-days 0 --keep-weeks 0 --keep-last 0 --dry-run)
assert_contains "$dry_prune_out" "[dry-run] Would prune remote backup" "Dry run reports proposed prune"
assert_file_exists "${DRY_STORE}/vault-backup-20200101_120000.tar.gz" "Dry run does not delete remote files"

dry_backup_out=$("${BACKUP_VAULT}" backup \
  --source-mode dir \
  --source-dir "$MOCK_STORAGE_DIR" \
  --dest "$DRY_STORE" \
  --dry-run)
assert_contains "$dry_backup_out" "[dry-run] Would create Vault snapshot" "Dry run reports proposed snapshot"
assert_contains "$dry_backup_out" "[dry-run] Would upload" "Dry run reports proposed upload"

# 9. End-to-end full pipeline execution
E2E_STORE="${TEST_TMP}/e2e-store"
E2E_STAGING="${TEST_TMP}/e2e-staging"
mkdir -p "$E2E_STORE" "$E2E_STAGING"

e2e_res=$("${BACKUP_VAULT}" backup \
  --source-mode dir \
  --source-dir "$MOCK_STORAGE_DIR" \
  --output-dir "$E2E_STAGING" \
  --dest "$E2E_STORE" \
  --timestamp "20261110_223344")

assert_contains "$e2e_res" "Vault backup completed successfully" "End-to-end backup pipeline succeeds"
assert_file_exists "${E2E_STORE}/vault-backup-20261110_223344.tar.gz" "Backup uploaded to target destination"
assert_file_not_exists "${E2E_STAGING}/vault-backup-20261110_223344.tar.gz" "Temporary local archive cleaned up by default"

# End-to-end with --keep-local
e2e_local_res=$("${BACKUP_VAULT}" backup \
  --source-mode dir \
  --source-dir "$MOCK_STORAGE_DIR" \
  --output-dir "$E2E_STAGING" \
  --dest "$E2E_STORE" \
  --timestamp "20261110_223355" \
  --keep-local)

assert_contains "$e2e_local_res" "Preserved local archive at" "keep-local reports preserved path"
assert_file_exists "${E2E_STAGING}/vault-backup-20261110_223355.tar.gz" "Local archive preserved when requested"

echo "All ${TESTS_PASSED}/${TESTS_RUN} unit tests passed successfully."
