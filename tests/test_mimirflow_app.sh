#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_FILE="${REPO_ROOT}/clusters/local/apps/mimirflow.yaml"
DOC_FILE="${REPO_ROOT}/docs/apps/mimirflow.md"

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

assert_file_exists() {
  local file="$1"
  local msg="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -f "$file" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "FAIL: $msg (file not found: $file)" >&2
    exit 1
  fi
}

echo "Running tests for mimirflow application onboarding..."

assert_file_exists "$APP_FILE" "Application descriptor exists"
assert_file_exists "$DOC_FILE" "Application onboarding documentation exists"

# Validate YAML fields
PARSED=$(python3 -c "
import yaml
with open('${APP_FILE}') as f:
    d = yaml.safe_load(f)
print(f\"{d.get('name')}|{d.get('repoURL')}|{d.get('targetRevision')}|{d.get('path')}|{d.get('namespace')}\")
")

IFS='|' read -r APP_NAME REPO_URL TARGET_REV APP_PATH APP_NS <<< "$PARSED"

assert_eq "mimirflow" "$APP_NAME" "App name is mimirflow"
assert_eq "git@github.com:Spuntininki/mimirflow.git" "$REPO_URL" "Repo URL matches git SSH"
assert_eq "HEAD" "$TARGET_REV" "Target revision is HEAD"
assert_eq "deploy/k8s" "$APP_PATH" "Manifest path is deploy/k8s"
assert_eq "mimirflow" "$APP_NS" "Target namespace is mimirflow"

echo "All ${TESTS_PASSED}/${TESTS_RUN} mimirflow onboarding tests passed successfully."
