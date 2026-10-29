#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/azure-key-vault/setup
# Auth is a service-principal client-credentials flow via curl (no az CLI).
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/azure-key-vault/setup"
  export DEPS="source $PARAMETERS_DIR/utils/log; source $PARAMETERS_DIR/utils/get_config_value"

  # Mock `curl`: logs every invocation, writes MOCK_CURL_BODY to the -o file and
  # prints MOCK_CURL_CODE (the %{http_code} the script reads).
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

  # Sensible defaults so most tests just set the vault name.
  export AZURE_CLIENT_ID="client-123"
  export AZURE_CLIENT_SECRET="secret-abc"
  export AZURE_TENANT_ID="tenant-xyz"
  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY='{"access_token":"tok-abc"}'
}

teardown() {
  unset AZURE_KEY_VAULT_NAME AZ_VAULT_NAME AZ_VAULT_URL \
    AZ_ACCESS_TOKEN PROVIDER_CONFIG AZURE_CLIENT_ID AZURE_CLIENT_SECRET \
    AZURE_TENANT_ID MOCK_CURL_CODE MOCK_CURL_BODY
}

@test "azure-key-vault setup: fails when vault name is missing" {
  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Azure Key Vault name not configured"
  assert_contains "$output" "🔧 How to fix:"
}

@test "azure-key-vault setup: vault name from env" {
  export AZURE_KEY_VAULT_NAME="my-vault"

  run bash -c "$DEPS; source $SCRIPT && echo VAULT=\$AZ_VAULT_NAME URL=\$AZ_VAULT_URL TOKEN=\$AZ_ACCESS_TOKEN"

  assert_equal "$status" "0"
  assert_contains "$output" "VAULT=my-vault"
  assert_contains "$output" "URL=https://my-vault.vault.azure.net"
  assert_contains "$output" "TOKEN=tok-abc"
}

@test "azure-key-vault setup: vault_name from PROVIDER_CONFIG" {
  export PROVIDER_CONFIG='{"setup":{"vault_name":"cfg-vault"}}'

  run bash -c "$DEPS; source $SCRIPT && echo VAULT=\$AZ_VAULT_NAME"

  assert_equal "$status" "0"
  assert_contains "$output" "VAULT=cfg-vault"
}

@test "azure-key-vault setup: requests a token from the Azure AD endpoint" {
  export AZURE_KEY_VAULT_NAME="my-vault"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "login.microsoftonline.com/tenant-xyz/oauth2/v2.0/token"
}

@test "azure-key-vault setup: fails when service principal credentials are missing" {
  export AZURE_KEY_VAULT_NAME="my-vault"
  unset AZURE_CLIENT_SECRET

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Azure service principal credentials not configured"
}

@test "azure-key-vault setup: surfaces the underlying error when auth fails" {
  export AZURE_KEY_VAULT_NAME="my-vault"
  export MOCK_CURL_CODE=401
  export MOCK_CURL_BODY='{"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided."}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Azure service principal authentication failed (HTTP 401)"
  assert_contains "$output" "Underlying error: AADSTS7000215: Invalid client secret provided."
}
