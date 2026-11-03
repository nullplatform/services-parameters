#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/hashicorp-vault/retrieve
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/hashicorp-vault/retrieve"

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
if [ "$want_status" = "1" ]; then printf "\n%s" "${MOCK_HTTP_STATUS:-200}"; fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export VAULT_ADDR="https://vault.example.com"
  export VAULT_TOKEN="hvs.test-token"
  # external_id path is the full, self-contained Vault path (KV prefix embedded by store).
  export EXTERNAL_ID="secret/data/nullplatform/abc-123"

  export EXTERNAL_ID_PATH="$EXTERNAL_ID"
  export EXTERNAL_ID_VERSION=""
  export CONTEXT='{}'
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "vault retrieve: 200 returns stored value" {
  body='{"data":{"data":{"value":"the-real-secret","parameter_id":42}}}'

  run bash -c "$DEPS; MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='$body' source $SCRIPT"

  assert_equal "$status" "0"
  value=$(echo "$output" | jq -r '.value')
  assert_equal "$value" "the-real-secret"
}

@test "vault retrieve: 200 preserves values with quotes without JSON injection" {
  # A stored value crafted to break naive string-interpolated JSON output.
  malicious='inject","injected":"x'
  body=$(jq -nc --arg v "$malicious" '{data:{data:{value:$v}}}')

  run bash -c "$DEPS; MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='$body' source $SCRIPT"

  assert_equal "$status" "0"
  # Output must be valid JSON with the value preserved verbatim...
  echo "$output" | jq -e . >/dev/null
  value=$(echo "$output" | jq -r '.value')
  assert_equal "$value" "$malicious"
  # ...and must NOT have gained an injected top-level key.
  injected=$(echo "$output" | jq -r '.injected // "ABSENT"')
  assert_equal "$injected" "ABSENT"
}

@test "vault retrieve: 404 fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=404 source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "not found in Vault"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "🔧 How to fix:"
}

@test "vault retrieve: 403 fails with auth troubleshooting" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=403 MOCK_HTTP_BODY='{\"errors\":[\"permission denied\"]}' source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Vault GET failed with HTTP 403"
  assert_contains "$output" "lacks read permission"
}

@test "vault retrieve: 500 fails with server troubleshooting" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=500 source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Vault GET failed with HTTP 500"
}

@test "vault retrieve: network error fails with connectivity troubleshooting" {
  run bash -c "$DEPS; MOCK_CURL_MODE=network_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Network error calling Vault"
}

@test "vault retrieve: GETs the correct Vault URL with token header" {
  body='{"data":{"data":{"value":"x"}}}'
  run bash -c "$DEPS; MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='$body' source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "-H X-Vault-Token: hvs.test-token"
  assert_contains "$captured" "https://vault.example.com/v1/secret/data/nullplatform/abc-123"
}

@test "vault retrieve: applies the Vault namespace as a URL prefix" {
  export VAULT_NAMESPACE="admin/eks-null-alfa-136"
  body='{"data":{"data":{"value":"x"}}}'

  run bash -c "$DEPS; MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='$body' source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "https://vault.example.com/v1/admin/eks-null-alfa-136/secret/data/nullplatform/abc-123"
}

@test "vault retrieve: uses external_id path verbatim, ignoring current VAULT_PATH_PREFIX" {
  # Regression: simulates setup.namespace being reconfigured AFTER this secret was
  # stored. The full path lives in the external_id, so it must win over the current
  # prefix — otherwise the reference would be silently lost.
  export EXTERNAL_ID_PATH="secret/data/original-ns/abc-123"
  export VAULT_PATH_PREFIX="secret/data/reconfigured-ns"
  body='{"data":{"data":{"value":"x"}}}'

  run bash -c "$DEPS; MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='$body' source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "https://vault.example.com/v1/secret/data/original-ns/abc-123"
}
