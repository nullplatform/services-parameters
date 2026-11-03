#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-parameter-store/retrieve
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-parameter-store/retrieve"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$AWS_LOG"
case "${MOCK_AWS_MODE:-success}" in
  success)
    echo "the-real-value"
    ;;
  not_found)
    echo "An error occurred (ParameterNotFound) when calling the GetParameter operation." >&2
    exit 254
    ;;
  auth_error)
    echo "An error occurred (AccessDeniedException) when calling the GetParameter operation." >&2
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
  export CONTEXT='{}'
  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "aws-parameter-store retrieve: success → returns value" {
  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  value=$(echo "$output" | jq -r '.value')
  assert_equal "$value" "the-real-value"
}

@test "aws-parameter-store retrieve: ParameterNotFound fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=not_found source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "not found in AWS Parameter Store"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "🔧 How to fix:"
}

@test "aws-parameter-store retrieve: AccessDenied fails with troubleshooting" {
  run bash -c "$DEPS; MOCK_AWS_MODE=auth_error source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve parameter"
  assert_contains "$output" "lacks ssm:GetParameter"
}

@test "aws-parameter-store retrieve: unknown errors fail loud" {
  run bash -c "$DEPS; MOCK_AWS_MODE=other source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to retrieve parameter"
}

@test "aws-parameter-store retrieve: calls aws with --with-decryption" {
  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "ssm get-parameter"
  assert_contains "$captured" "--region us-east-1"
  assert_contains "$captured" "--name /nullplatform/abc-123"
  assert_contains "$captured" "--with-decryption"
}
