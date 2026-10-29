#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/gcp-secret-manager/retrieve
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/gcp-secret-manager/retrieve"

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
  export EXTERNAL_ID_PATH="organization=acme-123456789/account=production-987654321/application=api-222/DB_PASSWORD-42"
  export EXTERNAL_ID_VERSION=""
  export EXPECTED_SECRET_ID="nullplatform__organization-acme-123456789__account-production-987654321__application-api-222__DB_PASSWORD-42"
  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY="{\"name\":\"projects/123/secrets/x/versions/3\",\"payload\":{\"data\":\"$(printf 'my-secret' | base64)\"}}"

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "gcp-secret-manager retrieve: hit returns the decoded value" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.value')" "my-secret"
}

@test "gcp-secret-manager retrieve: multi-line and unicode values round-trip" {
  value=$'line one\nlínea dos: ñ ✓'
  export MOCK_CURL_BODY="{\"payload\":{\"data\":\"$(printf '%s' "$value" | base64 | tr -d '\n')\"}}"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -r '.value')" "$value"
}

@test "gcp-secret-manager retrieve: trailing newlines in the value are preserved" {
  value=$'secret-with-newline\n\n'
  export MOCK_CURL_BODY="{\"payload\":{\"data\":\"$(printf '%s' "$value" | base64 | tr -d '\n')\"}}"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(echo "$output" | jq -c '.value')" '"secret-with-newline\n\n"'
}

@test "gcp-secret-manager retrieve: a response without payload fails with troubleshooting" {
  export MOCK_CURL_BODY='{"name":"projects/123/secrets/x/versions/3"}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Secret Manager returned no payload"
  assert_contains "$output" "🔧 How to fix:"
}

@test "gcp-secret-manager retrieve: without a version reads latest" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "/projects/my-project/secrets/$EXPECTED_SECRET_ID/versions/latest:access"
}

@test "gcp-secret-manager retrieve: with a version targets that historical revision" {
  export EXTERNAL_ID_VERSION="2"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "/secrets/$EXPECTED_SECRET_ID/versions/2:access"
}

@test "gcp-secret-manager retrieve: not found exits non-zero with troubleshooting" {
  export MOCK_CURL_CODE=404
  export MOCK_CURL_BODY='{"error":{"code":404,"message":"Secret not found"}}'
  export EXTERNAL_ID_VERSION="7"

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Secret '$EXPECTED_SECRET_ID' (version 7) not found"
  assert_contains "$output" "Requested version '7' does not exist"
  assert_contains "$output" "🔧 How to fix:"
  [[ "$output" != *'"value"'* ]] || false
}

@test "gcp-secret-manager retrieve: permission error exits non-zero with the API error" {
  export MOCK_CURL_CODE=403
  export MOCK_CURL_BODY='{"error":{"code":403,"message":"Permission secretmanager.versions.access denied"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve secret"
  assert_contains "$output" "(HTTP 403)"
  assert_contains "$output" "Underlying error: Permission secretmanager.versions.access denied"
}

@test "gcp-secret-manager retrieve: network failure reports no HTTP response" {
  export MOCK_CURL_CODE=000
  export MOCK_CURL_BODY=''

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "could not connect to secretmanager.googleapis.com"
}

@test "gcp-secret-manager retrieve: bearer token goes through a mode-600 header file, never on argv" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  if grep -q 'tok-abc' "$CURL_LOG"; then false; fi
  assert_contains "$(cat "$HEADER_LOG")" "Authorization: Bearer tok-abc"
  assert_equal "$(sort -u "$HEADER_MODES")" "-rw-------"
  # The header file is removed when the script exits.
  while read -r f; do [ ! -e "$f" ] || false; done < "$HEADER_FILES"
}

@test "gcp-secret-manager retrieve: explicit 'latest' version is accepted" {
  export EXTERNAL_ID_VERSION="latest"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$(cat "$CURL_LOG")" "/secrets/$EXPECTED_SECRET_ID/versions/latest:access"
}

@test "gcp-secret-manager retrieve: path traversal in the version is rejected before any call" {
  export EXTERNAL_ID_VERSION="../../nullplatform__organization-other-1__x/versions/latest"

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Invalid secret version"
  assert_contains "$output" "🔧 How to fix:"
  [ ! -f "$CURL_LOG" ] || false
}

@test "gcp-secret-manager retrieve: non-numeric version is rejected" {
  for v in "abc" "3a" "-1" "1.0" "LATEST" " 3"; do
    rm -f "$CURL_LOG"
    export EXTERNAL_ID_VERSION="$v"

    run bash -c "$DEPS; source $SCRIPT"

    [ "$status" -ne 0 ]
    assert_contains "$output" "❌ Invalid secret version"
    [ ! -f "$CURL_LOG" ] || false
  done
}
