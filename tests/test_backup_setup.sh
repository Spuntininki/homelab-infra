#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_SETUP="${REPO_ROOT}/scripts/backup-setup.sh"
VAULT_SCRIPT="${REPO_ROOT}/scripts/vault.sh"

TEST_TMP="$(mktemp -d /tmp/backup-setup-test.XXXXXX)"
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

assert_file_perm() {
  local file="$1"
  local expected_perm="$2"
  local msg="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  local actual_perm
  actual_perm=$(stat -c "%a" "$file" 2>/dev/null || stat -f "%Lp" "$file" 2>/dev/null)
  if [[ "$actual_perm" == "$expected_perm" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (expected perm '$expected_perm', got '$actual_perm')" >&2
    exit 1
  fi
}

echo "Running tests for backup-setup.sh and Vault backup integration..."

# 1. Help and usage
output=$("${BACKUP_SETUP}" --help)
assert_contains "$output" "Usage: backup-setup.sh" "Help flag displays usage message"
assert_contains "$output" "--config" "Help flag documents --config option"
assert_contains "$output" "check" "Help flag documents check action"

# 2. Argument validation
set +e
err=$("${BACKUP_SETUP}" --unknown-flag 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Unknown flag exits with code 1"
assert_contains "$err" "Error: Unknown argument" "Error message printed for unknown flag"

set +e
err=$("${BACKUP_SETUP}" --config 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Missing --config argument value exits with code 1"
assert_contains "$err" "Error: --config requires a path argument" "Error message printed for missing config value"

# 3. Vault helper command validation
set +e
err=$("${VAULT_SCRIPT}" backup-put 2>&1)
code=$?
set -e
assert_eq "1" "$code" "vault.sh backup-put without args fails"
assert_contains "$err" "Error: 'backup-put' requires <target>" "backup-put shows usage error"

set +e
err=$("${VAULT_SCRIPT}" backup-put invalid_target foo=bar 2>&1)
code=$?
set -e
assert_eq "1" "$code" "vault.sh backup-put with invalid target fails"
assert_contains "$err" "Must be 'gdrive' or 'crypt'" "backup-put rejects non-backup target"

set +e
err=$("${VAULT_SCRIPT}" backup-get 2>&1)
code=$?
set -e
assert_eq "1" "$code" "vault.sh backup-get without args fails"
assert_contains "$err" "Error: 'backup-get' requires <target>" "backup-get shows usage error"

# 4. Error handling: Missing Vault secrets
MOCK_VAULT_FAIL="${TEST_TMP}/mock-vault-fail.sh"
cat <<'EOF' > "$MOCK_VAULT_FAIL"
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$MOCK_VAULT_FAIL"

set +e
err=$("${BACKUP_SETUP}" configure --vault-script "$MOCK_VAULT_FAIL" --config "${TEST_TMP}/rclone.conf" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Configure exits with code 1 when Vault secret retrieval fails"
assert_contains "$err" "Failed to retrieve 'secret/homelab/backup/gdrive'" "Error mentions failing gdrive secret"

# 5. Error handling: Incomplete Vault secrets (missing required keys)
MOCK_VAULT_INCOMPLETE="${TEST_TMP}/mock-vault-incomplete.sh"
cat <<'EOF' > "$MOCK_VAULT_INCOMPLETE"
#!/usr/bin/env bash
if [[ "$*" == *"gdrive"* ]]; then
  echo '{"client_id": "test-id"}'
elif [[ "$*" == *"crypt"* ]]; then
  echo '{"password": "secret-pass"}'
fi
EOF
chmod +x "$MOCK_VAULT_INCOMPLETE"

set +e
err=$("${BACKUP_SETUP}" configure --vault-script "$MOCK_VAULT_INCOMPLETE" --config "${TEST_TMP}/rclone.conf" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Configure exits with code 1 when required fields are missing"
assert_contains "$err" "missing required fields" "Error identifies missing fields in gdrive secret"

# 6. Successful configuration generation and safe permissions (0600)
MOCK_VAULT_SUCCESS="${TEST_TMP}/mock-vault-success.sh"
cat <<'EOF' > "$MOCK_VAULT_SUCCESS"
#!/usr/bin/env bash
if [[ "$*" == *"gdrive"* ]]; then
  cat <<'DATA'
{
  "client_id": "mock-client-id.apps.googleusercontent.com",
  "client_secret": "mock-client-secret-xyz",
  "scope": "drive",
  "token": "{\"access_token\":\"mock-token-123\",\"token_type\":\"Bearer\",\"refresh_token\":\"mock-refresh-456\"}"
}
DATA
elif [[ "$*" == *"crypt"* ]]; then
  cat <<'DATA'
{
  "password": "my-plain-crypt-pass",
  "password2": "my-salt-phrase"
}
DATA
fi
EOF
chmod +x "$MOCK_VAULT_SUCCESS"

TARGET_CONFIG="${TEST_TMP}/nested/dir/rclone.conf"
output=$("${BACKUP_SETUP}" configure --vault-script "$MOCK_VAULT_SUCCESS" --config "$TARGET_CONFIG")
assert_contains "$output" "Rclone configuration generated at" "Configure reports success"
test -f "$TARGET_CONFIG"
assert_file_perm "$TARGET_CONFIG" "600" "Generated rclone.conf has strict 600 permissions"
assert_file_perm "$(dirname "$TARGET_CONFIG")" "700" "Parent directory has strict 700 permissions"

# Verify generated content
conf_content=$(cat "$TARGET_CONFIG")
assert_contains "$conf_content" "[gdrive]" "Config contains [gdrive] section"
assert_contains "$conf_content" "type = drive" "gdrive type is drive"
assert_contains "$conf_content" "client_id = mock-client-id.apps.googleusercontent.com" "client_id is present"
assert_contains "$conf_content" "client_secret = mock-client-secret-xyz" "client_secret is present"
assert_contains "$conf_content" "scope = drive" "scope is present"
assert_contains "$conf_content" "mock-token-123" "token is present"

assert_contains "$conf_content" "[gdrive-crypt]" "Config contains [gdrive-crypt] section"
assert_contains "$conf_content" "type = crypt" "gdrive-crypt type is crypt"
assert_contains "$conf_content" "remote = gdrive:homelab-backup" "crypt remote points to gdrive:homelab-backup"
assert_contains "$conf_content" "filename_encryption = standard" "filename encryption is standard"
assert_contains "$conf_content" "directory_name_encryption = true" "directory name encryption is enabled"
assert_contains "$conf_content" "password =" "password is set"
assert_contains "$conf_content" "password2 =" "secondary salt password2 is set"

# 7. Preserving existing sections when updating configuration
cat <<'EOF' >> "$TARGET_CONFIG"

[existing-custom-remote]
type = s3
provider = AWS
EOF

"${BACKUP_SETUP}" configure --vault-script "$MOCK_VAULT_SUCCESS" --config "$TARGET_CONFIG"
updated_conf=$(cat "$TARGET_CONFIG")
assert_contains "$updated_conf" "[existing-custom-remote]" "Existing remotes preserved on reconfiguration"
assert_contains "$updated_conf" "[gdrive]" "gdrive section present after reconfiguration"
assert_contains "$updated_conf" "[gdrive-crypt]" "gdrive-crypt section present after reconfiguration"
assert_file_perm "$TARGET_CONFIG" "600" "Permissions remain 600 after reconfiguration"

# 8. Dry-run mode
DRY_CONFIG="${TEST_TMP}/dry-run-rclone.conf"
dry_output=$("${BACKUP_SETUP}" configure --vault-script "$MOCK_VAULT_SUCCESS" --config "$DRY_CONFIG" --dry-run)
assert_contains "$dry_output" "[dry-run]" "Dry-run flag emits dry-run output"
test ! -f "$DRY_CONFIG"
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

# 9. Pre-flight check failure modes
set +e
err=$("${BACKUP_SETUP}" check --config "${TEST_TMP}/nonexistent.conf" 2>&1)
code=$?
set -e
assert_eq "1" "$code" "Check fails when config file does not exist"
assert_contains "$err" "Rclone configuration file not found" "Check reports missing configuration file"

# Insecure permissions are automatically rectified by check
chmod 644 "$TARGET_CONFIG"
MOCK_RCLONE_SUCCESS="${TEST_TMP}/mock-rclone.sh"
cat <<'EOF' > "$MOCK_RCLONE_SUCCESS"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_RCLONE_SUCCESS"

check_out=$(RCLONE_BIN="$MOCK_RCLONE_SUCCESS" "${BACKUP_SETUP}" check --config "$TARGET_CONFIG")
assert_contains "$check_out" "Warning: Insecure permissions" "Check detects insecure permissions"
assert_contains "$check_out" "pre-flight check SUCCESSFUL" "Check succeeds with functional rclone"
assert_file_perm "$TARGET_CONFIG" "600" "Check enforces 600 permissions"

# 10. Pre-obscured password idempotency
MOCK_VAULT_OBSCURED="${TEST_TMP}/mock-vault-obscured.sh"
OBSCURED_PW=$(rclone obscure "my-already-obscured-pw")
cat <<EOF > "$MOCK_VAULT_OBSCURED"
#!/usr/bin/env bash
if [[ "\$*" == *"gdrive"* ]]; then
  echo '{"client_id": "test-id", "client_secret": "test-sec", "token": "{}"}'
elif [[ "\$*" == *"crypt"* ]]; then
  echo '{"password": "${OBSCURED_PW}"}'
fi
EOF
chmod +x "$MOCK_VAULT_OBSCURED"

OBS_TARGET_CONFIG="${TEST_TMP}/obs-test.conf"
"${BACKUP_SETUP}" configure --vault-script "$MOCK_VAULT_OBSCURED" --config "$OBS_TARGET_CONFIG"
obs_conf=$(cat "$OBS_TARGET_CONFIG")
assert_contains "$obs_conf" "password = ${OBSCURED_PW}" "Pre-obscured password is not double-obscured"

# 11. End-to-end crypt encryption overlay verification
CRYPT_BACKING_DIR="${TEST_TMP}/backing_store"
mkdir -p "$CRYPT_BACKING_DIR"
cat <<EOF >> "$OBS_TARGET_CONFIG"

[local-backing]
type = local

[test-e2e-crypt]
type = crypt
remote = local-backing:${CRYPT_BACKING_DIR}
filename_encryption = standard
directory_name_encryption = true
password = ${OBSCURED_PW}
EOF

# Write encrypted file through rclone
echo "confidential homelab payload" | rclone --config "$OBS_TARGET_CONFIG" rcat test-e2e-crypt:secret.txt
lsd_output=$(rclone --config "$OBS_TARGET_CONFIG" ls test-e2e-crypt:)
assert_contains "$lsd_output" "secret.txt" "Rclone decrypts and lists filename correctly"

# Verify ciphertext at underlying store
backing_files=$(ls "$CRYPT_BACKING_DIR")
if [[ "$backing_files" == *"secret.txt"* ]]; then
  echo "FAIL: Backing store contains plaintext filename!" >&2
  exit 1
fi
TESTS_RUN=$((TESTS_RUN + 1))
TESTS_PASSED=$((TESTS_PASSED + 1))

echo "All ${TESTS_PASSED}/${TESTS_RUN} unit tests passed successfully."
