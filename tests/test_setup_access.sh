#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETUP_ACCESS="${REPO_ROOT}/scripts/setup-access.sh"

TEST_TMP="$(mktemp -d /tmp/k3s-access-test.XXXXXX)"
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

echo "Running tests for setup-access.sh..."

# Fixture: mock k3s.yaml with valid base64 credentials
MOCK_K3S="${TEST_TMP}/mock-k3s.yaml"
cat <<'EOF' > "$MOCK_K3S"
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: dGVzdC1jYS1kYXRh
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: default
  user:
    client-certificate-data: dGVzdC1jZXJ0LWRhdGE=
    client-key-data: dGVzdC1rZXktZGF0YQ==
EOF

# Test 1: Dry run generation with public IP
OUTPUT_DRY=$("$SETUP_ACCESS" --source "$MOCK_K3S" --server 187.77.241.62 --dry-run)
assert_contains "$OUTPUT_DRY" "server: https://187.77.241.62:6443" "Server URL normalized with https and port 6443"
assert_contains "$OUTPUT_DRY" "name: homelab" "Cluster named homelab"
assert_contains "$OUTPUT_DRY" "name: k3s-homelab" "Context named k3s-homelab"
assert_contains "$OUTPUT_DRY" "name: homelab-admin" "User named homelab-admin"
assert_contains "$OUTPUT_DRY" "certificate-authority-data: dGVzdC1jYS1kYXRh" "Extracted CA data intact"
assert_contains "$OUTPUT_DRY" "client-certificate-data: dGVzdC1jZXJ0LWRhdGE=" "Extracted client cert intact"
assert_contains "$OUTPUT_DRY" "client-key-data: dGVzdC1rZXktZGF0YQ==" "Extracted client key intact"

# Test 2: Custom domain and cluster name
OUTPUT_CUSTOM=$("$SETUP_ACCESS" --source "$MOCK_K3S" --server k8s.sputinik.tech --cluster-name prod-cluster --dry-run)
assert_contains "$OUTPUT_CUSTOM" "server: https://k8s.sputinik.tech:6443" "Domain server URL formatted"
assert_contains "$OUTPUT_CUSTOM" "name: prod-cluster" "Custom cluster name set"
assert_contains "$OUTPUT_CUSTOM" "name: k3s-prod-cluster" "Custom context name set"
assert_contains "$OUTPUT_CUSTOM" "name: prod-cluster-admin" "Custom user name set"

# Test 3: File writing and permission enforcement (0600)
OUT_FILE="${TEST_TMP}/target-kubeconfig"
"$SETUP_ACCESS" --source "$MOCK_K3S" --server 100.64.0.1 --output "$OUT_FILE" --skip-validation >/dev/null
test -f "$OUT_FILE"
assert_eq "true" "true" "Generated kubeconfig file exists"

FILE_PERMS="$(stat -c "%a" "$OUT_FILE")"
assert_eq "600" "$FILE_PERMS" "File permissions are 0600"

# Test 4: Validation with kubectl config view
KUBECTL_CHECK="$(kubectl --kubeconfig "$OUT_FILE" config view -o jsonpath='{.clusters[0].cluster.server}')"
assert_eq "https://100.64.0.1:6443" "$KUBECTL_CHECK" "kubectl parses generated kubeconfig properly"

# Test 5: Safe merging without corrupting existing kubeconfig
MOCK_EXISTING="${TEST_TMP}/mock-home-kube"
mkdir -p "${MOCK_EXISTING}/.kube"
cat <<'EOF' > "${MOCK_EXISTING}/.kube/config"
apiVersion: v1
clusters:
- cluster:
    server: https://work-cluster.internal:6443
  name: work-cluster
contexts:
- context:
    cluster: work-cluster
    user: work-user
  name: work-context
current-context: work-context
kind: Config
users:
- name: work-user
  user:
    token: secret-token
EOF

HOME="$MOCK_EXISTING" "$SETUP_ACCESS" --source "$MOCK_K3S" --server 187.77.241.62 --merge --skip-validation >/dev/null
MERGED_CONTEXTS="$(kubectl --kubeconfig "${MOCK_EXISTING}/.kube/config" config get-contexts -o name)"
assert_contains "$MERGED_CONTEXTS" "work-context" "Preserved existing work-context"
assert_contains "$MERGED_CONTEXTS" "k3s-homelab" "Added new k3s-homelab context"

CURRENT_CTX="$(kubectl --kubeconfig "${MOCK_EXISTING}/.kube/config" config current-context)"
assert_eq "k3s-homelab" "$CURRENT_CTX" "Active context switched to k3s-homelab"

# Test 6: Safe merging with --no-switch-context
HOME="$MOCK_EXISTING" "$SETUP_ACCESS" --source "$MOCK_K3S" --server 187.77.241.62 --cluster-name second-cluster --merge --no-switch-context --skip-validation >/dev/null
KEPT_CTX="$(kubectl --kubeconfig "${MOCK_EXISTING}/.kube/config" config current-context)"
assert_eq "k3s-homelab" "$KEPT_CTX" "Active context not modified when --no-switch-context is set"

# Test 7: Error handling for missing source
if "$SETUP_ACCESS" --source "${TEST_TMP}/nonexistent.yaml" --skip-validation >/dev/null 2>&1; then
  echo "FAIL: Expected error on nonexistent source file" >&2
  exit 1
else
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
fi

echo "All ${TESTS_PASSED}/${TESTS_RUN} unit tests passed successfully."
