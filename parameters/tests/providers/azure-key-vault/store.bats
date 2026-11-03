#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/azure-key-vault/store
# The AKV secret name IS the external_id: slug-free (entity ids), dash-joined,
# no prefix. Uses the Key Vault REST API via curl.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/azure-key-vault/store"

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
  export PARAMETER_VALUE="my-secret"
  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY='{"id":"https://my-vault.vault.azure.net/secrets/some-name/abc123"}'

  export CONTEXT='{
    "parameter_id": 42,
    "value": "my-secret",
    "entities": {
      "organization": "1255165411",
      "account": "95118862",
      "namespace": "37094320",
      "application": "321402625"
    },
    "dimensions": {}
  }'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "azure-key-vault store: external_id is the slug-free name + version suffix" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  expected="application-321402625-42#abc123"
  assert_equal "$external_id" "$expected"
}

@test "azure-key-vault store: secret_name is slug-free with entity types, no prefix" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_name=$(echo "$output" | jq -r '.metadata.secret_name')
  assert_equal "$secret_name" "application-321402625-42"
  # No slugs and no nullplatform- prefix.
  [[ "$secret_name" != *"nullplatform-"* ]]
  [[ "$secret_name" != *"/"* ]]
  [[ "$secret_name" != *"="* ]]
}

@test "azure-key-vault store: PUTs to the secret URL, value not on argv" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "-X PUT"
  assert_contains "$captured" "https://my-vault.vault.azure.net/secrets/application-321402625"
  assert_contains "$captured" "api-version=7.4"
  # The value travels in the body via stdin — it must NOT appear on argv.
  [[ "$captured" != *"my-secret"* ]]
}

@test "azure-key-vault store: dimensions sorted alphabetically in the name" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.dimensions = {environment: "prod", country: "arg"}')

  run bash -c "$DEPS; source $SCRIPT"

  secret_name=$(echo "$output" | jq -r '.metadata.secret_name')
  assert_contains "$secret_name" "application-321402625-country-arg-environment-prod-42"
}

@test "azure-key-vault store: uses value_entities and includes scope" {
  export CONTEXT='{
    "parameter_id": 7,
    "value_entities": { "application": "100", "scope": "200" },
    "dimensions": {}
  }'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_name=$(echo "$output" | jq -r '.metadata.secret_name')
  assert_equal "$secret_name" "application-100-scope-200-7"
}

@test "azure-key-vault store: name at exactly 127 chars is allowed" {
  # "application-321402625" (21) + "-" + <name> + "-42" (3) = 25 + len(name); 102 → 127.
  pname=$(printf 'a%.0s' $(seq 1 102))
  export CONTEXT=$(echo "$CONTEXT" | jq --arg n "$pname" '.parameter_name = $n')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_name=$(echo "$output" | jq -r '.metadata.secret_name')
  assert_equal "${#secret_name}" "127"
}

@test "azure-key-vault store: name at 128 chars fails" {
  pname=$(printf 'a%.0s' $(seq 1 103))
  export CONTEXT=$(echo "$CONTEXT" | jq --arg n "$pname" '.parameter_name = $n')

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "exceeds Azure Key Vault's 127-character limit"
}

@test "azure-key-vault store: name over 127 chars fails with a clear error" {
  # A long parameter name pushes the total over AKV's 127-char limit.
  long_name=$(printf 'x%.0s' $(seq 1 150))
  export CONTEXT=$(echo "$CONTEXT" | jq --arg n "$long_name" '.parameter_name = $n')

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "exceeds Azure Key Vault's 127-character limit"
  assert_contains "$output" "🔧 How to fix:"
  # It must fail BEFORE calling AKV.
  [ ! -s "$CURL_LOG" ]
}

@test "azure-key-vault store: fails with troubleshooting and underlying error on HTTP error" {
  export MOCK_CURL_CODE=403
  export MOCK_CURL_BODY='{"error":{"code":"Forbidden","message":"Caller is not authorized to perform action on resource."}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to store secret in Azure Key Vault"
  assert_contains "$output" "Underlying error: Caller is not authorized"
}

@test "azure-key-vault store: HTTP 000 reports a connectivity error, not an empty one" {
  export MOCK_CURL_CODE=000
  export MOCK_CURL_BODY=''

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "(HTTP 000)"
  assert_contains "$output" "could not connect to https://my-vault.vault.azure.net"
}
