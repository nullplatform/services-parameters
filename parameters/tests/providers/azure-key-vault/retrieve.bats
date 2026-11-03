#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/azure-key-vault/retrieve
# Uses the Key Vault REST API via curl (no az CLI).
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/azure-key-vault/retrieve"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'EOF'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && printf '%s' "${MOCK_CURL_BODY:-}" > "$out"
printf '%s' "${MOCK_CURL_CODE:-200}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AZ_VAULT_NAME="my-vault"
  export AZ_VAULT_URL="https://my-vault.vault.azure.net"
  export AZ_ACCESS_TOKEN="tok-abc"
  export EXTERNAL_ID_PATH="organization-1-account-2-42"
  export EXTERNAL_ID_VERSION=""
  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY='{"value":"the-stored-value"}'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "azure-key-vault retrieve: success → returns value" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  value=$(echo "$output" | jq -r '.value')
  assert_equal "$value" "the-stored-value"
}

@test "azure-key-vault retrieve: 404 fails with troubleshooting" {
  export MOCK_CURL_CODE=404
  export MOCK_CURL_BODY='{"error":{"code":"SecretNotFound","message":"A secret with (name/id) was not found."}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "not found in Azure Key Vault"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "🔧 How to fix:"
}

@test "azure-key-vault retrieve: auth error fails with underlying error" {
  export MOCK_CURL_CODE=403
  export MOCK_CURL_BODY='{"error":{"code":"Forbidden","message":"The user is not authorized to perform this action."}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve secret"
  assert_contains "$output" "Underlying error: The user is not authorized"
}

@test "azure-key-vault retrieve: unknown errors fail loud" {
  export MOCK_CURL_CODE=500
  export MOCK_CURL_BODY='{"error":{"code":"InternalServerError","message":"something went wrong."}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve secret"
}

@test "azure-key-vault retrieve: GETs the secret URL from external_id verbatim" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "-X GET"
  assert_contains "$captured" "https://my-vault.vault.azure.net/secrets/organization-1-account-2-42"
  assert_contains "$captured" "api-version=7.4"
}

@test "azure-key-vault retrieve: requests a specific version when present" {
  export EXTERNAL_ID_VERSION="ver999"

  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "/secrets/organization-1-account-2-42/ver999"
}
