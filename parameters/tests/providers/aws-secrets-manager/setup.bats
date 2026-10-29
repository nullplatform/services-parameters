#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-secrets-manager/setup
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export PARAMETERS_ROOT="$PARAMETERS_DIR"
  export SCRIPT="$PARAMETERS_DIR/providers/aws-secrets-manager/setup"
  export DEPS="source $PARAMETERS_DIR/utils/log; source $PARAMETERS_DIR/utils/get_config_value"

  # setup sources utils/assume_role_step, which runs `np provider list`. Mock np
  # (no IAM provider → empty ARN → no sts call) and supply a minimal payload.
  export BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  cat > "$BIN_DIR/np" << 'EOF'
#!/bin/bash
echo '{"results":[]}'
EOF
  chmod +x "$BIN_DIR/np"
  export PATH="$BIN_DIR:$PATH"
  export CONTEXT='{"entities":{"organization":"o","account":"a","namespace":"n","application":"ap"}}'
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"
  mkdir -p "$SERVICE_PATH"
}

teardown() {
  unset AWS_REGION SM_NAME_PREFIX SM_KMS_KEY_ID PROVIDER_CONFIG \
    CONTEXT SERVICE_PATH
}

@test "aws-secrets-manager setup: fails fast when AWS_REGION is missing" {
  unset AWS_REGION

  run bash -c "$DEPS; source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "AWS_REGION"
}

@test "aws-secrets-manager setup: name_prefix is hardcoded to 'nullplatform/'" {
  export AWS_REGION="us-east-1"
  # Even if PROVIDER_CONFIG tries to set name_prefix, it's ignored (hardcoded invariant)
  export PROVIDER_CONFIG='{"name_prefix":"custom/"}'

  run bash -c "$DEPS; source $SCRIPT && echo PREFIX=\$SM_NAME_PREFIX"

  assert_equal "$status" "0"
  assert_contains "$output" "PREFIX=nullplatform/"
}

@test "aws-secrets-manager setup: AWS_REGION is taken from env (runtime-injected)" {
  export AWS_REGION="eu-west-1"

  run bash -c "$DEPS; source $SCRIPT && echo REGION=\$AWS_REGION"

  assert_equal "$status" "0"
  assert_contains "$output" "REGION=eu-west-1"
}

@test "aws-secrets-manager setup: kms_key_id from PROVIDER_CONFIG" {
  export AWS_REGION="us-east-1"
  export PROVIDER_CONFIG='{"setup":{"kms_key_id":"alias/mykey"}}'

  run bash -c "$DEPS; source $SCRIPT && echo KMS=\$SM_KMS_KEY_ID"

  assert_equal "$status" "0"
  assert_contains "$output" "KMS=alias/mykey"
}

@test "aws-secrets-manager setup: kms_key_id is empty by default" {
  export AWS_REGION="us-east-1"

  run bash -c "$DEPS; source $SCRIPT && echo KMS=[\$SM_KMS_KEY_ID]"

  assert_equal "$status" "0"
  assert_contains "$output" "KMS=[]"
}
