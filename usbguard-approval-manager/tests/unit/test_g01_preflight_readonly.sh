#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$PROJECT_ROOT/tests/integration/collect_g01_readonly_preflight.sh"
TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN" "$TEST_DIR/rules.d"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_USB_COMMANDS"
case "$*" in
  --version)
    printf 'USBGuard 1.1.4\n'
    ;;
  'list-devices')
    printf '1: allow id 1d6b:0002 name "Lab device"\n'
    ;;
  'list-devices --blocked')
    printf '3: block id 1234:5678 name "Test device"\n'
    ;;
  list-rules)
    printf '1: block id 1234:5678\n'
    ;;
  *)
    printf 'forbidden or unexpected USBGuard command: %s\n' "$*" >&2
    exit 64
    ;;
esac
MOCK

cat > "$FAKE_BIN/pgrep" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "-x usbguard-daemon" ]] || exit 64
printf '42\n'
MOCK

chmod 700 "$FAKE_BIN/usbguard" "$FAKE_BIN/pgrep"
export PATH="$FAKE_BIN:$PATH"
FAKE_USB_COMMANDS="$TEST_DIR/commands.log"
export FAKE_USB_COMMANDS
IPC_TIMEOUT_SECONDS=1
export IPC_TIMEOUT_SECONDS
POLICY_FILE="$TEST_DIR/rules.conf"
touch "$POLICY_FILE"
DAEMON_CONFIG="$TEST_DIR/usbguard-daemon.conf"
printf 'RuleFile=%s\nRuleFolder=%s\n' "$POLICY_FILE" "$TEST_DIR/rules.d" \
  > "$DAEMON_CONFIG"
USBAM_DAEMON_CONFIG_PATH="$DAEMON_CONFIG"
export USBAM_DAEMON_CONFIG_PATH

set +e
output="$(env -u USBAM_G01_EXPECTED_HOSTNAME bash "$PREFLIGHT" 2>&1)"
status=$?
set -e
[[ "$status" -eq 9 ]] || fail "missing expected hostname did not fail closed"
[[ "$output" == *"T01_RESULT=UNVERIFIED"* ]] ||
  fail "host mismatch did not report UNVERIFIED"
[[ ! -s "$FAKE_USB_COMMANDS" ]] ||
  fail "USBGuard was queried before the hostname gate"
pass "expected-hostname gate prevents queries on an unconfirmed host"

export USBAM_G01_EXPECTED_HOSTNAME
USBAM_G01_EXPECTED_HOSTNAME="$(hostname)"
set +e
output="$(bash "$PREFLIGHT" 2>&1)"
status=$?
set -e
[[ "$status" -eq 9 ]] || fail "preflight did not keep G-01 gated"
[[ "$output" == *"T01_RESULT=READ_ONLY_EVIDENCE_COLLECTED"* ]] ||
  fail "successful read-only collection was not reported"
[[ "$output" == *"G01_STATUS=UNVERIFIED"* ]] ||
  fail "preflight incorrectly reported G-01 as verified"
[[ "$output" == *"POLICY_CHANGING_TESTS=NOT_RUN"* ]] ||
  fail "preflight did not report that policy-changing tests were skipped"
[[ "$output" == *"RuleFile="* && "$output" == *"RuleFolder="* ]] ||
  fail "both configured policy source paths were not reported"
expected_commands=$'--version\nlist-devices\nlist-devices --blocked\nlist-rules'
asserted_commands="$(<"$FAKE_USB_COMMANDS")"
[[ "$asserted_commands" == "$expected_commands" ]] ||
  fail "preflight ran a command outside its read-only allowlist"
pass "preflight gathers read-only evidence and leaves G-01 unverified"
