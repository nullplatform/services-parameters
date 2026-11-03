#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/log
# All log levels route to stderr (stdout is reserved for JSON contract).
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"
}

teardown() {
  unset -f log 2>/dev/null || true
  unset LOG_LEVEL
}

@test "log: info routes to stderr" {
  source "$PARAMETERS_DIR/utils/log"
  err=$(log info "hello" 2>&1 >/dev/null)
  assert_equal "$err" "hello"

  # Verify stdout is empty
  out=$(log info "hello" 2>/dev/null)
  assert_equal "$out" ""
}

@test "log: warn routes to stderr" {
  source "$PARAMETERS_DIR/utils/log"
  err=$(log warn "uh oh" 2>&1 >/dev/null)
  assert_equal "$err" "uh oh"
}

@test "log: error routes to stderr" {
  source "$PARAMETERS_DIR/utils/log"
  err=$(log error "boom" 2>&1 >/dev/null)
  assert_equal "$err" "boom"
}

@test "log: debug is silent by default" {
  source "$PARAMETERS_DIR/utils/log"
  err=$(log debug "shhh" 2>&1 >/dev/null)
  assert_equal "$err" ""
}

@test "log: debug emits to stderr when LOG_LEVEL=debug" {
  export LOG_LEVEL=debug
  source "$PARAMETERS_DIR/utils/log"
  err=$(log debug "spoke up" 2>&1 >/dev/null)
  assert_equal "$err" "spoke up"
}

@test "log: stdout is always empty (JSON contract)" {
  source "$PARAMETERS_DIR/utils/log"
  out=$(
    log info "info msg"
    log warn "warn msg"
    log error "error msg"
    log debug "debug msg"
    LOG_LEVEL=debug log debug "debug enabled msg"
  )
  assert_equal "$out" ""
}
