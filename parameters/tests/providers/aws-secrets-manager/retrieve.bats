#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-secrets-manager/retrieve
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-secrets-manager/retrieve"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$AWS_LOG"
case "${MOCK_AWS_MODE:-success}" in
  success)
    echo '{"parameter_id":42,"value":"the-real-value","stored_at":"2026-01-01T00:00:00Z","external_id":"abc-123"}'
    ;;
  not_found)
    echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation: Secret not found." >&2
    exit 254
    ;;
  auth_error)
    echo "An error occurred (AccessDeniedException) when calling the GetSecretValue operation: User not authorized." >&2
    exit 254
    ;;
  *)
    echo "An error occurred (UnknownError) when calling." >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/aws"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AWS_REGION="us-east-1"
  export SM_NAME_PREFIX="nullplatform/"
  export EXTERNAL_ID="abc-123"

  export EXTERNAL_ID_PATH="$EXTERNAL_ID"
  export EXTERNAL_ID_VERSION=""
  export CONTEXT='{}'
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "aws-secrets-manager retrieve: success → extracts .value from envelope" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  value=$(echo "$output" | jq -r '.value')
  assert_equal "$value" "the-real-value"
}

@test "aws-secrets-manager retrieve: ResourceNotFoundException fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=not_found source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Secret"
  assert_contains "$output" "not found in AWS Secrets Manager"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "🔧 How to fix:"
}

@test "aws-secrets-manager retrieve: AccessDenied fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=auth_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve secret"
  assert_contains "$output" "lacks secretsmanager:GetSecretValue"
}

@test "aws-secrets-manager retrieve: unknown errors fail loud" {
  run bash -c "$DEPS; MOCK_AWS_MODE=other source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve secret"
}

@test "aws-secrets-manager retrieve: calls aws with correct args" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "secretsmanager get-secret-value"
  assert_contains "$captured" "--region us-east-1"
  assert_contains "$captured" "--secret-id nullplatform/abc-123"
}
