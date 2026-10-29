#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/gcp-secret-manager/store
#
# Verifies:
#   - secret id = canonical path flattened under "<prefix>__"
#   - external_id keeps the canonical slash form + "#<version>"
#   - addVersion first; only a 404 (first store) creates the secret, then retries
#   - The value travels base64-encoded in the body, never on argv
#   - The bearer token travels in a mode-600 header file, never on argv
#   - Replication: automatic by default, user-managed with replica locations
#   - Labels: NRN ids and slugs (+ scope when present), managed_by and
#     parameter_id, normalized to the label charset and never overridable
#   - Real errors propagate with troubleshooting
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_ROOT="$PARAMETERS_DIR"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/gcp-secret-manager/store"

  # Mock `curl`: logs argv and the stdin body, and picks the response per call —
  # secret creation (?secretId=) vs addVersion (:addVersion).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export HEADER_LOG="$BATS_TEST_TMPDIR/header.log"
  export HEADER_FILES="$BATS_TEST_TMPDIR/header.files"
  export HEADER_MODES="$BATS_TEST_TMPDIR/header.modes"
  export BODY_LOG="$BATS_TEST_TMPDIR/body.log"
  export ADD_COUNT="$BATS_TEST_TMPDIR/add.count"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'MOCK'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
out=""; prev=""; call="other"
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  if [ "$prev" = "-H" ] && [[ "$a" == @* ]]; then
    cat "${a#@}" >> "$HEADER_LOG"
    echo "${a#@}" >> "$HEADER_FILES"
    ls -l "${a#@}" | cut -c1-10 >> "$HEADER_MODES"
  fi
  case "$a" in
    *"?secretId="*) call="create" ;;
    *":addVersion"*) call="add" ;;
  esac
  prev="$a"
done
if [[ " $* " == *" --data-binary @- "* ]]; then
  { echo "[$call]"; cat; echo; } >> "$BODY_LOG"
fi
case "$call" in
  create) code="${MOCK_CREATE_CODE:-200}"; body="${MOCK_CREATE_BODY:-}" ;;
  add)
    # MOCK_ADD_CODES is a comma-separated sequence, one entry per addVersion call.
    n=$(( $(cat "$ADD_COUNT" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$ADD_COUNT"
    code=$(echo "${MOCK_ADD_CODES:-200}" | cut -d, -f"$n")
    [ -z "$code" ] && code=$(echo "${MOCK_ADD_CODES:-200}" | awk -F, '{print $NF}')
    if [ "$code" = "200" ]; then body="${MOCK_ADD_BODY:-}"; else body="${MOCK_ADD_ERROR_BODY:-}"; fi
    ;;
  *)      code="500";                      body="" ;;
esac
[ -n "$out" ] && printf '%s' "$body" > "$out"
printf '%s' "$code"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export GSM_PROJECT_ID="my-project"
  export GSM_API_URL="https://secretmanager.googleapis.com/v1"
  export GSM_NAME_PREFIX="nullplatform"
  export GSM_REPLICA_LOCATIONS=""
  export GCP_ACCESS_TOKEN="tok-abc"
  export PARAMETER_ID="42"
  export PARAMETER_VALUE="my-secret"
  export MOCK_CREATE_CODE=200
  export MOCK_CREATE_BODY='{"name":"projects/123/secrets/x"}'
  # Default: the secret already exists, so the first addVersion succeeds.
  export MOCK_ADD_CODES=200
  export MOCK_ADD_ERROR_BODY='{"error":{"code":404,"message":"Secret not found"}}'
  export MOCK_ADD_BODY='{"name":"projects/123/secrets/x/versions/3","state":"ENABLED"}'

  export CONTEXT='{
    "parameter_id": 42,
    "parameter_name": "DB_PASSWORD",
    "value": "my-secret",
    "entities": {
      "organization": "123456789", "organization_slug": "acme",
      "account": "987654321", "account_slug": "production",
      "namespace": "111", "namespace_slug": "billing",
      "application": "222", "application_slug": "api"
    },
    "dimensions": {}
  }'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "gcp-secret-manager store: external_id is the canonical path + version suffix" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  assert_equal "$external_id" "organization=acme-123456789/account=production-987654321/namespace=billing-111/application=api-222/DB_PASSWORD-42#3"
}

@test "gcp-secret-manager store: secret id is the flattened path under the prefix" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_id=$(echo "$output" | jq -r '.metadata.secret_id')
  assert_equal "$secret_id" "nullplatform__organization-acme-123456789__account-production-987654321__namespace-billing-111__application-api-222__DB_PASSWORD-42"
  [[ "$secret_id" =~ ^[A-Za-z0-9_-]+$ ]] || false
}

@test "gcp-secret-manager store: metadata carries the version resource name and project" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$(echo "$output" | jq -r '.metadata.version_name')" "projects/123/secrets/x/versions/3"
  assert_equal "$(echo "$output" | jq -r '.metadata.project_id')" "my-project"
}

@test "gcp-secret-manager store: existing secret only adds a version (single call)" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "/secrets/nullplatform__organization-acme-123456789__account-production-987654321__namespace-billing-111__application-api-222__DB_PASSWORD-42:addVersion"
  assert_equal "$(grep -c '' "$CURL_LOG")" "1"
  if grep -q 'secretId=' "$CURL_LOG"; then false; fi
}

@test "gcp-secret-manager store: first store (404) creates the secret, then adds the version" {
  export MOCK_ADD_CODES="404,200"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(grep -c '' "$CURL_LOG")" "3"
  assert_contains "$(sed -n 2p "$CURL_LOG")" "https://secretmanager.googleapis.com/v1/projects/my-project/secrets?secretId=nullplatform__organization-acme-123456789"
  assert_contains "$(sed -n 3p "$CURL_LOG")" ":addVersion"
  assert_equal "$(echo "$output" | jq -r '.external_id' | sed 's/.*#//')" "3"
}

@test "gcp-secret-manager store: value travels base64-encoded on stdin, not on argv" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  if grep -q 'my-secret' "$CURL_LOG"; then false; fi
  assert_contains "$(cat "$BODY_LOG")" "$(printf 'my-secret' | base64)"
}

@test "gcp-secret-manager store: automatic replication and nullplatform labels on create" {
  export MOCK_ADD_CODES="404,200"

  run bash -c "$DEPS; source $SCRIPT"

  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -c '.replication')" '{"automatic":{}}'
  assert_equal "$(echo "$create_body" | jq -r '.labels.managed_by')" "nullplatform"
  assert_equal "$(echo "$create_body" | jq -r '.labels.parameter_id')" "42"
}

@test "gcp-secret-manager store: replica locations switch to user-managed replication" {
  export MOCK_ADD_CODES="404,200"
  export GSM_REPLICA_LOCATIONS="europe-west1,us-east1"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -c '.replication')" '{"userManaged":{"replicas":[{"location":"europe-west1"},{"location":"us-east1"}]}}'
}

@test "gcp-secret-manager store: create racing with another store (409) still adds the version" {
  export MOCK_ADD_CODES="404,200"
  export MOCK_CREATE_CODE=409
  export MOCK_CREATE_BODY='{"error":{"code":409,"message":"Secret already exists"}}'

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  assert_equal "$(grep -c '' "$CURL_LOG")" "3"
}

@test "gcp-secret-manager store: parameter_id label is normalized to the label charset" {
  export MOCK_ADD_CODES="404,200"
  export PARAMETER_ID="Abc.42"

  run bash -c "$DEPS; source $SCRIPT"

  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -r '.labels.parameter_id')" "abc-42"
}

@test "gcp-secret-manager store: application-level value is labeled with its NRN ids and slugs, no scope" {
  export MOCK_ADD_CODES="404,200"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -cS '.labels')" '{"account":"production","account_id":"987654321","application":"api","application_id":"222","managed_by":"nullplatform","namespace":"billing","namespace_id":"111","organization":"acme","organization_id":"123456789","parameter_id":"42"}'
}

@test "gcp-secret-manager store: scope-level value also carries the scope labels" {
  export MOCK_ADD_CODES="404,200"
  export CONTEXT=$(echo "$CONTEXT" | jq '.value_entities = (.entities + {scope: "333", scope_slug: "prod"})')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -r '.labels.scope_id')" "333"
  assert_equal "$(echo "$create_body" | jq -r '.labels.scope')" "prod"
  assert_equal "$(echo "$create_body" | jq -r '.labels.application')" "api"
  assert_equal "$(echo "$create_body" | jq '.labels | length')" "12"
}

@test "gcp-secret-manager store: NRN label values are normalized to the label charset" {
  export MOCK_ADD_CODES="404,200"
  long_slug=$(printf 'a%.0s' {1..70})
  export CONTEXT=$(echo "$CONTEXT" | jq --arg long "$long_slug" '.entities.account_slug = "Prod.Main" | .entities.namespace_slug = $long')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -r '.labels.account')" "prod-main"
  assert_equal "$(echo "$create_body" | jq -r '.labels.namespace | length')" "63"
  echo "$create_body" | jq -e '.labels | to_entries | all(.value | test("^[a-z0-9_-]{0,63}$"))'
}

@test "gcp-secret-manager store: platform labels cannot be overridden from the payload" {
  export MOCK_ADD_CODES="404,200"
  export CONTEXT=$(echo "$CONTEXT" | jq '.tags = {managed_by: "someone", organization_id: "spoofed", team: "payments"} | .labels = {parameter_id: "spoofed"}')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  create_body=$(sed -n '/^\[create\]$/{n;p;}' "$BODY_LOG")
  assert_equal "$(echo "$create_body" | jq -r '.labels.managed_by')" "nullplatform"
  assert_equal "$(echo "$create_body" | jq -r '.labels.parameter_id')" "42"
  assert_equal "$(echo "$create_body" | jq -r '.labels.organization_id')" "123456789"
  assert_equal "$(echo "$create_body" | jq '.labels | has("team")')" "false"
}

@test "gcp-secret-manager store: an existing secret's labels are not touched" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  if grep -q '"labels"' "$BODY_LOG"; then false; fi
}

@test "gcp-secret-manager store: the value stays off argv when labels are built" {
  export MOCK_ADD_CODES="404,200"
  mkdir -p "$BATS_TEST_TMPDIR/jqbin"
  real_jq=$(command -v jq)
  printf '#!/bin/bash\necho "jq $*" >> "%s"\nexec %s "$@"\n' "$BATS_TEST_TMPDIR/jq.log" "$real_jq" > "$BATS_TEST_TMPDIR/jqbin/jq"
  chmod +x "$BATS_TEST_TMPDIR/jqbin/jq"

  run bash -c "export PATH=$BATS_TEST_TMPDIR/jqbin:\$PATH; $DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  if grep -q 'my-secret' "$BATS_TEST_TMPDIR/jq.log"; then false; fi
}

@test "gcp-secret-manager store: dimensions sorted alphabetically, scope included" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.value_entities = (.entities + {scope: "333", scope_slug: "prod"}) | .dimensions = {environment: "production", country: "br"}')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_id=$(echo "$output" | jq -r '.metadata.secret_id')
  assert_contains "$secret_id" "__application-api-222__scope-prod-333__country-br__environment-production__DB_PASSWORD-42"
}

@test "gcp-secret-manager store: characters outside the charset are mapped to dashes" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.parameter_name = "db.password"')

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  secret_id=$(echo "$output" | jq -r '.metadata.secret_id')
  assert_contains "$secret_id" "__db-password-42"
}

@test "gcp-secret-manager store: secret id over 255 chars fails with a clear error" {
  long_name=$(printf 'x%.0s' $(seq 1 200))
  export CONTEXT=$(echo "$CONTEXT" | jq --arg n "$long_name" '.parameter_name = $n')

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "exceeds GCP Secret Manager's 255-character limit"
  assert_contains "$output" "🔧 How to fix:"
  [ ! -f "$CURL_LOG" ] || false
}

@test "gcp-secret-manager store: bearer token goes through a mode-600 header file, never on argv" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  if grep -q 'tok-abc' "$CURL_LOG"; then false; fi
  assert_contains "$(cat "$HEADER_LOG")" "Authorization: Bearer tok-abc"
  assert_equal "$(sort -u "$HEADER_MODES")" "-rw-------"
  # The header file is removed when the script exits.
  while read -r f; do [ ! -e "$f" ] || false; done < "$HEADER_FILES"
}

@test "gcp-secret-manager store: create succeeds but the retried addVersion fails, and the failure propagates" {
  export MOCK_ADD_CODES="404,500"
  export MOCK_CREATE_CODE=200
  export MOCK_ADD_ERROR_BODY='{"error":{"code":500,"message":"Internal error adding version"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_equal "$(grep -c '' "$CURL_LOG")" "3"
  assert_contains "$(sed -n 2p "$CURL_LOG")" "?secretId="
  assert_contains "$(sed -n 3p "$CURL_LOG")" ":addVersion"
  assert_contains "$output" "❌ Failed to add a version to secret"
  assert_contains "$output" "(HTTP 500)"
  assert_contains "$output" "Underlying error: Internal error adding version"
  [[ "$output" != *'"external_id"'* ]] || false
}

@test "gcp-secret-manager store: create failure propagates with the API error" {
  export MOCK_ADD_CODES="404"
  export MOCK_CREATE_CODE=403
  export MOCK_CREATE_BODY='{"error":{"code":403,"message":"Permission secretmanager.secrets.create denied"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to create secret"
  assert_contains "$output" "(HTTP 403)"
  assert_contains "$output" "Underlying error: Permission secretmanager.secrets.create denied"
}

@test "gcp-secret-manager store: addVersion failure propagates with the API error" {
  export MOCK_ADD_CODES=403
  export MOCK_ADD_ERROR_BODY='{"error":{"code":403,"message":"Permission secretmanager.versions.add denied"}}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to add a version to secret"
  assert_contains "$output" "Underlying error: Permission secretmanager.versions.add denied"
}

@test "gcp-secret-manager store: network failure reports no HTTP response" {
  export MOCK_ADD_CODES=000

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "(HTTP 000)"
  assert_contains "$output" "could not connect to secretmanager.googleapis.com"
}
