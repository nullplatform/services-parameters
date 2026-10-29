#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/hashicorp-vault/delete
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/hashicorp-vault/delete"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$CURL_LOG"
if [ "${MOCK_CURL_MODE:-success}" = "network_error" ]; then exit 6; fi
want_status=0
for arg in "$@"; do
  if [ "$arg" = "-w" ]; then want_status=1; break; fi
done
if [ -n "${MOCK_HTTP_BODY:-}" ]; then printf "%s" "$MOCK_HTTP_BODY"; fi
if [ "$want_status" = "1" ]; then printf "\n%s" "${MOCK_HTTP_STATUS:-204}"; fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export VAULT_ADDR="https://vault.example.com"
  export VAULT_TOKEN="hvs.test-token"
  # external_id path is the full, self-contained Vault path (KV prefix embedded by store).
  export EXTERNAL_ID="secret/data/nullplatform/abc-123"

  export EXTERNAL_ID_PATH="$EXTERNAL_ID"
  export EXTERNAL_ID_VERSION=""
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "vault delete: 204 returns {success: true}" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=204 source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "vault delete: 200 returns {success: true}" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=200 source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "vault delete: 404 is idempotent — returns success" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=404 source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "vault delete: 403 fails with auth troubleshooting" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=403 MOCK_HTTP_BODY='{\"errors\":[\"permission denied\"]}' source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Vault DELETE failed with HTTP 403"
  assert_contains "$output" "lacks delete permission"
  assert_contains "$output" "🔧 How to fix:"
}

@test "vault delete: 500 fails with server troubleshooting" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=500 source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Vault DELETE failed with HTTP 500"
  assert_contains "$output" "Server-side error"
}

@test "vault delete: network error fails with connectivity troubleshooting" {
  run bash -c "$DEPS; MOCK_CURL_MODE=network_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Network error calling Vault"
  assert_contains "$output" "unreachable"
}

@test "vault delete: DELETEs the correct Vault URL with token header" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=204 source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "-X DELETE"
  assert_contains "$captured" "-H X-Vault-Token: hvs.test-token"
  assert_contains "$captured" "https://vault.example.com/v1/secret/data/nullplatform/abc-123"
}

@test "vault delete: applies the Vault namespace as a URL prefix" {
  export VAULT_NAMESPACE="admin/eks-null-alfa-136"

  run bash -c "$DEPS; MOCK_HTTP_STATUS=204 source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "https://vault.example.com/v1/admin/eks-null-alfa-136/secret/data/nullplatform/abc-123"
}

@test "vault delete: uses external_id path verbatim, ignoring current VAULT_PATH_PREFIX" {
  # Regression: simulates setup.namespace being reconfigured AFTER this secret was
  # stored. The full path lives in the external_id, so it must win over the current
  # prefix — otherwise the delete would target the wrong (or a non-existent) path.
  export EXTERNAL_ID_PATH="secret/data/original-ns/abc-123"
  export VAULT_PATH_PREFIX="secret/data/reconfigured-ns"

  run bash -c "$DEPS; MOCK_HTTP_STATUS=204 source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "https://vault.example.com/v1/secret/data/original-ns/abc-123"
}
