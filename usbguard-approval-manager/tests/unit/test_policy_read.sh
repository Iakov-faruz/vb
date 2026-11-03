#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/config-reader.sh"
source "$PROJECT_ROOT/scripts/lib/usbguard-policy.sh"

TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf -- "$TEST_DIR"' EXIT

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_USB_COMMANDS"
case "$*" in
  --version)
    printf 'USBGuard 1.1.4\n'
    ;;
  'list-devices --blocked')
    case "${FAKE_DEVICE_MODE:-normal}" in
      empty) exit 0 ;;
      malformed) printf 'not a USBGuard record\n' ;;
      failure)
        printf 'query failed\n' >&2
        exit 3
        ;;
      slow) sleep 5 ;;
      *)
        printf '3: block id 1d6b:0002 name "Lab device"\n'
        printf '4: block id 1234:5678 name "Second lab device"\n'
        ;;
    esac
    ;;
  list-devices)
    if [[ "${FAKE_IPC_MODE:-connected}" == "unavailable" ]]; then
      printf 'IPC unavailable\n' >&2
      exit 4
    fi
    printf '1: allow id 1d6b:0002 name "Lab device"\n'
    ;;
  list-rules)
    if [[ "${FAKE_RULE_MODE:-normal}" == "empty" ]]; then
      exit 0
    fi
    printf '1: allow id 1d6b:0002\n'
    printf '2: block id 9999:0001\n'
    ;;
  *)
    printf 'unexpected command\n' >&2
    exit 64
    ;;
esac
MOCK

cat > "$FAKE_BIN/pgrep" <<'MOCK'
#!/usr/bin/env bash
if [[ "${FAKE_DAEMON_MODE:-running}" == "running" ]]; then
  printf '42\n'
  exit 0
fi
exit 1
MOCK
chmod 700 "$FAKE_BIN/usbguard" "$FAKE_BIN/pgrep"
PATH="$FAKE_BIN:$PATH"
export PATH
FAKE_USB_COMMANDS="$TEST_DIR/usbguard-commands.log"
export FAKE_USB_COMMANDS
IPC_TIMEOUT_SECONDS=1

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

assert_equal "$(usbguard_policy_timeout)" "1" \
  "timeout falls back to the environment value when configuration is not loaded"
unset IPC_TIMEOUT_SECONDS
assert_equal "$(usbguard_policy_timeout)" "5" \
  "timeout falls back to the default when configuration is not loaded"
IPC_TIMEOUT_SECONDS=1

printf 'IPC_TIMEOUT_SECONDS=2\n' > "$TEST_DIR/timeout-config"
load_config "$TEST_DIR/timeout-config" ||
  fail "timeout configuration could not be loaded"
assert_equal "$(usbguard_policy_timeout)" "2" \
  "loaded configuration takes precedence over the environment fallback"
CONFIG_VALUES=()
pass "USBGuard timeout handles both empty and loaded configuration"

get_usbguard_version >/dev/null || fail "version query failed"
assert_equal "$USBAM_POLICY_VERSION" "USBGuard 1.1.4" "version output"
assert_equal "$USBAM_POLICY_VERSION" "USBGuard 1.1.4" "stored version"
pass "version query returns captured version"

command_count="$(wc -l < "$FAKE_USB_COMMANDS")"
forbidden_commands=(
  'append-rule allow id 1d6b:0002' \
  'block-device 3'
)
for forbidden_command in "${forbidden_commands[@]}"; do
  read -r -a command_args <<< "$forbidden_command"
  if usbguard_policy_run_readonly "${command_args[@]}" 2>/dev/null; then
    fail "read-only command runner accepted '$forbidden_command'"
  fi
  assert_equal "$USBAM_POLICY_ERROR_CODE" "invalid_command" \
    "read-only command allowlist"
done
assert_equal "$(wc -l < "$FAKE_USB_COMMANDS")" "$command_count" \
  "forbidden commands never reach the USBGuard executable"
pass "read-only runner rejects all non-query USBGuard operations"

list_blocked_devices || fail "blocked-device query failed"
assert_equal "${#USBAM_BLOCKED_DEVICES[@]}" "2" "blocked-device record count"
assert_equal "${USBAM_BLOCKED_DEVICES[0]}" \
  '3: block id 1d6b:0002 name "Lab device"' "first blocked device record"
pass "blocked devices are returned as structured records"

export FAKE_DEVICE_MODE=empty
list_blocked_devices ||
  fail "empty blocked-device list was rejected"
assert_equal "${#USBAM_BLOCKED_DEVICES[@]}" "0" "empty device record count"
pass "empty blocked-device list is valid"

FAKE_DEVICE_MODE=malformed
export FAKE_DEVICE_MODE
if list_blocked_devices 2>/dev/null; then
  fail "malformed device record was accepted"
fi
assert_equal "${#USBAM_BLOCKED_DEVICES[@]}" "0" "malformed device records cleared"
pass "malformed device output fails closed"

FAKE_DEVICE_MODE=failure
export FAKE_DEVICE_MODE
if list_blocked_devices 2>/dev/null; then
  fail "failed USBGuard command was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "command_failed" "command failure code"
assert_equal "$USBAM_POLICY_STDERR" "query failed" "captured command stderr"
pass "non-zero USBGuard exit is explicit and stderr is retained"

FAKE_DEVICE_MODE=slow
export FAKE_DEVICE_MODE
if list_blocked_devices 2>/dev/null; then
  fail "timed-out USBGuard command was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "command_timeout" "timeout error code"
pass "USBGuard queries are bounded by the configured timeout"
unset FAKE_DEVICE_MODE

list_active_rules || fail "active-rule query failed"
assert_equal "${#USBAM_ACTIVE_RULES[@]}" "2" "active-rule record count"
get_active_rules || fail "get_active_rules alias failed"
assert_equal "${#USBAM_ACTIVE_RULES[@]}" "2" "get_active_rules record count"
pass "active rules are returned as structured records"

export FAKE_RULE_MODE=empty
list_active_rules ||
  fail "empty active-rule list was rejected"
assert_equal "${#USBAM_ACTIVE_RULES[@]}" "0" "empty active rule count"
pass "empty active-rule list is valid"
unset FAKE_RULE_MODE

POLICY_FILE="$TEST_DIR/rules.conf"
POLICY_FOLDER="$TEST_DIR/rules.d"
mkdir "$POLICY_FOLDER"
touch "$POLICY_FILE"
DAEMON_CONFIG="$TEST_DIR/usbguard-daemon.conf"
USBAM_DAEMON_CONFIG_PATH="$DAEMON_CONFIG"
printf 'RuleFile = %s\n' "$POLICY_FILE" > "$DAEMON_CONFIG"
get_persistent_policy_paths ||
  fail "configured RuleFile was not detected"
assert_equal "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}" "$POLICY_FILE" \
  "RuleFile path"
assert_equal "${#USBAM_PERSISTENT_POLICY_PATHS[@]}" "1" \
  "RuleFile source count"
printf 'RuleFolder = %s\n' "$POLICY_FOLDER" > "$DAEMON_CONFIG"
get_persistent_policy_paths ||
  fail "configured RuleFolder was not detected"
assert_equal "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}" "$POLICY_FOLDER" \
  "RuleFolder path"
assert_equal "${#USBAM_PERSISTENT_POLICY_PATHS[@]}" "1" \
  "RuleFolder source count"
printf 'RuleFile=%s\nRuleFolder=%s\n' "$POLICY_FILE" "$POLICY_FOLDER" \
  > "$DAEMON_CONFIG"
get_persistent_policy_paths ||
  fail "simultaneous RuleFile and RuleFolder were not detected"
assert_equal "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}" "$POLICY_FILE" \
  "combined RuleFile path"
assert_equal "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}" "$POLICY_FOLDER" \
  "combined RuleFolder path"
assert_equal "${#USBAM_PERSISTENT_POLICY_PATHS[@]}" "2" \
  "combined policy source count"
pass "configured RuleFile and RuleFolder sources are both returned"

printf '# no persistent source configured\n' > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "configuration without a policy source was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "policy_source_unconfigured" \
  "missing persistent source error"
assert_equal "${#USBAM_PERSISTENT_POLICY_PATHS[@]}" "0" \
  "sources cleared when none is configured"
printf 'RuleFile=%s\n' "$TEST_DIR/missing-rules.conf" > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "missing RuleFile was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "policy_source_unavailable" \
  "missing RuleFile error"
printf 'RuleFile=/etc/usbguard/../outside.rules\n' > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "parent traversal in RuleFile was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "invalid_policy_path" \
  "policy path traversal error"
printf 'RuleFile=%s\nRuleFile=%s\n' "$POLICY_FILE" "$POLICY_FILE" \
  > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "duplicate RuleFile setting was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "ambiguous_policy_source" \
  "duplicate RuleFile error"
printf 'RuleFolder=%s\nRuleFolder=%s\n' "$POLICY_FOLDER" "$POLICY_FOLDER" \
  > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "duplicate RuleFolder setting was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "ambiguous_policy_source" \
  "duplicate RuleFolder error"
printf 'RuleFile=%s\nRuleFolder=%s\n' "$POLICY_FILE" "$TEST_DIR/missing-rules.d" \
  > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "missing RuleFolder was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "policy_source_unavailable" \
  "missing RuleFolder error"
assert_equal "${#USBAM_PERSISTENT_POLICY_PATHS[@]}" "0" \
  "partial sources cleared after validation failure"
ln -s "$POLICY_FILE" "$TEST_DIR/rules-link.conf"
printf 'RuleFile=%s\n' "$TEST_DIR/rules-link.conf" > "$DAEMON_CONFIG"
if get_persistent_policy_paths >/dev/null 2>&1; then
  fail "symlinked RuleFile was accepted"
fi
assert_equal "$USBAM_POLICY_ERROR_CODE" "policy_source_unavailable" \
  "symlinked RuleFile error"
pass "missing, duplicate, traversing, and symlinked policy sources fail closed"

check_daemon_status ||
  fail "running daemon with reachable IPC was not healthy"
assert_equal "$USBAM_DAEMON_STATUS" "running" "daemon status"
assert_equal "$USBAM_IPC_STATUS" "connected" "IPC status"
pass "daemon and IPC success are reported separately"

FAKE_IPC_MODE=unavailable
export FAKE_IPC_MODE
if check_daemon_status; then
  fail "unavailable IPC was reported healthy"
else
  [[ "$?" -eq 9 ]] || fail "unavailable IPC returned an unexpected status"
fi
assert_equal "$USBAM_DAEMON_STATUS" "running" "daemon remains running"
assert_equal "$USBAM_IPC_STATUS" "unavailable" "unavailable IPC status"
pass "running daemon with unavailable IPC is degraded"
unset FAKE_IPC_MODE

FAKE_DAEMON_MODE=stopped
export FAKE_DAEMON_MODE
if check_daemon_status; then
  fail "stopped daemon was reported healthy"
else
  [[ "$?" -eq 9 ]] || fail "stopped daemon returned an unexpected status"
fi
assert_equal "$USBAM_DAEMON_STATUS" "stopped" "stopped daemon status"
assert_equal "$USBAM_IPC_STATUS" "unavailable" "stopped daemon IPC status"
pass "stopped daemon is reported as unavailable"

if get_usbguard_version unexpected-argument 2>/dev/null; then
  fail "unexpected adapter arguments were accepted"
fi
pass "adapter rejects unexpected arguments"

printf 'All read-only USBGuard adapter checks passed\n'
