#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/usbguard-policy.sh"

TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'lock_release; rm -rf -- "$TEST_DIR"' EXIT

FAKE_RULES_FILE="$TEST_DIR/active_rules.txt"
printf '1: allow id 1d6b:0002\n2: block id 9999:0001\n' > "$FAKE_RULES_FILE"
FAKE_DEVICES_FILE="$TEST_DIR/devices.txt"
printf '1: allow id 1d6b:0002\n3: block id 1234:5678\n4: block id abcd:ef01\n5: allow id 1111:2222\n' > "$FAKE_DEVICES_FILE"

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
STATE_DIR="${FAKE_STATE_DIR:?}"
RULES_FILE="$STATE_DIR/active_rules.txt"
DEVICES_FILE="$STATE_DIR/devices.txt"
LOG_FILE="$STATE_DIR/usbguard-commands.log"
printf '%s\n' "$*" >> "$LOG_FILE"

case "$1" in
  --version)
    printf 'USBGuard 1.1.4\n'
    ;;
  list-devices)
    if [[ "${2:-}" == "--blocked" ]]; then
      grep -E '^[[:space:]]*[0-9]+: block([[:space:]]|$)' "$DEVICES_FILE" || true
    else
      cat "$DEVICES_FILE"
    fi
    ;;
  list-rules)
    cat "$RULES_FILE"
    ;;
  allow-device|block-device)
    dev_id="${2:-}"
    if [[ ! "$dev_id" =~ ^[0-9]+$ ]]; then
      echo "invalid device id" >&2
      exit 2
    fi
    if [[ "$1" == "allow-device" && "${FAKE_ALLOW_NOOP:-0}" == "1" ]] ||
      [[ "$1" == "block-device" && "${FAKE_BLOCK_NOOP:-0}" == "1" ]]; then
      exit 0
    fi
    if ! grep -qE "^[[:space:]]*$dev_id:" "$DEVICES_FILE"; then
      echo "device not found" >&2
      exit 7
    fi
    if [[ "$1" == "allow-device" ]]; then
      sed -E "s/^$dev_id: (block|reject)/$dev_id: allow/" "$DEVICES_FILE" > "$DEVICES_FILE.tmp"
    else
      sed -E "s/^$dev_id: allow/$dev_id: block/" "$DEVICES_FILE" > "$DEVICES_FILE.tmp"
    fi
    mv "$DEVICES_FILE.tmp" "$DEVICES_FILE"
    ;;
  append-rule)
    rule=""
    for arg in "$@"; do
      [[ "$arg" == "append-rule" || "$arg" == "--temporary" ]] || rule="$arg"
    done
    if [[ "$rule" == *"00-system.rules"* ]]; then
      echo "protected" >&2
      exit 5
    fi
    if grep -Fq "$rule" "$RULES_FILE"; then
      echo "duplicate" >&2
      exit 6
    fi
    max_id="$(awk -F: '{gsub(/ /,"",$1); if($1>max) max=$1} END{print max+0}' "$RULES_FILE")"
    new_id=$((max_id + 1))
    printf '%s: %s\n' "$new_id" "$rule" >> "$RULES_FILE"
    if [[ " $* " != *" --temporary "* ]]; then
      printf '%s\n' "$rule" >> "${FAKE_PERSISTENT_RULES_FILE:?}"
    fi
    printf '%s\n' "$new_id"
    ;;
  remove-rule)
    rid="${2:-}"
    if [[ ! "$rid" =~ ^[0-9]+$ ]] || ! grep -qE "^[[:space:]]*$rid:" "$RULES_FILE"; then
      echo "rule not found" >&2
      exit 4
    fi
    grep -vE "^[[:space:]]*$rid:" "$RULES_FILE" > "$RULES_FILE.tmp" || true
    mv "$RULES_FILE.tmp" "$RULES_FILE"
    ;;
  *)
    echo "unexpected command: $*" >&2
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
export PATH FAKE_STATE_DIR="$TEST_DIR"
IPC_TIMEOUT_SECONDS=1
USBAM_DAEMON_CONFIG_PATH="$TEST_DIR/usbguard-daemon.conf"
printf 'RuleFile=%s\n' "$TEST_DIR/rules.conf" > "$USBAM_DAEMON_CONFIG_PATH"
touch "$TEST_DIR/rules.conf"
FAKE_PERSISTENT_RULES_FILE="$TEST_DIR/rules.conf"
export FAKE_PERSISTENT_RULES_FILE

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() {
  printf 'PASS: %s\n' "$1"
}

# Verify that legacy environment and /tmp-based bypasses are not accepted.
unset USBAM_G01_VERIFIED USBAM_ALLOW_BLOCK
if ! is_g01_verified; then
  export USBAM_G01_VERIFIED=1 USBAM_ALLOW_BLOCK=1
  if is_g01_verified; then
    fail "environment variables bypassed the G-01 marker"
  fi
  pass "G-01 environment overrides are ignored"
else
  pass "G-01 marker is already valid on this test host"
fi
unset USBAM_G01_VERIFIED USBAM_ALLOW_BLOCK

# Test canonicalization and hashing.
canon="$(usbguard_canonicalize_rule '  allow id 1234:5678  ')"
[[ "$canon" == "allow id 1234:5678" ]] || fail "canonicalize trim failed: '$canon'"
pass "canonicalize trims whitespace"

hash1="$(usbguard_hash_rule 'allow id 1234:5678')"
hash2="$(usbguard_hash_rule 'allow id 1234:5678')"
[[ "$hash1" == "$hash2" && "${#hash1}" -eq 64 ]] || fail "hash is not stable SHA-256"
pass "hash is deterministic SHA-256"

# The fake gate is local to this test process; production verification remains
# based exclusively on the root-owned evidence marker.
is_g01_verified() {
  [[ "${FAKE_G01_VERIFIED:-0}" == "1" ]]
}

FAKE_G01_VERIFIED=0
if usbguard_policy_run_write block-device 5 2>/dev/null; then
  fail "write runner accepted a mutation before G-01"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "g01_not_verified" ]] || fail "write gate error code mismatch"
FAKE_G01_VERIFIED=1
if usbguard_policy_run_write block-device 5 2>/dev/null; then
  fail "write runner accepted a mutation without the global lock"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "lock_not_held" ]] || fail "global-lock error code mismatch"
LOCK_FILE="$TEST_DIR/policy.lock"
: > "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
lock_acquire 1 || fail "could not acquire the test lock"
pass "all write operations require G-01 verification and the global lock"

# Missing arguments must be reported, not expanded under nounset.
for command_name in approve_device add_temporary_rule add_permanent_rule \
  remove_rule_by_canonical_rule block_device; do
  if "$command_name" 2>/dev/null; then
    fail "$command_name accepted missing arguments"
  fi
  [[ "$USBAM_POLICY_ERROR_CODE" == "invalid_arguments" ]] || fail "$command_name missing-argument error code mismatch"
done
pass "write operations reject missing arguments safely"

# Approvals must target a live device and verify its resulting state.
list_blocked_devices >/dev/null || fail "initial blocked list failed"
[[ "${#USBAM_BLOCKED_DEVICES[@]}" -eq 2 ]] || fail "initial blocked count mismatch"
approve_device 3 || fail "approve_device 3 failed"
[[ "$USBAM_LAST_DEVICE_ID" == "3" ]] || fail "last device ID not set"
if grep -qE '^3: block([[:space:]]|$)' "$FAKE_DEVICES_FILE"; then
  fail "device 3 remains blocked after approval"
fi
pass "approve_device verifies the selected device is allowed"

printf '3: block id 1234:5678\n' > "$TEST_DIR/device-restore"
grep -vE '^3:' "$FAKE_DEVICES_FILE" >> "$TEST_DIR/device-restore"
mv "$TEST_DIR/device-restore" "$FAKE_DEVICES_FILE"
export FAKE_ALLOW_NOOP=1
if approve_device 3 2>/dev/null; then
  fail "approve_device accepted a successful command with unchanged blocked state"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "device_still_blocked" ]] || fail "approval verification error code mismatch"
unset FAKE_ALLOW_NOOP
pass "approve_device fails when USBGuard does not change device state"

if approve_device "abc" 2>/dev/null; then
  fail "approve_device accepted an invalid ID"
fi
pass "approve_device rejects invalid IDs"

# Temporary and permanent rule validation.
add_temporary_rule 'allow id abcd:1234 serial "TEST"' || fail "temporary rule append failed"
[[ -n "$USBAM_LAST_RULE_ID" ]] || fail "temporary rule ID not set"
pass "temporary rule append succeeds"

if add_temporary_rule 'allow id abcd:1234 serial "TEST"' 2>/dev/null; then
  fail "duplicate temporary rule was accepted"
fi
pass "duplicate temporary rules are rejected"

if add_temporary_rule 'allow id 9999:0001' 2>/dev/null; then
  fail "block-before-allow conflict was accepted"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "precedence_conflict" ]] || fail "precedence conflict error code mismatch"
pass "block-before-allow conflict is rejected"

printf '98: block with-interface equals {03:*:*}\n' >> "$FAKE_RULES_FILE"
if add_temporary_rule 'allow id 1234:5678' 2>/dev/null; then
  fail "generic block-before-specific-allow conflict was accepted"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "precedence_conflict" ]] || fail "generic precedence error code mismatch"
grep -vE '^98:' "$FAKE_RULES_FILE" > "$FAKE_RULES_FILE.tmp"
mv "$FAKE_RULES_FILE.tmp" "$FAKE_RULES_FILE"
pass "generic earlier blocks conservatively reject later allows"

if add_temporary_rule 'allow id 1234:5678 path "00-system.rules"' 2>/dev/null; then
  fail "protected rule was accepted"
fi
pass "protected 00-system.rules is rejected"

add_permanent_rule 'allow id 1111:2222' || fail "permanent rule append failed"
grep -Fqx 'allow id 1111:2222' "$FAKE_PERSISTENT_RULES_FILE" ||
  fail "permanent rule was not verified in the persistent policy"
pass "permanent rule append succeeds"

usbguard_find_rule_id_by_canonical 'allow id 1111:2222' >/dev/null ||
  fail "existing canonical rule was not found"
[[ -n "$USBAM_MATCHED_RULE_ID" ]] || fail "matched rule ID is empty"
pass "canonical rule lookup finds a unique match"

printf '99: allow id 1111:2222\n' >> "$FAKE_RULES_FILE"
if usbguard_find_rule_id_by_canonical 'allow id 1111:2222' 2>/dev/null; then
  fail "ambiguous rule match was accepted"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "ambiguous_rule_match" ]] || fail "ambiguous match error code mismatch"
grep -vE '^99:' "$FAKE_RULES_FILE" > "$FAKE_RULES_FILE.tmp"
mv "$FAKE_RULES_FILE.tmp" "$FAKE_RULES_FILE"
pass "canonical rule lookup rejects ambiguous matches"

remove_rule_by_canonical_rule 'allow id 1111:2222' || fail "canonical rule removal failed"
if usbguard_find_rule_id_by_canonical 'allow id 1111:2222' 2>/dev/null; then
  fail "removed rule remains active"
fi
pass "canonical rule removal is verified"

if remove_rule_by_canonical_rule 'allow id 9999:8888' 2>/dev/null; then
  fail "removal of a missing rule succeeded"
fi
pass "missing rules cannot be removed"

# Block operations must also verify the resulting state.
if block_device 99 2>/dev/null; then
  fail "block_device succeeded for a missing device"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "command_failed" ]] || fail "missing-device block error code mismatch"

export FAKE_BLOCK_NOOP=1
if block_device 5 2>/dev/null; then
  fail "block_device accepted a successful command with unchanged state"
fi
[[ "$USBAM_POLICY_ERROR_CODE" == "device_not_blocked" ]] || fail "block verification error code mismatch"
unset FAKE_BLOCK_NOOP

block_device 5 || fail "block_device failed for a live device"
grep -qE '^5: block([[:space:]]|$)' "$FAKE_DEVICES_FILE" || fail "device 5 is not blocked"
pass "block_device verifies the selected device is blocked"

if usbguard_policy_run_readonly allow-device 1 2>/dev/null; then
  fail "read-only runner accepted a write operation"
fi
pass "read-only runner rejects write operations"

printf 'All policy write checks passed\n'
