#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/azure-key-vault/delete
# Two-step: soft-delete + purge via the REST API. Purge failures are warnings.
# =============================================================================

bats_require_minimum_version 1.5.0

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/azure-key-vault/delete"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  # Distinguish the soft-delete (DELETE /secrets/...) from the purge
  # (DELETE /deletedsecrets/...) by the URL, and pick per-call code/body.
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'EOF'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
out=""; prev=""; is_purge=0
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in *deletedsecrets*) is_purge=1 ;; esac
  prev="$a"
done
if [ "$is_purge" = "1" ]; then
  code="${MOCK_PURGE_CODE:-200}"; body="${MOCK_PURGE_BODY:-}"
else
  code="${MOCK_DELETE_CODE:-200}"; body="${MOCK_DELETE_BODY:-}"
fi
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '%s' "$code"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AZ_VAULT_NAME="my-vault"
  export AZ_VAULT_URL="https://my-vault.vault.azure.net"
  export AZ_ACCESS_TOKEN="tok-abc"
  export EXTERNAL_ID_PATH="organization-1-account-2-42"
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "azure-key-vault delete: both delete + purge succeed → {success: true}" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "azure-key-vault delete: 404 on delete is idempotent → success" {
  export MOCK_DELETE_CODE=404
  export MOCK_DELETE_BODY='{"error":{"code":"SecretNotFound","message":"not found."}}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "azure-key-vault delete: delete auth error fails with troubleshooting" {
  export MOCK_DELETE_CODE=403
  export MOCK_DELETE_BODY='{"error":{"code":"Forbidden","message":"not authorized."}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to delete secret"
  assert_contains "$output" "lacks Delete permission"
}

@test "azure-key-vault delete: purge forbidden is downgraded to warning, still success" {
  export MOCK_PURGE_CODE=403
  export MOCK_PURGE_BODY='{"error":{"code":"Forbidden","message":"purge not allowed."}}'

  run --separate-stderr bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
  assert_contains "$stderr" "⚠️"
  assert_contains "$stderr" "Purge permission missing"
}

@test "azure-key-vault delete: purge 409 (purge protection) is expected, no warning" {
  export MOCK_PURGE_CODE=409
  export MOCK_PURGE_BODY='{"error":{"code":"Conflict","message":"purge protection is enabled."}}'

  run --separate-stderr bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
  [[ "$stderr" != *"⚠️"* ]]
}

@test "azure-key-vault delete: purge other failure is warning, still success" {
  export MOCK_PURGE_CODE=500
  export MOCK_PURGE_BODY='{"error":{"code":"InternalServerError","message":"boom."}}'

  run --separate-stderr bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
  assert_contains "$stderr" "⚠️ Purge failed"
}

@test "azure-key-vault delete: calls both delete and purge endpoints" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "/secrets/organization-1-account-2-42"
  assert_contains "$captured" "/deletedsecrets/organization-1-account-2-42"
}

@test "azure-key-vault delete: skips purge if delete returned 404" {
  export MOCK_DELETE_CODE=404
  export MOCK_DELETE_BODY='{"error":{"code":"SecretNotFound","message":"not found."}}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "/secrets/organization-1-account-2-42"
  # Purge must NOT have been attempted after a 404 delete.
  [[ "$captured" != *"deletedsecrets"* ]]
}
