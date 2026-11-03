#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/gcp-secret-manager/delete
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/gcp-secret-manager/delete"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export HEADER_LOG="$BATS_TEST_TMPDIR/header.log"
  export HEADER_FILES="$BATS_TEST_TMPDIR/header.files"
  export HEADER_MODES="$BATS_TEST_TMPDIR/header.modes"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'MOCK'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  if [ "$prev" = "-H" ] && [[ "$a" == @* ]]; then
    cat "${a#@}" >> "$HEADER_LOG"
    echo "${a#@}" >> "$HEADER_FILES"
    ls -l "${a#@}" | cut -c1-10 >> "$HEADER_MODES"
  fi
  prev="$a"
done
[ -n "$out" ] && printf '%s' "${MOCK_CURL_BODY:-}" > "$out"
printf '%s' "${MOCK_CURL_CODE:-200}"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export GSM_PROJECT_ID="my-project"
  export GSM_API_URL="https://secretmanager.googleapis.com/v1"
  export GSM_NAME_PREFIX="nullplatform"
  export GCP_ACCESS_TOKEN="tok-abc"
  export EXTERNAL_ID_PATH="organization=acme-123456789/application=api-222/DB_PASSWORD-42"
  export EXTERNAL_ID_VERSION="3"
  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY='{}'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "gcp-secret-manager delete: returns success and deletes the whole secret" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.success')" "true"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "-X DELETE"
  assert_contains "$captured" "/projects/my-project/secrets/nullplatform__organization-acme-123456789__application-api-222__DB_PASSWORD-42 "
  # The version suffix is ignored: delete removes every version.
  [[ "$captured" != *"/versions/"* ]] || false
}

@test "gcp-secret-manager delete: not found is idempotent success" {
  export MOCK_CURL_CODE=404
  export MOCK_CURL_BODY='{"error":{"code":404,"message":"Secret not found"}}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.success')" "true"
}

@test "gcp-secret-manager delete: other errors propagate as exit 1" {
  export MOCK_CURL_CODE=403
  export MOCK_CURL_BODY='{"error":{"code":403,"message":"Permission secretmanager.secrets.delete denied"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to delete secret"
  assert_contains "$output" "Underlying error: Permission secretmanager.secrets.delete denied"
  [[ "$output" != *'"success"'* ]] || false
}

@test "gcp-secret-manager delete: network failure propagates as exit 1" {
  export MOCK_CURL_CODE=000
  export MOCK_CURL_BODY=''

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "could not connect to secretmanager.googleapis.com"
}

@test "gcp-secret-manager delete: bearer token goes through a mode-600 header file, never on argv" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  if grep -q 'tok-abc' "$CURL_LOG"; then false; fi
  assert_contains "$(cat "$HEADER_LOG")" "Authorization: Bearer tok-abc"
  assert_equal "$(sort -u "$HEADER_MODES")" "-rw-------"
  # The header file is removed when the script exits.
  while read -r f; do [ ! -e "$f" ] || false; done < "$HEADER_FILES"
}
