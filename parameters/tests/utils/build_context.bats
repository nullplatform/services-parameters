#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/build_context — provider resolution via spec_id
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/utils/build_context"
  export TEST_PROVIDER_DIR="$PARAMETERS_DIR/providers/test_provider"

  # Mock the np CLI
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export NP_LOG="$BATS_TEST_TMPDIR/np.log"
  cat > "$BATS_TEST_TMPDIR/bin/np" << 'EOF'
#!/bin/bash
echo "ARGS: $@" >> "$NP_LOG"
if [ "$1" = "provider" ] && [ "$2" = "specification" ] && [ "$3" = "read" ]; then
  case "${MOCK_NP_SPEC_MODE:-success}" in
    success)
      slug="${MOCK_NP_SPEC_SLUG:-test_provider}"
      echo "{\"slug\":\"$slug\",\"id\":\"some-uuid\"}"
      ;;
    not_found)
      echo "Error: Specification not found" >&2
      exit 1
      ;;
    no_slug)
      echo "{\"id\":\"some-uuid\"}"
      ;;
  esac
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/np"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # Default CONTEXT: platform ships specification_slug directly in the payload.
  export CONTEXT='{
    "parameter_id": 42,
    "value": "my-val",
    "parameter_name": "DB_PASS",
    "encoding": "plain",
    "secret": true,
    "entities": {
      "organization": "1255165411",
      "account": "95118862",
      "namespace": "37094320",
      "application": "321402625"
    },
    "provider": {
      "specification_id": "ec885dd0-7c38-45b8-af2c-0b9e1deb7d3d",
      "specification_slug": "test_provider",
      "attributes": {
        "region": "us-east-1",
        "name_prefix": "parameters/"
      }
    }
  }'
}

teardown() {
  rm -rf "$TEST_PROVIDER_DIR"
  unset MOCK_NP_SPEC_MODE MOCK_NP_SPEC_SLUG
  unset PARAMETER_KIND ACTIVE_PROVIDER PROVIDER_DIR PARAMETERS_ROOT
  unset EXTERNAL_ID PARAMETER_ID PARAMETER_VALUE PARAMETER_NAME PARAMETER_ENCODING
  unset PROVIDER_CONFIG
}

@test "build_context: extracts notification fields and exports them" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo PID=\$PARAMETER_ID VAL=\$PARAMETER_VALUE NAME=\$PARAMETER_NAME ENC=\$PARAMETER_ENCODING"

  assert_equal "$status" "0"
  assert_contains "$output" "PID=42"
  assert_contains "$output" "VAL=my-val"
  assert_contains "$output" "NAME=DB_PASS"
  assert_contains "$output" "ENC=plain"
}

@test "build_context: derives PARAMETER_KIND=secret when .secret is true" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo KIND=\$PARAMETER_KIND"

  assert_equal "$status" "0"
  assert_contains "$output" "KIND=secret"
}

@test "build_context: derives PARAMETER_KIND=parameter when .secret is false" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.secret = false')
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo KIND=\$PARAMETER_KIND"

  assert_equal "$status" "0"
  assert_contains "$output" "KIND=parameter"
}

@test "build_context: resolves ACTIVE_PROVIDER from spec_id via np CLI" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo PROV=\$ACTIVE_PROVIDER"

  assert_equal "$status" "0"
  assert_contains "$output" "PROV=test_provider"
}

@test "build_context: does NOT call np provider specification read (slug comes from payload)" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT"

  captured=$(cat "$NP_LOG" 2>/dev/null || echo "")
  case "$captured" in *"provider specification read"*) return 1 ;; esac
}

@test "build_context: fails when specification_slug is missing" {
  export CONTEXT=$(echo "$CONTEXT" | jq 'del(.provider.specification_slug)')

  run bash -c "source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Missing .provider.specification_slug"
  assert_contains "$output" "💡 Possible causes:"
}

@test "build_context: fails when provider directory doesn't exist" {
  export CONTEXT=$(echo "$CONTEXT" | jq '.provider.specification_slug = "nonexistent_provider"')

  run bash -c "source $SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ Provider implementation not found for slug 'nonexistent_provider'"
}

@test "build_context: PROVIDER_CONFIG comes from .provider.attributes" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo CONFIG=\$PROVIDER_CONFIG"

  assert_equal "$status" "0"
  assert_contains "$output" '"region":"us-east-1"'
  assert_contains "$output" '"name_prefix":"parameters/"'
}

@test "build_context: PROVIDER_CONFIG defaults to {} when attributes is missing" {
  export CONTEXT=$(echo "$CONTEXT" | jq 'del(.provider.attributes)')
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo CONFIG=\$PROVIDER_CONFIG"

  assert_equal "$status" "0"
  assert_contains "$output" "CONFIG={}"
}

@test "build_context: sources provider setup when present" {
  mkdir -p "$TEST_PROVIDER_DIR"
  echo 'export SETUP_RAN="yes"' > "$TEST_PROVIDER_DIR/setup"

  run bash -c "source $SCRIPT && echo SETUP=\$SETUP_RAN"

  assert_equal "$status" "0"
  assert_contains "$output" "SETUP=yes"
}

@test "build_context: setup can read PROVIDER_CONFIG via get_config_value" {
  mkdir -p "$TEST_PROVIDER_DIR"
  cat > "$TEST_PROVIDER_DIR/setup" << 'EOF'
REGION=$(get_config_value --provider '.region')
export RESOLVED_REGION="$REGION"
EOF

  run bash -c "source $SCRIPT && echo REGION=\$RESOLVED_REGION"

  assert_equal "$status" "0"
  assert_contains "$output" "REGION=us-east-1"
}

@test "build_context: succeeds when provider has no setup" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo PROV=\$ACTIVE_PROVIDER"

  assert_equal "$status" "0"
  assert_contains "$output" "PROV=test_provider"
}

@test "build_context: exports PROVIDER_DIR and PARAMETERS_ROOT" {
  mkdir -p "$TEST_PROVIDER_DIR"

  run bash -c "source $SCRIPT && echo PD=\$PROVIDER_DIR ROOT=\$PARAMETERS_ROOT"

  assert_equal "$status" "0"
  assert_contains "$output" "PD=$PARAMETERS_DIR/providers/test_provider"
  assert_contains "$output" "ROOT=$PARAMETERS_DIR"
}
