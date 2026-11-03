#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/gcp-secret-manager/setup
# Auth is the metadata server (Workload Identity) via curl, or GCP_ACCESS_TOKEN.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/gcp-secret-manager/setup"
  export DEPS="source $PARAMETERS_DIR/utils/log; source $PARAMETERS_DIR/utils/get_config_value"

  # Mock `curl`: logs every invocation, writes MOCK_CURL_BODY to the -o file and
  # prints MOCK_CURL_CODE (the %{http_code} the script reads).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  cat > "$BATS_TEST_TMPDIR/bin/curl" << 'MOCK'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && printf '%s' "${MOCK_CURL_BODY:-}" > "$out"
printf '%s' "${MOCK_CURL_CODE:-200}"
MOCK
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export MOCK_CURL_CODE=200
  export MOCK_CURL_BODY='{"access_token":"tok-meta","expires_in":3599,"token_type":"Bearer"}'
}

teardown() {
  unset GCP_SECRET_MANAGER_PROJECT_ID GCP_SECRET_MANAGER_NAME_PREFIX \
    GCP_SECRET_MANAGER_REPLICA_LOCATIONS GCP_ACCESS_TOKEN GSM_PROJECT_ID \
    GSM_API_URL GSM_NAME_PREFIX GSM_REPLICA_LOCATIONS PROVIDER_CONFIG \
    MOCK_CURL_CODE MOCK_CURL_BODY
}

@test "gcp-secret-manager setup: fails when project id is missing" {
  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ GCP Secret Manager project not configured"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "🔧 How to fix:"
}

@test "gcp-secret-manager setup: project id from env, defaults applied" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"

  run bash -c "$DEPS; source $SCRIPT && echo PROJECT=\$GSM_PROJECT_ID PREFIX=\$GSM_NAME_PREFIX URL=\$GSM_API_URL REPLICAS=[\$GSM_REPLICA_LOCATIONS] TOKEN=\$GCP_ACCESS_TOKEN"

  assert_equal "$status" "0"
  assert_contains "$output" "PROJECT=my-project"
  assert_contains "$output" "PREFIX=nullplatform"
  assert_contains "$output" "URL=https://secretmanager.googleapis.com/v1"
  assert_contains "$output" "REPLICAS=[]"
  assert_contains "$output" "TOKEN=tok-meta"
}

@test "gcp-secret-manager setup: PROVIDER_CONFIG wins over env" {
  export GCP_SECRET_MANAGER_PROJECT_ID="env-project"
  export PROVIDER_CONFIG='{"setup":{"project_id":"cfg-project","name_prefix":"np-acme","replica_locations":["europe-west1","us-east1"]}}'

  run bash -c "$DEPS; source $SCRIPT && echo PROJECT=\$GSM_PROJECT_ID PREFIX=\$GSM_NAME_PREFIX REPLICAS=\$GSM_REPLICA_LOCATIONS"

  assert_equal "$status" "0"
  assert_contains "$output" "PROJECT=cfg-project"
  assert_contains "$output" "PREFIX=np-acme"
  assert_contains "$output" "REPLICAS=europe-west1,us-east1"
}

@test "gcp-secret-manager setup: rejects a prefix outside the secret id charset" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"
  export GCP_SECRET_MANAGER_NAME_PREFIX="null/platform"

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Invalid GCP Secret Manager name prefix 'null/platform'"
}

@test "gcp-secret-manager setup: rejects a prefix containing the '__' separator" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"
  export GCP_SECRET_MANAGER_NAME_PREFIX="np__x"

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Invalid GCP Secret Manager name prefix 'np__x'"
}

@test "gcp-secret-manager setup: requests the token from the metadata server" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  captured=$(cat "$CURL_LOG")
  assert_contains "$captured" "Metadata-Flavor: Google"
  assert_contains "$captured" "metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
  assert_contains "$captured" "--max-time"
}

@test "gcp-secret-manager setup: GCP_ACCESS_TOKEN skips the metadata server" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"
  export GCP_ACCESS_TOKEN="tok-env"

  run bash -c "$DEPS; source $SCRIPT && echo TOKEN=\$GCP_ACCESS_TOKEN"

  assert_equal "$status" "0"
  assert_contains "$output" "TOKEN=tok-env"
  [ ! -f "$CURL_LOG" ] || false
}

@test "gcp-secret-manager setup: fails with troubleshooting when there is no metadata server" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"
  export MOCK_CURL_CODE=000
  export MOCK_CURL_BODY=''

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Could not obtain a GCP access token from the metadata server (HTTP 000)"
  assert_contains "$output" "Underlying error: could not connect to metadata.google.internal"
}

@test "gcp-secret-manager setup: fails when the metadata server returns no token" {
  export GCP_SECRET_MANAGER_PROJECT_ID="my-project"
  export MOCK_CURL_BODY='{}'

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ The metadata server returned no access_token"
}
