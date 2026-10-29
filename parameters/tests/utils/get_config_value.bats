#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/get_config_value
# Priority: provider config > env var > default
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"
  source "$PARAMETERS_DIR/utils/get_config_value"
}

teardown() {
  unset PROVIDER_CONFIG
  unset TEST_ENV_VAR OTHER_ENV
}

@test "get_config_value: provider wins over env var" {
  export PROVIDER_CONFIG='{"address":"from-provider"}'
  export TEST_ENV_VAR="from-env"

  result=$(get_config_value --env TEST_ENV_VAR --provider '.address' --default "default")
  assert_equal "$result" "from-provider"
}

@test "get_config_value: env wins when provider has no match" {
  export PROVIDER_CONFIG='{"other":"value"}'
  export TEST_ENV_VAR="from-env"

  result=$(get_config_value --env TEST_ENV_VAR --provider '.address' --default "default")
  assert_equal "$result" "from-env"
}

@test "get_config_value: default is last resort" {
  result=$(get_config_value --env UNSET_VAR --provider '.address' --default "fallback")
  assert_equal "$result" "fallback"
}

@test "get_config_value: returns empty when no match and no default" {
  result=$(get_config_value --env UNSET_VAR --provider '.address')
  assert_equal "$result" ""
}

@test "get_config_value: works without PROVIDER_CONFIG set" {
  unset PROVIDER_CONFIG
  export TEST_ENV_VAR="env-only"

  result=$(get_config_value --env TEST_ENV_VAR --provider '.address')
  assert_equal "$result" "env-only"
}

@test "get_config_value: multiple provider paths, first match wins" {
  export PROVIDER_CONFIG='{"a":null,"b":"second"}'

  result=$(get_config_value --provider '.a' --provider '.b' --default "fallback")
  assert_equal "$result" "second"
}

@test "get_config_value: multiple env vars, first set wins" {
  export TEST_ENV_VAR=""
  export OTHER_ENV="other-set"

  result=$(get_config_value --env TEST_ENV_VAR --env OTHER_ENV --default "fallback")
  assert_equal "$result" "other-set"
}

@test "get_config_value: null value in PROVIDER_CONFIG is treated as missing" {
  export PROVIDER_CONFIG='{"address":null}'

  result=$(get_config_value --provider '.address' --default "fallback")
  assert_equal "$result" "fallback"
}

@test "get_config_value: invalid JSON in PROVIDER_CONFIG falls through to env" {
  export PROVIDER_CONFIG='not-valid-json'
  export TEST_ENV_VAR="env-val"

  result=$(get_config_value --env TEST_ENV_VAR --provider '.address')
  assert_equal "$result" "env-val"
}

@test "get_config_value: nested provider path resolves correctly" {
  export PROVIDER_CONFIG='{"connection":{"address":"https://vault.example.com"}}'

  result=$(get_config_value --provider '.connection.address')
  assert_equal "$result" "https://vault.example.com"
}
