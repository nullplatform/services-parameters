#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/assume_role_lib — pure helpers.
# Provider-agnostic: env var names are parameters, NOT hardcoded.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"
  source "$PARAMETERS_DIR/utils/assume_role_lib"
}

teardown() {
  unset \
    SECRET_MANAGER_ASSUME_ROLE_ARN SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT \
    PARAMETER_STORE_ASSUME_ROLE_ARN PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT
}

# ---- arn_for_selector -------------------------------------------------------

@test "arn_for_selector: returns matching ARN when selector exists" {
  local json='{"iam_role_arns":{"arns":[
    {"selector":"containers","arn":"arn:aws:iam::1:role/containers"},
    {"selector":"secret_manager","arn":"arn:aws:iam::1:role/secret-mgr"}
  ]}}'

  run arn_for_selector "$json" "secret_manager"

  assert_equal "$status" "0"
  assert_equal "$output" "arn:aws:iam::1:role/secret-mgr"
}

@test "arn_for_selector: works with a different selector (parameter_store)" {
  local json='{"iam_role_arns":{"arns":[
    {"selector":"secret_manager","arn":"arn:sm"},
    {"selector":"parameter_store","arn":"arn:ps"}
  ]}}'

  run arn_for_selector "$json" "parameter_store"

  assert_equal "$output" "arn:ps"
}

@test "arn_for_selector: returns first match when selector appears twice" {
  local json='{"iam_role_arns":{"arns":[
    {"selector":"secret_manager","arn":"arn:1"},
    {"selector":"secret_manager","arn":"arn:2"}
  ]}}'

  run arn_for_selector "$json" "secret_manager"

  assert_equal "$output" "arn:1"
}

@test "arn_for_selector: returns empty when selector not found" {
  local json='{"iam_role_arns":{"arns":[{"selector":"containers","arn":"a"}]}}'

  run arn_for_selector "$json" "secret_manager"

  assert_equal "$status" "0"
  assert_equal "$output" ""
}

@test "arn_for_selector: empty/malformed input returns empty (no crash)" {
  run arn_for_selector "" "secret_manager"
  assert_equal "$output" ""

  run arn_for_selector "{}" "secret_manager"
  assert_equal "$output" ""

  run arn_for_selector "not-json-at-all" "secret_manager"
  assert_equal "$output" ""
}

# ---- resolve_assume_role_arn -----------------------------------------------
# Now takes 4 args: iam_json, selector, override_env_name, default_env_name.

@test "resolve_assume_role_arn: override env (by name) wins over provider" {
  export SECRET_MANAGER_ASSUME_ROLE_ARN="arn:from-env"
  local json='{"iam_role_arns":{"arns":[{"selector":"secret_manager","arn":"arn:provider"}]}}'

  run resolve_assume_role_arn "$json" "secret_manager" \
    "SECRET_MANAGER_ASSUME_ROLE_ARN" "SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT"

  assert_equal "$output" "arn:from-env"
}

@test "resolve_assume_role_arn: parameter_store uses ITS OWN env var (not secret_manager's)" {
  export PARAMETER_STORE_ASSUME_ROLE_ARN="arn:ps-override"
  # secret_manager's env is also set, but caller asked for parameter_store's
  export SECRET_MANAGER_ASSUME_ROLE_ARN="arn:sm-IGNORED"

  run resolve_assume_role_arn "{}" "parameter_store" \
    "PARAMETER_STORE_ASSUME_ROLE_ARN" "PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT"

  assert_equal "$output" "arn:ps-override"
}

@test "resolve_assume_role_arn: empty override falls through to provider selector" {
  export SECRET_MANAGER_ASSUME_ROLE_ARN=""
  local json='{"iam_role_arns":{"arns":[{"selector":"secret_manager","arn":"arn:provider"}]}}'

  run resolve_assume_role_arn "$json" "secret_manager" \
    "SECRET_MANAGER_ASSUME_ROLE_ARN" "SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT"

  assert_equal "$output" "arn:provider"
}

@test "resolve_assume_role_arn: provider miss falls through to DEFAULT env" {
  unset SECRET_MANAGER_ASSUME_ROLE_ARN
  export SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT="arn:default"
  local json='{"iam_role_arns":{"arns":[{"selector":"containers","arn":"a"}]}}'

  run resolve_assume_role_arn "$json" "secret_manager" \
    "SECRET_MANAGER_ASSUME_ROLE_ARN" "SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT"

  assert_equal "$output" "arn:default"
}

@test "resolve_assume_role_arn: parameter_store DEFAULT env is independent of secret_manager's" {
  export SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT="arn:sm-IGNORED"
  export PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT="arn:ps-default"

  run resolve_assume_role_arn "{}" "parameter_store" \
    "PARAMETER_STORE_ASSUME_ROLE_ARN" "PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT"

  assert_equal "$output" "arn:ps-default"
}

@test "resolve_assume_role_arn: no source set returns empty (use agent creds)" {
  run resolve_assume_role_arn "{}" "secret_manager" \
    "SECRET_MANAGER_ASSUME_ROLE_ARN" "SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT"

  assert_equal "$output" ""
}

@test "resolve_assume_role_arn: empty override-env-name arg is treated as 'no override'" {
  # Caller passes "" for the override env name → step 1 of precedence is skipped
  local json='{"iam_role_arns":{"arns":[{"selector":"secret_manager","arn":"arn:p"}]}}'

  run resolve_assume_role_arn "$json" "secret_manager" "" ""

  assert_equal "$output" "arn:p"
}
