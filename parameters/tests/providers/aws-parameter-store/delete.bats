#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-parameter-store/delete
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-parameter-store/delete"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$AWS_LOG"
case "${MOCK_AWS_MODE:-success}" in
  success) ;;
  not_found)
    echo "An error occurred (ParameterNotFound) when calling the DeleteParameter operation: Parameter not found." >&2
    exit 254
    ;;
  auth_error)
    echo "An error occurred (AccessDeniedException) when calling the DeleteParameter operation." >&2
    exit 254
    ;;
  *)
    echo "An error occurred (InternalServerError)." >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/aws"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AWS_REGION="us-east-1"
  export PS_NAME_PREFIX="/nullplatform/"
  export EXTERNAL_ID="abc-123"

  export EXTERNAL_ID_PATH="$EXTERNAL_ID"
  export EXTERNAL_ID_VERSION=""
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "aws-parameter-store delete: success → {success: true}" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "aws-parameter-store delete: ParameterNotFound is idempotent → success" {
  run bash -c "$DEPS; MOCK_AWS_MODE=not_found source $SCRIPT"

  assert_equal "$status" "0"
  success=$(echo "$output" | jq -r '.success')
  assert_equal "$success" "true"
}

@test "aws-parameter-store delete: AccessDenied fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=auth_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to delete parameter"
  assert_contains "$output" "lacks ssm:DeleteParameter"
}

@test "aws-parameter-store delete: unknown errors fail loud" {
  run bash -c "$DEPS; MOCK_AWS_MODE=other source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to delete parameter"
}

@test "aws-parameter-store delete: calls aws ssm delete-parameter with name" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "ssm delete-parameter"
  assert_contains "$captured" "--region us-east-1"
  assert_contains "$captured" "--name /nullplatform/abc-123"
}
