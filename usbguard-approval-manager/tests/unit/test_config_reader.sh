#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/config-reader.sh
source "$PROJECT_ROOT/scripts/lib/config-reader.sh"

if env CONFIG_READER_LOADED=1 bash -c \
  'source "$1"; [[ "$CONFIG_READER_VERSION" == "1.2.0" ]]' _ \
  "$PROJECT_ROOT/scripts/lib/config-reader.sh"; then
  printf 'PASS: exported initialization marker cannot bypass setup\n'
else
  printf 'FAIL: exported initialization marker bypassed setup\n' >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

pass_count=0
fail_count=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  fail_count=$((fail_count + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
  pass_count=$((pass_count + 1))
}

assert_config_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(get_config "$key")" || {
    fail "get_config $key"
    return
  }
  if [[ "$actual" == "$expected" ]]; then
    pass "get_config $key=$expected"
  else
    fail "get_config $key expected '$expected', got '$actual'"
  fi
}

assert_rejected() {
  local name="$1"
  local contents="$2"
  printf '%s' "$contents" > "$TEST_DIR/config"
  if load_config "$TEST_DIR/config" >/dev/null 2>&1; then
    fail "$name was accepted"
  else
    pass "$name was rejected"
  fi
}

if load_config "$PROJECT_ROOT/conf/approval-manager.conf.example"; then
  pass "approved configuration example"
  assert_config_value TEMP_TTL_SECONDS 3600
  assert_config_value MIN_REASONABLE_EPOCH 1577836800
  assert_config_value MAX_CLOCK_JUMP_SECONDS 3600
  assert_config_value BACKUP_KEEP 5
  assert_config_value IPC_TIMEOUT_SECONDS 5
  assert_config_value LOG_LEVEL INFO
else
  fail "approved configuration example"
fi

cat > "$TEST_DIR/config" <<'EOF'
# Valid SRS v4.5 configuration
TEMP_TTL_SECONDS=00080
MAX_CLOCK_JUMP_SECONDS=86400
BACKUP_KEEP=100
IPC_TIMEOUT_SECONDS=60
LOG_LEVEL=DEBUG
EOF
if load_config "$TEST_DIR/config"; then
  pass "valid configuration"
  assert_config_value TEMP_TTL_SECONDS 80
  assert_config_value MAX_CLOCK_JUMP_SECONDS 86400
  assert_config_value MIN_REASONABLE_EPOCH 1577836800
  assert_config_value BACKUP_KEEP 100
  assert_config_value IPC_TIMEOUT_SECONDS 60
  assert_config_value LOG_LEVEL DEBUG
else
  fail "valid configuration"
fi

for level in DEBUG INFO WARNING ERROR; do
  printf 'LOG_LEVEL=%s\n' "$level" > "$TEST_DIR/config"
  if load_config "$TEST_DIR/config" &&
    [[ "$(get_config LOG_LEVEL)" == "$level" ]]; then
    pass "accepted LOG_LEVEL=$level"
  else
    fail "rejected valid LOG_LEVEL=$level"
  fi
done

assert_rejected "duplicate key" \
  $'TEMP_TTL_SECONDS=3600\nTEMP_TTL_SECONDS=7200\n'
assert_rejected "unknown key" $'UNLISTED_KEY=value\n'
assert_rejected "invalid log level" $'LOG_LEVEL=TRACE\n'
assert_rejected "out-of-range value" $'TEMP_TTL_SECONDS=2592001\n'
assert_rejected "backup retention below minimum" $'BACKUP_KEEP=0\n'
assert_rejected "backup retention above maximum" $'BACKUP_KEEP=101\n'
assert_rejected "IPC timeout below minimum" $'IPC_TIMEOUT_SECONDS=0\n'
assert_rejected "IPC timeout above maximum" $'IPC_TIMEOUT_SECONDS=61\n'
assert_rejected "oversized out-of-range value" \
  $'TEMP_TTL_SECONDS=999999999999999999999999999999999999999\n'
assert_rejected "command substitution" \
  "TEMP_TTL_SECONDS=\$(touch $TEST_DIR/injected)"
if [[ -e "$TEST_DIR/injected" ]]; then
  fail "command substitution was executed"
else
  pass "command substitution was not executed"
fi
assert_rejected "parameter expansion" 'TEMP_TTL_SECONDS=${HOME}'
assert_rejected "backtick substitution" 'TEMP_TTL_SECONDS=`id`'
assert_rejected "malformed assignment" $'TEMP_TTL_SECONDS\n'
assert_rejected "control character" $'TEMP_TTL_SECONDS=3600\t\n'

printf '%s\n' 'TEMP_TTL_SECONDS=3600' > "$TEST_DIR/config"
load_config "$TEST_DIR/config"
printf '%s\n' 'TEMP_TTL_SECONDS=1' > "$TEST_DIR/config"
if load_config "$TEST_DIR/config" >/dev/null 2>&1 ||
  get_config TEMP_TTL_SECONDS >/dev/null 2>&1; then
  fail "failed load left stale configuration values"
else
  pass "failed load clears previously loaded configuration"
fi

printf 'TEMP_TTL_SECONDS=3600\0\n' > "$TEST_DIR/config"
if load_config "$TEST_DIR/config" >/dev/null 2>&1; then
  fail "NUL byte was accepted"
else
  pass "NUL byte was rejected"
fi

if [[ "$fail_count" -ne 0 ]]; then
  printf '%s test(s) failed; %s passed\n' "$fail_count" "$pass_count" >&2
  exit 1
fi
printf 'All %s config-reader checks passed\n' "$pass_count"
