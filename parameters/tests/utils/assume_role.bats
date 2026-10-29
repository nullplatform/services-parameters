#!/usr/bin/env bats
# =============================================================================
# Unit tests for parameters/utils/assume_role — sourceable sts:AssumeRole step.
# Reads ASSUME_ROLE_ARN_RESOLVED (provider-agnostic) set by assume_role_step.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export PARAMETERS_DIR="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

  source "$PROJECT_ROOT/testing/assertions.sh"

  export SCRIPT="$PARAMETERS_DIR/utils/assume_role"
  export BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"

  # Isolate the sts-creds cache per test: cache lives under
  # $SERVICE_PATH/credentials/, so a fresh SERVICE_PATH per test = fresh cache.
  export SERVICE_PATH="$BATS_TEST_TMPDIR/service"
  mkdir -p "$SERVICE_PATH"
  export STS_CACHE_DIR="$SERVICE_PATH/credentials"
}

teardown() {
  unset ASSUME_ROLE_ARN_RESOLVED ASSUME_ROLE_SESSION_PREFIX \
    SERVICE_PATH STS_CACHE_DIR NP_STS_CACHE_BUFFER_SECS \
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# Helper: a far-future ISO 8601 timestamp (for the Credentials.Expiration field).
far_future_iso() {
  echo "2099-12-31T23:59:59Z"
}

# Helper: a far-future Unix epoch (well past any sane buffer window).
far_future_epoch() {
  echo "4102444799"  # 2099-12-31T23:59:59Z
}

# Helper: a past Unix epoch (for cache-stale fixtures).
past_epoch() {
  echo "1577836800"  # 2020-01-01T00:00:00Z
}

@test "assume_role: no-op when ASSUME_ROLE_ARN_RESOLVED is empty" {
  unset ASSUME_ROLE_ARN_RESOLVED

  run bash -c "
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo AKID=[\${AWS_ACCESS_KEY_ID:-}]
  "

  assert_equal "$status" "0"
  assert_contains "$output" "AKID=[]"
}

@test "assume_role: success exports temp credentials and logs ✅" {
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
[ "$1 $2" = "sts assume-role" ] || { echo "unexpected: $*" >&2; exit 1; }
cat << 'JSON'
{
  "Credentials": {
    "AccessKeyId": "AKIA-TEST",
    "SecretAccessKey": "sk-test",
    "SessionToken": "token-test",
    "Expiration": "2026-01-01T00:00:00Z"
  }
}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/test"
  export SCOPE_ID="scope-42"
  export ASSUME_ROLE_SESSION_PREFIX="np-secret-manager"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo AKID=\$AWS_ACCESS_KEY_ID
    echo SECRET=\$AWS_SECRET_ACCESS_KEY
    echo TOKEN=\$AWS_SESSION_TOKEN
  "

  assert_equal "$status" "0"
  assert_contains "$output" "AKID=AKIA-TEST"
  assert_contains "$output" "SECRET=sk-test"
  assert_contains "$output" "TOKEN=token-test"
  assert_contains "$output" "🔑 Assuming role: arn:aws:iam::1:role/test"
  assert_contains "$output" "✅ Role assumed successfully"
}

@test "assume_role: session name uses ASSUME_ROLE_SESSION_PREFIX + SCOPE_ID" {
  export AWS_ARGS_LOG="$BATS_TEST_TMPDIR/aws-args"
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo "$*" > "$AWS_ARGS_LOG"
cat << 'JSON'
{"Credentials":{"AccessKeyId":"a","SecretAccessKey":"s","SessionToken":"t","Expiration":"2026-01-01T00:00:00Z"}}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:role/x"
  export SCOPE_ID="scp-99"
  export ASSUME_ROLE_SESSION_PREFIX="np-parameter-store"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_equal "$status" "0"
  run cat "$AWS_ARGS_LOG"
  assert_contains "$output" "--role-session-name np-parameter-store-scp-99"
}

@test "assume_role: session name falls back to 'np-parameters' when prefix unset" {
  export AWS_ARGS_LOG="$BATS_TEST_TMPDIR/aws-args"
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo "$*" > "$AWS_ARGS_LOG"
cat << 'JSON'
{"Credentials":{"AccessKeyId":"a","SecretAccessKey":"s","SessionToken":"t","Expiration":"2026-01-01T00:00:00Z"}}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:role/x"
  export SCOPE_ID="scp-1"
  unset ASSUME_ROLE_SESSION_PREFIX

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_equal "$status" "0"
  run cat "$AWS_ARGS_LOG"
  assert_contains "$output" "--role-session-name np-parameters-scp-1"
}

@test "assume_role: returns 1 when aws sts assume-role fails" {
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo "AccessDenied: not allowed" >&2
exit 255
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/test"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  [ "$status" -ne 0 ]
  assert_contains "$output" "❌ sts:AssumeRole failed"
  assert_contains "$output" "AccessDenied: not allowed"
}

@test "assume_role: fails when aws returns incomplete credentials" {
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo '{"Credentials":{"AccessKeyId":"AKIA","SecretAccessKey":"","SessionToken":""}}'
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/test"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  [ "$status" -ne 0 ]
  assert_contains "$output" "incomplete credentials"
}

# ---- STS credentials cache -----------------------------------------------

@test "assume_role: cache hit — skips aws call entirely when cached creds are fresh" {
  # aws mock that fails if invoked — proves we never called it.
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  : > "$AWS_CALL_LOG"
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo "$*" >> "$AWS_CALL_LOG"
echo "should-not-be-called" >&2
exit 1
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/cached"

  # Pre-populate the cache with creds that expire far in the future.
  # NOTE: freshness is decided from `_cache_exp_epoch`, not from .Expiration.
  mkdir -p "$STS_CACHE_DIR"
  CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | sha256sum 2>/dev/null | cut -c1-16)
  [ -z "$CACHE_KEY" ] && CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | shasum -a 256 | cut -c1-16)
  cat > "$STS_CACHE_DIR/$CACHE_KEY.json" << EOF
{
  "Credentials": {
    "AccessKeyId": "AKIA-CACHED",
    "SecretAccessKey": "sk-cached",
    "SessionToken": "tok-cached",
    "Expiration": "$(far_future_iso)"
  },
  "_cache_exp_epoch": $(far_future_epoch)
}
EOF

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo AKID=\$AWS_ACCESS_KEY_ID
  "

  assert_equal "$status" "0"
  assert_contains "$output" "AKID=AKIA-CACHED"
  # aws mock would have written to the log if called
  run cat "$AWS_CALL_LOG"
  [ -z "$output" ]
}

@test "assume_role: cache stale — falls through to aws call and rewrites cache" {
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  : > "$AWS_CALL_LOG"
  cat > "$BIN_DIR/aws" << EOF
#!/bin/bash
echo "\$*" >> "\$AWS_CALL_LOG"
cat << JSON
{
  "Credentials": {
    "AccessKeyId": "AKIA-FRESH",
    "SecretAccessKey": "sk-fresh",
    "SessionToken": "tok-fresh",
    "Expiration": "$(far_future_iso)"
  }
}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/stale"

  mkdir -p "$STS_CACHE_DIR"
  CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | sha256sum 2>/dev/null | cut -c1-16)
  [ -z "$CACHE_KEY" ] && CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | shasum -a 256 | cut -c1-16)
  # Past expiration — should trigger refresh.
  cat > "$STS_CACHE_DIR/$CACHE_KEY.json" << EOF
{
  "Credentials": {
    "AccessKeyId": "AKIA-STALE",
    "SecretAccessKey": "sk-stale",
    "SessionToken": "tok-stale",
    "Expiration": "2020-01-01T00:00:00Z"
  },
  "_cache_exp_epoch": $(past_epoch)
}
EOF

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
    echo AKID=\$AWS_ACCESS_KEY_ID
  "

  assert_equal "$status" "0"
  assert_contains "$output" "AKID=AKIA-FRESH"
  run cat "$AWS_CALL_LOG"
  assert_contains "$output" "sts assume-role"
  # New creds were written to the cache, with a precomputed epoch.
  run cat "$STS_CACHE_DIR/$CACHE_KEY.json"
  assert_contains "$output" "AKIA-FRESH"
  assert_contains "$output" "_cache_exp_epoch"
}

@test "assume_role: cache write stores precomputed _cache_exp_epoch" {
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  : > "$AWS_CALL_LOG"
  cat > "$BIN_DIR/aws" << EOF
#!/bin/bash
echo "\$*" >> "\$AWS_CALL_LOG"
cat << JSON
{
  "Credentials": {
    "AccessKeyId": "AKIA-NEW",
    "SecretAccessKey": "sk",
    "SessionToken": "tok",
    "Expiration": "$(far_future_iso)"
  }
}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/write-test"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_equal "$status" "0"
  CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | sha256sum 2>/dev/null | cut -c1-16)
  [ -z "$CACHE_KEY" ] && CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | shasum -a 256 | cut -c1-16)

  # _cache_exp_epoch must be a positive integer well in the future.
  EPOCH=$(jq -r '._cache_exp_epoch' < "$STS_CACHE_DIR/$CACHE_KEY.json")
  NOW=$(date -u +%s)
  [ "$EPOCH" -gt "$NOW" ]
}

@test "assume_role: unparseable AWS Expiration falls back to now+3540s (cache still works)" {
  # AWS returns garbage in Expiration — date(1) will fail on it. The fallback
  # `now + 3540` must kick in so the cache remains usable.
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  : > "$AWS_CALL_LOG"
  cat > "$BIN_DIR/aws" << 'EOF'
#!/bin/bash
echo "$*" >> "$AWS_CALL_LOG"
cat << JSON
{
  "Credentials": {
    "AccessKeyId": "AKIA-NEW",
    "SecretAccessKey": "sk",
    "SessionToken": "tok",
    "Expiration": "this-is-not-a-date"
  }
}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  export ASSUME_ROLE_ARN_RESOLVED="arn:aws:iam::1:role/garbage-exp"

  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    source $SCRIPT
  "

  assert_equal "$status" "0"
  CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | sha256sum 2>/dev/null | cut -c1-16)
  [ -z "$CACHE_KEY" ] && CACHE_KEY=$(printf '%s' "$ASSUME_ROLE_ARN_RESOLVED" | shasum -a 256 | cut -c1-16)

  EPOCH=$(jq -r '._cache_exp_epoch' < "$STS_CACHE_DIR/$CACHE_KEY.json")
  NOW=$(date -u +%s)
  # Fallback should be ~now+3540 (1h - 60s buffer). Allow ±10s slack.
  DIFF=$(( EPOCH - NOW ))
  [ "$DIFF" -gt 3500 ] && [ "$DIFF" -lt 3600 ]
}

@test "assume_role: different ARNs use different cache files" {
  export AWS_CALL_LOG="$BATS_TEST_TMPDIR/aws-calls.log"
  : > "$AWS_CALL_LOG"
  cat > "$BIN_DIR/aws" << EOF
#!/bin/bash
echo "\$*" >> "\$AWS_CALL_LOG"
# Return creds reflecting which ARN was requested (parse --role-arn).
ARN=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--role-arn" ]; then ARN="\$2"; shift 2; else shift; fi
done
SUFFIX=\$(printf '%s' "\$ARN" | tr '/:' '__')
cat << JSON
{
  "Credentials": {
    "AccessKeyId": "AKIA-\$SUFFIX",
    "SecretAccessKey": "sk",
    "SessionToken": "tok",
    "Expiration": "$(far_future_iso)"
  }
}
JSON
EOF
  chmod +x "$BIN_DIR/aws"

  # Two ARNs in the same cache dir.
  run bash -c "
    export PATH=$BIN_DIR:\$PATH
    source $PARAMETERS_DIR/utils/log
    ASSUME_ROLE_ARN_RESOLVED='arn:aws:iam::1:role/A' source $SCRIPT
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ASSUMED_CREDS
    ASSUME_ROLE_ARN_RESOLVED='arn:aws:iam::1:role/B' source $SCRIPT
  "

  assert_equal "$status" "0"
  # Both ARNs hit aws (no cross-contamination).
  run cat "$AWS_CALL_LOG"
  assert_contains "$output" "arn:aws:iam::1:role/A"
  assert_contains "$output" "arn:aws:iam::1:role/B"
  # Both cache files exist.
  run ls "$STS_CACHE_DIR"
  [ "$(echo "$output" | wc -l | tr -d ' ')" -ge "2" ]
}
