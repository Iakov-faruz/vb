#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state"
export USBAM_CONFIG_PATH="$TEST_DIR/missing.conf"
export USBAM_STATE_DIR="$TEST_DIR/state"
export USBAM_TTL_FILE="$TEST_DIR/state/ttl.json"
export USBAM_RESTORE_JOURNAL_FILE="$TEST_DIR/state/restore_journal.json"
export USBAM_DAEMON_CONFIG_PATH="$TEST_DIR/usbguard-daemon.conf"
export USBAM_LOCK_FILE="$TEST_DIR/lock"
touch "$USBAM_LOCK_FILE"
chmod 600 "$USBAM_LOCK_FILE"
printf 'RuleFile=%s\nRuleFolder=%s\n' \
  "$TEST_DIR/rules.conf" "$TEST_DIR/rules.d" > "$USBAM_DAEMON_CONFIG_PATH"
touch "$TEST_DIR/rules.conf"
mkdir "$TEST_DIR/rules.d"
export PATH="$TEST_DIR/bin:$PATH"

cat > "$TEST_DIR/bin/timeout" <<'EOF'
#!/usr/bin/env bash
while (($#)) && [[ "$1" == -* ]]; do shift; done
shift
exec "$@"
EOF
cat > "$TEST_DIR/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "${USBAM_TEST_DAEMON_RUNNING:-0}" == "1" ]]
EOF
cat > "$TEST_DIR/bin/usbguard" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "list-devices") printf '1: allow id 048d:1234\n' ;;
  "list-rules")
    [[ "${USBAM_TEST_POLICY_QUERY_FAILED:-0}" == "1" ]] && exit 2
    printf '1: allow id 048d:1234\n'
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$TEST_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "is-active" && "$2" == "--quiet" ]] || exit 2
if [[ "${USBAM_TEST_TIMER_ACTIVE:-0}" == "1" ]]; then
  exit 0
fi
exit 3
EOF
chmod +x "$TEST_DIR/bin/"*

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

run_status() {
  bash "$PROJECT_ROOT/scripts/usbguard-status.sh" --json
}

output="$(run_status)"
jq -e '
  .schema_version == 1 and
  .service_status == "unavailable" and
  .daemon_status == "stopped" and
  .ipc_status == "unavailable" and
  .timer_status == "inactive" and
  .ttl_counts == {
    pending: 0, active: 0, inconsistent: 0, recovery_required: 0, expired: 0
  } and
  .policy_result.status == "unknown" and
  .audit_result.status == "not_applicable"
' <<< "$output" >/dev/null || fail "stopped daemon status does not match schema"
pass "reports stopped daemon and complete zero TTL counts"

cat > "$USBAM_TTL_FILE" <<'EOF'
{"schema_version":1,"records":[
  {"managed_id":"f212db55-5330-4b54-ae96-07582941c7c3","rule":"allow id 048d:1234","rule_sha256":"97178f50cead3d9307c63b7bffe35f1c80a08d03d8741a395258b4ba0bc87386","expires_at":1793740550,"status":"pending","correlation_id":"f212db55-5330-4b54-ae96-07582941c7c3"},
  {"managed_id":"f212db55-5330-4b54-ae96-07582941c7c4","rule":"allow id 048d:1234","rule_sha256":"97178f50cead3d9307c63b7bffe35f1c80a08d03d8741a395258b4ba0bc87386","expires_at":1793740550,"status":"active","correlation_id":"f212db55-5330-4b54-ae96-07582941c7c4"},
  {"managed_id":"f212db55-5330-4b54-ae96-07582941c7c5","rule":"allow id 048d:1234","rule_sha256":"97178f50cead3d9307c63b7bffe35f1c80a08d03d8741a395258b4ba0bc87386","expires_at":1793740550,"status":"expired","correlation_id":"f212db55-5330-4b54-ae96-07582941c7c5"}
]}
EOF
export USBAM_TEST_DAEMON_RUNNING=1
export USBAM_TEST_TIMER_ACTIVE=1
output="$(run_status)"
jq -e '
  .service_status == "healthy" and
  .daemon_status == "running" and
  .ipc_status == "connected" and
  .timer_status == "active" and
  .ttl_counts.pending == 1 and
  .ttl_counts.active == 1 and
  .ttl_counts.expired == 1 and
  .ttl_counts.inconsistent == 0 and
  .ttl_counts.recovery_required == 0 and
  .policy_result.status == "not_applicable"
' <<< "$output" >/dev/null || fail "healthy status or TTL counts are incorrect"
pass "reports live read-only status and counts each TTL state"

export USBAM_TEST_POLICY_QUERY_FAILED=1
output="$(run_status)"
jq -e '
  .service_status == "degraded" and
  .policy_result.status == "unknown" and
  .policy_result.detail_code == "command_failed" and
  .detail_code == "policy_query_failed"
' <<< "$output" >/dev/null || fail "failed policy query was not surfaced"
unset USBAM_TEST_POLICY_QUERY_FAILED
pass "surfaces policy query failure without a success-shaped status"

printf '{invalid json\n' > "$USBAM_TTL_FILE"
output="$(run_status)"
jq -e '
  .service_status == "degraded" and
  .detail_code == "ttl_state_invalid"
' <<< "$output" >/dev/null || fail "invalid TTL state was not surfaced"
pass "reports invalid TTL state as degraded"

cat > "$USBAM_TTL_FILE" <<'EOF'
{"schema_version":1,"records":[
  {"managed_id":"f212db55-5330-4b54-ae96-07582941c7c3","rule":"allow id 048d:1234","rule_sha256":"97178f50cead3d9307c63b7bffe35f1c80a08d03d8741a395258b4ba0bc87386","expires_at":1793740550,"status":"pending","correlation_id":"f212db55-5330-4b54-ae96-07582941c7c3"},
  {"managed_id":"f212db55-5330-4b54-ae96-07582941c7c4","rule":"allow id 048d:1234","rule_sha256":"97178f50cead3d9307c63b7bffe35f1c80a08d03d8741a395258b4ba0bc87386","expires_at":1793740550,"status":"active","correlation_id":"f212db55-5330-4b54-ae96-07582941c7c4"},
  {"managed_id":"f212db55-5330-4b54-ae96-07582941c7c5","rule":"allow id 048d:1234","rule_sha256":"97178f50cead3d9307c63b7bffe35f1c80a08d03d8741a395258b4ba0bc87386","expires_at":1793740550,"status":"expired","correlation_id":"f212db55-5330-4b54-ae96-07582941c7c5"}
]}
EOF
touch "$USBAM_RESTORE_JOURNAL_FILE"
output="$(run_status)"
jq -e '
  .service_status == "degraded" and
  .detail_code == "restore_recovery_required"
' <<< "$output" >/dev/null || fail "restore journal did not degrade service status"
pass "reports open restore journal as degraded"

if bash "$PROJECT_ROOT/scripts/usbguard-status.sh" --unexpected >/dev/null 2>&1; then
  fail "unknown arguments were accepted"
else
  [[ $? == 7 ]] || fail "invalid arguments did not return EXIT_VALIDATION"
fi
pass "rejects arguments outside the JSON status contract"

printf 'All usbguard-status checks passed\n'
