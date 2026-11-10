#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/validators.sh"

TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
TEST_PROJECT_ROOT="$TEST_DIR/project"
mkdir -p "$FAKE_BIN" "$TEST_PROJECT_ROOT"
trap 'rm -rf -- "$TEST_DIR"' EXIT

FAKE_RULES_FILE="$TEST_DIR/active_rules.txt"
FAKE_BLOCKED_FILE="$TEST_DIR/blocked_devices.txt"
printf '1: allow id 1d6b:0002\n' > "$FAKE_RULES_FILE"
printf '' > "$FAKE_BLOCKED_FILE"

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
STATE_DIR="${FAKE_STATE_DIR:-/tmp}"
RULES_FILE="$STATE_DIR/active_rules.txt"
BLOCKED_FILE="$STATE_DIR/blocked_devices.txt"
LOG="$STATE_DIR/usbguard.log"
printf '%s %s\n' "$(date +%s)" "$*" >> "$LOG"
case "$1" in
  --version) printf 'USBGuard 1.1.4\n' ;;
  list-devices)
    if [[ "${2:-}" == "--blocked" ]]; then cat "$BLOCKED_FILE" 2>/dev/null || true; exit 0; fi
    cat "$STATE_DIR/all_devices.txt" 2>/dev/null || printf '1: allow id 1d6b:0002\n2: block id 1234:5678\n'
    ;;
  list-rules) cat "$RULES_FILE" 2>/dev/null || true ;;
  allow-device) exit 0 ;;
  block-device) echo "$2: block" >> "$BLOCKED_FILE"; exit 0 ;;
  append-rule)
    rule=""; for arg in "$@"; do [[ "$arg" != "append-rule" && "$arg" != "--temporary" ]] && rule="$arg"; done
    max_id=$(awk -F: '{gsub(/ /,"",$1); if($1>max) max=$1} END{print max+0}' "$RULES_FILE" 2>/dev/null || echo 0)
    new_id=$((max_id+1))
    printf '%s: %s\n' "$new_id" "$rule" >> "$RULES_FILE"
    printf '%s\n' "$new_id"
    exit 0
    ;;
  remove-rule)
    rid="${2:-}"; grep -v "^[[:space:]]*$rid:" "$RULES_FILE" > "$RULES_FILE.tmp" || true; mv "$RULES_FILE.tmp" "$RULES_FILE"; exit 0 ;;
  *) exit 64 ;;
esac
MOCK

cat > "$FAKE_BIN/pgrep" <<'MOCK'
#!/usr/bin/env bash
printf '42\n'; exit 0
MOCK

cat > "$FAKE_BIN/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

chmod 700 "$FAKE_BIN/usbguard" "$FAKE_BIN/pgrep" "$FAKE_BIN/logger"
PATH="$FAKE_BIN:$PATH"
export PATH
export FAKE_STATE_DIR="$TEST_DIR"
export USBAM_STATE_DIR="$TEST_DIR/state"
export USBAM_CONFIG_PATH="$TEST_DIR/config.conf"
printf '' > "$USBAM_CONFIG_PATH"
mkdir -p "$TEST_DIR/state"
printf '1: allow id 1d6b:0002\n2: block id 1234:5678\n' > "$TEST_DIR/all_devices.txt"

# Mock clock_state.py to return trusted
cat > "$FAKE_BIN/python3" <<'PY'
#!/usr/bin/env bash
if [[ "$*" == *"clock_state.py"* ]]; then
  state="${FAKE_CLOCK_STATE:-trusted_same_boot}"
  echo "$state"
  [[ "$state" == "trusted_same_boot" ]] && exit 0
  exit 9
fi
if [[ "$*" == *"atomic-write.py"* ]]; then
  exec /usr/bin/python3 "$@"
fi
if [[ "$*" == *"audit_write.py"* ]]; then
  exit 0
fi
exec /usr/bin/python3 "$@"
PY
chmod 700 "$FAKE_BIN/python3"

export USBAM_AUDIT_FILE="$TEST_DIR/audit.jsonl"
export USBAM_AUDIT_DIR="$TEST_DIR"
export USBAM_LOCK_FILE="$TEST_DIR/lock"
touch "$USBAM_LOCK_FILE"
chmod 600 "$USBAM_LOCK_FILE"
export USBAM_G01_VERIFIED=1
IPC_TIMEOUT_SECONDS=1
USBAM_DAEMON_CONFIG_PATH="$TEST_DIR/usbguard-daemon.conf"
printf 'RuleFile=%s\n' "$TEST_DIR/rules.conf" > "$USBAM_DAEMON_CONFIG_PATH"
touch "$TEST_DIR/rules.conf"
export USBAM_DAEMON_CONFIG_PATH

# Isolate the integration fixture and mock only the root-owned G-01 marker gate.
cp -R "$PROJECT_ROOT/scripts" "$TEST_PROJECT_ROOT/"
sed -i '/^is_g01_verified() {/,/^}/c\is_g01_verified() { return 0; }' \
  "$TEST_PROJECT_ROOT/scripts/lib/usbguard-policy.sh"
TEST_CLEANUP="$TEST_PROJECT_ROOT/scripts/cleanup-expired.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

cat > "$FAKE_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "is-active --quiet ntpsec" ]]
MOCK
cat > "$FAKE_BIN/timedatectl" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "show -p NTPSynchronized --value" ]] || exit 2
printf '%s\n' "${FAKE_TIME_SYNCED:-yes}"
MOCK
cat > "$FAKE_BIN/ntpq" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "-pn" ]] || exit 2
printf '*192.0.2.1 192.0.2.2 2 u 10 64 377 1.0 0.1 0.2\n'
MOCK
chmod 700 "$FAKE_BIN/systemctl" "$FAKE_BIN/timedatectl" "$FAKE_BIN/ntpq"

create_ttl() {
  local mid="$1" rule="$2" hash="$3" expires="$4" status="$5" cid="$6"
  jq -n \
    --arg mid "$mid" \
    --arg rule "$rule" \
    --arg hash "$hash" \
    --arg status "$status" \
    --arg cid "$cid" \
    --argjson expires "$expires" \
    '{
      schema_version: 1,
      records: [{
        managed_id: $mid,
        rule: $rule,
        rule_sha256: $hash,
        expires_at: $expires,
        status: $status,
        correlation_id: $cid
      }]
    }'
}

# Create ttl.json with one expired active record
TTL="$TEST_DIR/state/ttl.json"
RULE="allow id 1234:5678 serial \"EXPIRE-TEST\""
HASH="$(validators_hash_rule "$RULE")"
MID="11111111-1111-4111-8111-111111111111"
CID="22222222-2222-4222-8222-222222222222"
EXPIRED_EPOCH=$(( $(date +%s) - 100 ))  # already expired

create_ttl "$MID" "$RULE" "$HASH" "$EXPIRED_EPOCH" active "$CID" > "$TTL"

# Add rule to fake active rules
printf '10: %s\n' "$RULE" >> "$FAKE_RULES_FILE"

# Run cleanup-expired (should remove expired rule)
bash "$TEST_CLEANUP" 2>&1 | tee "$TEST_DIR/cleanup.log"
RC=${PIPESTATUS[0]}
[[ $RC -eq 0 ]] || fail "cleanup-expired failed with $RC, log: $(cat $TEST_DIR/cleanup.log)"

# Verify record now expired
STATUS="$(jq -r ".records[] | select(.managed_id==\"$MID\") | .status" "$TTL")"
[[ "$STATUS" == "expired" ]] || fail "record should be expired after cleanup, got $STATUS"
pass "cleanup-expired removes expired rule and marks expired"

# Verify rule removed from active rules
if grep -Fq "$RULE" "$FAKE_RULES_FILE"; then
  fail "rule should be removed from active rules after expire"
fi
pass "cleanup-expired verifies removal from active rules"

# Test reconcile: pending -> recovery_required
PENDING_RULE="allow id 9999:0001"
PENDING_HASH="$(validators_hash_rule "$PENDING_RULE")"
PENDING_MID="33333333-3333-4333-8333-333333333333"
PENDING_CID="44444444-4444-4444-8444-444444444444"
create_ttl "$PENDING_MID" "$PENDING_RULE" "$PENDING_HASH" 9999999999 pending "$PENDING_CID" > "$TTL"

bash "$TEST_CLEANUP" --reconcile 2>&1 | tee "$TEST_DIR/cleanup2.log"
RC=${PIPESTATUS[0]}
[[ $RC -eq 0 ]] || fail "cleanup --reconcile failed with $RC"

STATUS="$(jq -r ".records[] | select(.managed_id==\"$PENDING_MID\") | .status" "$TTL")"
[[ "$STATUS" == "recovery_required" ]] || fail "pending should go to recovery_required after reconcile, got $STATUS"
pass "cleanup-expired reconcile moves pending to recovery_required"

# An untrusted clock must preserve an expired active rule and require recovery.
UNTRUSTED_RULE="allow id 9999:0002"
UNTRUSTED_HASH="$(validators_hash_rule "$UNTRUSTED_RULE")"
UNTRUSTED_MID="99999999-9999-4999-8999-999999999999"
UNTRUSTED_CID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
EXPIRED_UNTRUSTED=$(( $(date +%s) - 10 ))
create_ttl "$UNTRUSTED_MID" "$UNTRUSTED_RULE" "$UNTRUSTED_HASH" \
  "$EXPIRED_UNTRUSTED" active "$UNTRUSTED_CID" > "$TTL"
printf '10: %s\n' "$UNTRUSTED_RULE" > "$FAKE_RULES_FILE"
: > "$TEST_DIR/usbguard.log"
FAKE_TIME_SYNCED=no
export FAKE_TIME_SYNCED
bash "$TEST_CLEANUP" 2>&1 | tee "$TEST_DIR/cleanup-untrusted.log"
RC=${PIPESTATUS[0]}
[[ "$RC" -eq 0 ]] || fail "untrusted-clock reconcile failed with $RC"
unset FAKE_TIME_SYNCED
STATUS="$(jq -r ".records[] | select(.managed_id==\"$UNTRUSTED_MID\") | .status" "$TTL")"
[[ "$STATUS" == "recovery_required" ]] ||
  fail "untrusted clock did not move the expired record to recovery_required"
grep -Fq "$UNTRUSTED_RULE" "$FAKE_RULES_FILE" ||
  fail "untrusted clock caused an automatic policy removal"
grep -q "remove-rule" "$TEST_DIR/usbguard.log" &&
  fail "Reaper attempted remove-rule while the clock was untrusted"
pass "untrusted clock blocks automatic expiration and preserves policy"

# Test that Reaper never calls block-device
if grep -q "block-device" "$TEST_DIR/usbguard.log" 2>/dev/null; then
  fail "Reaper called block-device - forbidden per spec"
fi
pass "Reaper never calls block-device"

# Test EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED reporting
# Create active rule + permanent rule with same VID:PID
RULE2="allow id abcd:1234 serial \"TEMP\""
RULE2_HASH="$(validators_hash_rule "$RULE2")"
RULE2_PERM="allow id abcd:1234"
MID2="55555555-5555-4555-8555-555555555555"
CID2="66666666-6666-4666-8666-666666666666"
EXPIRED2=$(( $(date +%s) - 10 ))
create_ttl "$MID2" "$RULE2" "$RULE2_HASH" "$EXPIRED2" active "$CID2" > "$TTL"
# Add both temp and perm to active
printf '' > "$FAKE_RULES_FILE"
printf '10: %s\n' "$RULE2" >> "$FAKE_RULES_FILE"
printf '11: %s\n' "$RULE2_PERM" >> "$FAKE_RULES_FILE"

bash "$TEST_CLEANUP" 2>&1 | tee "$TEST_DIR/cleanup3.log"
if ! grep -q "EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED" "$TEST_DIR/cleanup3.log"; then
  fail "should report EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED when perm rule still allows"
fi
pass "Reaper reports EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED"

# An expired record must never cause a persistent rule to be removed.
RULE3="allow id 5678:1234 serial \"PERSISTENT\""
RULE3_HASH="$(validators_hash_rule "$RULE3")"
MID3="77777777-7777-4777-8777-777777777777"
CID3="88888888-8888-4888-8888-888888888888"
EXPIRED3=$(( $(date +%s) - 10 ))
create_ttl "$MID3" "$RULE3" "$RULE3_HASH" "$EXPIRED3" active "$CID3" > "$TTL"
printf '10: %s\n' "$RULE3" > "$FAKE_RULES_FILE"
printf '%s\n' "$RULE3" > "$TEST_DIR/rules.conf"

bash "$TEST_CLEANUP" 2>&1 | tee "$TEST_DIR/cleanup4.log"
RC=${PIPESTATUS[0]}
[[ $RC -eq 0 ]] || fail "cleanup of a persistent match failed with $RC"
STATUS="$(jq -r ".records[] | select(.managed_id==\"$MID3\") | .status" "$TTL")"
[[ "$STATUS" == "recovery_required" ]] ||
  fail "persistent policy match was not moved to recovery_required"
grep -Fq "$RULE3" "$FAKE_RULES_FILE" ||
  fail "Reaper removed a persistent policy rule"
pass "Reaper preserves a rule present in the persistent policy source"

# RuleFolder is another active persistent source and must receive the same guard.
RULE4="allow id 9abc:7654 serial \"FOLDER-PERSISTENT\""
RULE4_HASH="$(validators_hash_rule "$RULE4")"
MID4="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CID4="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
EXPIRED4=$(( $(date +%s) - 10 ))
create_ttl "$MID4" "$RULE4" "$RULE4_HASH" "$EXPIRED4" active "$CID4" > "$TTL"
printf '10: %s\n' "$RULE4" > "$FAKE_RULES_FILE"
mkdir -p "$TEST_DIR/rule-folder"
printf '%s\n' "$RULE4" > "$TEST_DIR/rule-folder/custom.rules"
printf 'RuleFile=%s\nRuleFolder=%s\n' \
  "$TEST_DIR/rules.conf" "$TEST_DIR/rule-folder" > "$USBAM_DAEMON_CONFIG_PATH"

bash "$TEST_CLEANUP" 2>&1 | tee "$TEST_DIR/cleanup-folder.log"
RC=${PIPESTATUS[0]}
[[ "$RC" -eq 0 ]] || fail "cleanup of a RuleFolder match failed with $RC"
STATUS="$(jq -r ".records[] | select(.managed_id==\"$MID4\") | .status" "$TTL")"
[[ "$STATUS" == "recovery_required" ]] ||
  fail "RuleFolder policy match was not moved to recovery_required"
grep -Fq "$RULE4" "$FAKE_RULES_FILE" ||
  fail "Reaper removed a RuleFolder policy rule"
pass "Reaper preserves a rule present in RuleFolder"

# A missing recovery journal is the only way to proceed after a prior recovery.
touch "$USBAM_STATE_DIR/restore_journal.json"
if bash "$TEST_CLEANUP" > "$TEST_DIR/recovery.log" 2>&1; then
  fail "preflight accepted an open restore journal"
else
  RC=$?
fi
[[ "$RC" -eq 9 ]] || fail "open restore journal returned exit code $RC instead of 9"
grep -q '"result_state": "RECOVERY_REQUIRED"' "$TEST_DIR/recovery.log" ||
  fail "open restore journal did not produce RECOVERY_REQUIRED"
rm -f "$USBAM_STATE_DIR/restore_journal.json"
pass "Reaper preserves recovery-required exit status"

printf 'All cleanup-expired checks passed\n'
