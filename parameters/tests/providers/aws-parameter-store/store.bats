#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/providers/aws-parameter-store/store
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_ROOT="$PARAMETERS_DIR"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/providers/aws-parameter-store/store"

  mkdir -p "$BATS_TEST_TMPDIR/bin"

  export AWS_LOG="$BATS_TEST_TMPDIR/aws.log"
  cat > "$BATS_TEST_TMPDIR/bin/aws" << EOF
#!/bin/bash
echo "ARGS: \$@" >> "$AWS_LOG"
if [ "\${MOCK_AWS_EXIT:-0}" -ne 0 ]; then exit \$MOCK_AWS_EXIT; fi
# put-parameter --output json returns { "Version": N, "Tier": "..." }
if [[ "\$*" == *"put-parameter"* ]]; then
  echo '{"Version":7,"Tier":"Standard"}'
fi
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/aws"

  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  export AWS_REGION="us-east-1"
  export PS_NAME_PREFIX="/nullplatform/"
  export PS_KMS_KEY_ID=""
  export PS_TIER="Standard"
  export PARAMETER_ID=42
  export PARAMETER_VALUE="my-value"
  # Slugs travel in the payload next to each entity id (build_external_id reads
  # them straight from CONTEXT — no np call, no cache files).
  export CONTEXT='{
    "parameter_id": 42,
    "value": "my-value",
    "entities": {
      "organization": "1255165411",
      "organization_slug": "acme",
      "account": "95118862",
      "account_slug": "prod",
      "namespace": "37094320",
      "namespace_slug": "billing",
      "application": "321402625",
      "application_slug": "api"
    },
    "dimensions": {}
  }'

  export DEPS="source $PARAMETERS_DIR/utils/log"
}

@test "aws-parameter-store store: external_id composed from entities + parameter_id + version" {
  export PARAMETER_KIND="parameter"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  external_id=$(echo "$output" | jq -r '.external_id')
  # Mock returns .Version=7
  expected="organization=acme-1255165411/account=prod-95118862/namespace=billing-37094320/application=api-321402625/42#7"
  assert_equal "$external_id" "$expected"
}

@test "aws-parameter-store store: kind=secret uses SecureString" {
  export PARAMETER_KIND="secret"

  run bash -c "$DEPS; source $SCRIPT"

  assert_equal "$status" "0"
  type=$(echo "$output" | jq -r '.metadata.type')
  assert_equal "$type" "SecureString"
  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "--type SecureString"
}

@test "aws-parameter-store store: kind=parameter uses String" {
  export PARAMETER_KIND="parameter"

  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "--type String"
  [[ "$captured" != *"SecureString"* ]]
}

@test "aws-parameter-store store: includes --key-id for SecureString when PS_KMS_KEY_ID set" {
  export PARAMETER_KIND="secret"
  export PS_KMS_KEY_ID="alias/parameters-secure"

  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "--key-id alias/parameters-secure"
}

@test "aws-parameter-store store: parameter_name has PS_NAME_PREFIX + composite (= sanitized to _)" {
  export PARAMETER_KIND="parameter"

  run bash -c "$DEPS; source $SCRIPT"

  param_name=$(echo "$output" | jq -r '.metadata.parameter_name')
  # SSM doesn't allow `=` in path components, so we replace it with `_`.
  assert_contains "$param_name" "/nullplatform/organization_acme-1255165411"
  # No `=` should remain anywhere in the parameter_name.
  case "$param_name" in *"="*) return 1 ;; esac
}

@test "aws-parameter-store store: passes tier flag" {
  export PARAMETER_KIND="parameter"
  export PS_TIER="Advanced"

  run bash -c "$DEPS; source $SCRIPT"

  captured=$(cat "$AWS_LOG")
  assert_contains "$captured" "--tier Advanced"
}

@test "aws-parameter-store store: fails with troubleshooting on aws error" {
  export PARAMETER_KIND="parameter"

  run bash -c "$DEPS; MOCK_AWS_EXIT=1 source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Failed to store parameter in AWS Parameter Store"
}
