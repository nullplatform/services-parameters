#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# =============================================================================
# Unit tests for parameters/utils/assume_role_step.
#
# The step is self-contained: it computes NRN + dimensions from CONTEXT, fetches
# the IAM provider via `np provider list`, resolves the ARN via assume_role_lib,
# then sources assume_role to call sts:AssumeRole. Both np and aws are mocked.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/utils/assume_role_step"
  export BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"

  # np mock — records args and echoes $MOCK_IAM_JSON (the IAM provider list).
  export NP_LOG="$BATS_TEST_TMPDIR/np-calls.log"
  : > "$NP_LOG"
  cat > "$BIN_DIR/np" << 'EOF'
#!/bin/bash
echo "$@" >> "$NP_LOG"
echo "${MOCK_IAM_JSON:-}"
EOF
  chmod +x "$BIN_DIR/np"

  # aws mock — records sts args, returns valid creds.
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo "$@" >> "$AWS_INVOKED_LOG"
cat << 'JSON'
{"Credentials":{"AccessKeyId":"AKIA","SecretAccessKey":"sk","SessionToken":"t","Expiration":"2026-01-01T00:00:00Z"}}
JSON
EOF
  chmod +x "$BIN_DIR/aws"
  export AWS_INVOKED_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  : > "$AWS_INVOKED_LOG"

  # Default payload: app-level, so NRN is non-empty and the np lookup fires.
  export CONTEXT='{"entities":{"organization":"o","account":"a","namespace":"n","application":"ap"}}'

  # assume_role uses $SERVICE_PATH/credentials/ for the sts cache.
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"
  mkdir -p "$SERVICE_PATH"
}

teardown() {
  unset CONTEXT SCOPE_ID MOCK_IAM_JSON NP_LOG SERVICE_PATH \
    ASSUME_ROLE_SELECTOR ASSUME_ROLE_OVERRIDE_ENV ASSUME_ROLE_DEFAULT_ENV \
    ASSUME_ROLE_SESSION_PREFIX ASSUME_ROLE_ARN_RESOLVED \
    SECRET_MANAGER_ASSUME_ROLE_ARN SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT \
    PARAMETER_STORE_ASSUME_ROLE_ARN PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT \
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# Sets the IAM provider list the np mock returns.
set_iam_provider() {
  local arns_json="$1"
  export MOCK_IAM_JSON=$(jq -n --argjson arns "$arns_json" \
    '{results:[{id:"prov-1", attributes:{iam_role_arns:{arns:$arns}}}]}')
}

SM_CALLER='ASSUME_ROLE_SELECTOR=secret_manager; ASSUME_ROLE_OVERRIDE_ENV=SECRET_MANAGER_ASSUME_ROLE_ARN; ASSUME_ROLE_DEFAULT_ENV=SECRET_MANAGER_ASSUME_ROLE_ARN_DEFAULT'
PS_CALLER='ASSUME_ROLE_SELECTOR=parameter_store; ASSUME_ROLE_OVERRIDE_ENV=PARAMETER_STORE_ASSUME_ROLE_ARN; ASSUME_ROLE_DEFAULT_ENV=PARAMETER_STORE_ASSUME_ROLE_ARN_DEFAULT'

# ---- Contract -------------------------------------------------------------

@test "step: fails fast when ASSUME_ROLE_SELECTOR is missing" {
  run -127 bash -c "
    export PATH=$BIN_DIR:\$PATH
    ASSUME_ROLE_OVERRIDE_ENV=X ASSUME_ROLE_DEFAULT_ENV=Y
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_contains "$output" "ASSUME_ROLE_SELECTOR must be set"
}

@test "step: fails fast when ASSUME_ROLE_OVERRIDE_ENV is missing" {
  run -127 bash -c "
    export PATH=$BIN_DIR:\$PATH
    ASSUME_ROLE_SELECTOR=secret_manager ASSUME_ROLE_DEFAULT_ENV=Y
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_contains "$output" "ASSUME_ROLE_OVERRIDE_ENV must be set"
}

@test "step: fails fast when ASSUME_ROLE_DEFAULT_ENV is missing" {
  run -127 bash -c "
    export PATH=$BIN_DIR:\$PATH
    ASSUME_ROLE_SELECTOR=secret_manager ASSUME_ROLE_OVERRIDE_ENV=X
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_contains "$output" "ASSUME_ROLE_DEFAULT_ENV must be set"
}

# ---- NRN + dimensions passed to the np lookup -----------------------------

@test "step: builds NRN from payload and passes it to np provider list" {
  set_iam_provider '[{"selector":"secret_manager","arn":"arn:x"}]'

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $SM_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  run cat "$NP_LOG"
  assert_contains "$output" "provider list --categories identity-access-control --nrn organization=o:account=a:namespace=n:application=ap"
}

@test "step: scope-level payload adds scope to NRN and passes value_dimensions" {
  export CONTEXT='{"value_entities":{"organization":"o","account":"a","namespace":"n","application":"ap","scope":"S"},"value_dimensions":{"country":"uruguay","environment":"development"}}'
  set_iam_provider '[{"selector":"secret_manager","arn":"arn:x"}]'

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $SM_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  run cat "$NP_LOG"
  assert_contains "$output" "--nrn organization=o:account=a:namespace=n:application=ap:scope=S"
  assert_contains "$output" "--dimensions country:uruguay,environment:development"
}

# ---- ARN resolution -------------------------------------------------------

@test "step: override env wins over the IAM provider" {
  export SECRET_MANAGER_ASSUME_ROLE_ARN="arn:from-env-sm"
  set_iam_provider '[{"selector":"secret_manager","arn":"arn:from-provider"}]'

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $SM_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo ARN=\$ASSUME_ROLE_ARN_RESOLVED
  "

  assert_equal "$status" "0"
  assert_contains "$output" "ARN=arn:from-env-sm"
  run cat "$AWS_INVOKED_LOG"
  assert_contains "$output" "--role-arn arn:from-env-sm"
}

@test "step: parameter_store caller — uses ITS OWN env var (not secret_manager's)" {
  export PARAMETER_STORE_ASSUME_ROLE_ARN="arn:ps-env"
  export SECRET_MANAGER_ASSUME_ROLE_ARN="arn:sm-MUST-NOT-BE-USED"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $PS_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo ARN=\$ASSUME_ROLE_ARN_RESOLVED
  "

  assert_contains "$output" "ARN=arn:ps-env"
}

@test "step: IAM provider — matching selector ARN is picked" {
  set_iam_provider '[
    {"selector":"containers","arn":"arn:containers"},
    {"selector":"secret_manager","arn":"arn:from-provider"}
  ]'

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $SM_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo ARN=\$ASSUME_ROLE_ARN_RESOLVED
  "

  assert_contains "$output" "ARN=arn:from-provider"
}

@test "step: parameter_store selector picks parameter_store ARN from the provider" {
  set_iam_provider '[
    {"selector":"secret_manager","arn":"arn:sm"},
    {"selector":"parameter_store","arn":"arn:ps"}
  ]'

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $PS_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo ARN=\$ASSUME_ROLE_ARN_RESOLVED
  "

  assert_contains "$output" "ARN=arn:ps"
}

@test "step: no matching IAM provider → empty ARN, no aws call (agent creds)" {
  set_iam_provider '[]'  # provider exists but has no arns

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $SM_CALLER
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo ARN=[\$ASSUME_ROLE_ARN_RESOLVED]
  "

  assert_equal "$status" "0"
  assert_contains "$output" "ARN=[]"
  run cat "$AWS_INVOKED_LOG"
  [ -z "$output" ]
}

@test "step: session prefix flows through to assume_role with SCOPE_ID" {
  export CONTEXT='{"value_entities":{"organization":"o","account":"a","namespace":"n","application":"ap","scope":"601620319"}}'
  set_iam_provider '[{"selector":"secret_manager","arn":"arn:x"}]'

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    $SM_CALLER
    ASSUME_ROLE_SESSION_PREFIX=np-secret-manager
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  run cat "$AWS_INVOKED_LOG"
  assert_contains "$output" "--role-session-name np-secret-manager-601620319"
}
