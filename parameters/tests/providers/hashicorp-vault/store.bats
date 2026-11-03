#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/hashicorp-vault/store
# external_id is now composed via parameters/utils/build_external_id.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_ROOT="$PARAMETERS_DIR"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/hashicorp-vault/store"

  mkdir -p "$BATS_TEST_TMPDIR/bin"

  # Mock curl. store passes -w "\n%{http_code}", so append the HTTP status on a
  # trailing line; store validates it (curl -s alone exits 0 even on HTTP errors).
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$CURL_LOG"
if [ "${MOCK_CURL_EXIT:-0}" -ne 0 ]; then exit "$MOCK_CURL_EXIT"; fi
# Vault KV v2 returns the new version number in the response body.
default_body='{"data":{"created_time":"2026-06-23T00:00:00Z","version":3,"deletion_time":"","destroyed":false}}'
printf '%s' "${MOCK_HTTP_BODY:-$default_body}"
printf '\n%s' "${MOCK_HTTP_STATUS:-200}"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"

  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export VAULT_ADDR="https://vault.example.com"
  export VAULT_TOKEN="hvs.test-token"
  export VAULT_PATH_PREFIX="secret/data/nullplatform"
  export PARAMETER_ID=42
  export PARAMETER_VALUE="my-secret"
  # Slugs travel in the payload next to each entity id (build_external_id reads
  # them straight from CONTEXT — no np call, no cache files).
  export CONTEXT='{
    "parameter_id": 42,
    "value": "my-secret",
    "entities": {
      "organization": "1255165411",
      "organization_slug": "acme",
      "account": "95118862",
      "account_slug": "prod",
      "namespace": "37094320",
      "namespace_slug": "billing",
      "application": "321402625",
      "application_slug": "api"
    },
    "dimensions": {}
  }'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "vault store: external_id composed from entities + parameter_id + version" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  # external_id embeds the KV path prefix and the version (mock returns .data.version=3).
  expected="secret/data/nullplatform/organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/42#3"
  assert_equal "$external_id" "$expected"
}

@test "vault store: external_id includes sorted dimensions" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.dimensions = {environment: "prod", country: "arg"}')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  # Dimensions sorted alphabetically: country before environment
  assert_contains "$external_id" "country=arg/environment=prod/42"
}

@test "vault store: vault_path contains external_id" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  vault_path=$(echo "$output" | jq -r '.metadata.vault_path')
  assert_contains "$vault_path" "secret/data/nullplatform/organization=acme-1255165411"
  assert_contains "$vault_path" "/42"
}

@test "vault store: POSTs to Vault URL with token" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "-X POST"
  assert_contains "$captured" "-H X-Vault-Token: hvs.test-token"
  assert_contains "$captured" "https://vault.example.com/v1/secret/data/nullplatform/organization=acme-1255165411"
}

@test "vault store: POST body contains parameter_id, value, external_id, stored_at" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" '"parameter_id":42'
  assert_contains "$captured" '"value":"my-secret"'
  assert_contains "$captured" '"external_id":"secret/data/nullplatform/organization=acme-1255165411'
  assert_contains "$captured" '"stored_at":"'
}

@test "vault store: fails with troubleshooting when curl returns non-zero" {
  run bash -c "$DEPS; MOCK_CURL_EXIT=22 source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Network error storing parameter in Vault"
  assert_contains "$output" "💡 Possible causes:"
}

@test "vault store: fails when Vault returns a non-2xx status (silent-write regression)" {
  # Regression: a failed KV write (wrong mount / namespace / permission) must NOT
  # be reported as success. curl -s exits 0 on HTTP 4xx, so store must inspect the
  # HTTP status, not just curl's exit code.
  run bash -c "$DEPS; MOCK_HTTP_STATUS=404 MOCK_HTTP_BODY='{\"errors\":[]}' source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Vault write failed with HTTP 404"
  assert_contains "$output" "🔧 How to fix:"
}

@test "vault store: fails when Vault returns 403 (no write permission)" {
  run bash -c "$DEPS; MOCK_HTTP_STATUS=403 MOCK_HTTP_BODY='{\"errors\":[\"permission denied\"]}' source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Vault write failed with HTTP 403"
}

@test "vault store: applies the Vault namespace as a URL prefix" {
  export VAULT_NAMESPACE="admin/eks-null-alfa-136"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "https://vault.example.com/v1/admin/eks-null-alfa-136/secret/data/nullplatform/organization=acme-1255165411"
  # The namespace is NOT baked into the external_id (it comes from current config).
  external_id=$(echo "$output" | jq -r '.external_id')
  assert_contains "$external_id" "secret/data/nullplatform/organization=acme-1255165411"
  [[ "$external_id" != admin/* ]]
}

@test "vault store: external_id embeds a custom VAULT_PATH_PREFIX" {
  export VAULT_PATH_PREFIX="kv/data/custom-mount"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  # The configured prefix is baked into the external_id, not just the request URL.
  assert_contains "$external_id" "kv/data/custom-mount/organization=acme-1255165411"
}

@test "vault store: works without dimensions" {
  export CONTEXT=$(echo "$CONTEXT" | jq 'del(.dimensions)')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  expected="secret/data/nullplatform/organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/42#3"
  assert_equal "$external_id" "$expected"
}
