#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-secrets-manager/delete
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-secrets-manager/delete"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$AWS_LOG"
case "${MOCK_AWS_MODE:-success}" in
  success) ;;
  not_found)
    echo "An error occurred (ResourceNotFoundException) when calling the DeleteSecret operation: Secret not found." >&2
    exit 254
    ;;
  auth_error)
    echo "An error occurred (AccessDeniedException) when calling the DeleteSecret operation: User not authorized." >&2
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
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "aws-secrets-manager delete: success → {success: true}" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "aws-secrets-manager delete: ResourceNotFoundException is idempotent → success" {
  run bash -c "$DEPS; MOCK_AWS_MODE=not_found source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "aws-secrets-manager delete: AccessDenied fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=auth_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to delete secret"
  assert_contains "$output" "lacks secretsmanager:DeleteSecret"
  assert_contains "$output" "AccessDeniedException"
}

@test "aws-secrets-manager delete: unknown errors fail with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=other source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to delete secret"
  assert_contains "$output" "🔧 How to fix:"
}

@test "aws-secrets-manager delete: calls aws with force-delete flag" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "secretsmanager delete-secret"
  assert_contains "$captured" "--region us-east-1"
  assert_contains "$captured" "--secret-id nullplatform/abc-123"
  assert_contains "$captured" "--force-delete-without-recovery"
}
