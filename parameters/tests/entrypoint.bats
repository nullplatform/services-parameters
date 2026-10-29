#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/entrypoint — the action router.
# Action comes from $CONTEXT.action (i.e. NP_ACTION_CONTEXT.notification.action),
# NOT from a separate env var.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/entrypoint"
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"

  # Stage a fake parameters/workflows/ with the expected action workflows.
  mkdir -p "$SERVICE_PATH/workflows"
  for action in store retrieve delete notify; do
    : > "$SERVICE_PATH/workflows/$action.yaml"
  done

  # np mock — echo args so we can assert what entrypoint invoked.
  cat > "$BATS_TEST_TMPDIR/np" << 'EOF'
#!/bin/bash
echo "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/np"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
}

teardown() {
  unset NP_ACTION_CONTEXT OVERRIDES_PATH SERVICE_PATH
}

@test "entrypoint: fails when NP_ACTION_CONTEXT is empty" {
  unset NP_ACTION_CONTEXT

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ NP_ACTION_CONTEXT is not set"
}

@test "entrypoint: fails when CONTEXT.action has no action part" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter","secret":true}}'

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ CONTEXT.action is missing the action part"
}

@test "entrypoint: fails when CONTEXT.action is absent" {
  export NP_ACTION_CONTEXT='{"notification":{"secret":true}}'

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ CONTEXT.action is missing the action part"
}

@test "entrypoint: store action routes to store.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "store.yaml"
}

@test "entrypoint: retrieve action routes to retrieve.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:retrieve","secret":true,"external_id":"abc"}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "retrieve.yaml"
}

@test "entrypoint: delete action routes to delete.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:delete","secret":false,"external_id":"abc"}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "delete.yaml"
}

@test "entrypoint: notify action routes to notify.yaml" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:notify","secret":true,"external_id":"abc"}}'

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "notify.yaml"
}

@test "entrypoint: payload's .secret value does not affect routing" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'
  run bash "$SCRIPT"
  assert_equal "$status" "0"
  output_true="$output"

  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":false}}'
  run bash "$SCRIPT"
  assert_equal "$status" "0"

  assert_equal "$output" "$output_true"
}

@test "entrypoint: fails when no matching workflow exists" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:nonexistent","secret":true}}'

  run bash "$SCRIPT"

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ No workflow found at"
}

@test "entrypoint: strips surrounding single quotes from NP_ACTION_CONTEXT" {
  export NP_ACTION_CONTEXT="'{\"notification\":{\"action\":\"parameter:store\",\"secret\":true}}'"

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "store.yaml"
}

@test "entrypoint: OVERRIDES_PATH appends --overrides for matching path" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'

  mkdir -p "$BATS_TEST_TMPDIR/override1/parameters/workflows"
  : > "$BATS_TEST_TMPDIR/override1/parameters/workflows/store.yaml"
  export OVERRIDES_PATH="$BATS_TEST_TMPDIR/override1"

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  assert_contains "$output" "--overrides $BATS_TEST_TMPDIR/override1/parameters/workflows/store.yaml"
}

@test "entrypoint: OVERRIDES_PATH skips paths without the workflow file" {
  export NP_ACTION_CONTEXT='{"notification":{"action":"parameter:store","secret":true}}'

  mkdir -p "$BATS_TEST_TMPDIR/empty_override"
  export OVERRIDES_PATH="$BATS_TEST_TMPDIR/empty_override"

  run bash "$SCRIPT"

  assert_equal "$status" "0"
  [[ "$output" != *"--overrides $BATS_TEST_TMPDIR/empty_override"* ]]
}
