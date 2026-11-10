#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/result.sh
source "$PROJECT_ROOT/scripts/lib/result.sh"
set -o errexit -o nounset -o pipefail
# Sourcing a library twice must not reset results or fail on readonly constants.
source "$PROJECT_ROOT/scripts/lib/result.sh"

# --- הסבר בעברית ---
# בדיקת יחידה ל-model תוצאות/שגיאות (result model).
# בודקת אתחול, קודי יציאה, מצבי תוצאה והדפסת JSON.
# מודל תוצאות משותף (SRS §21, SEC-16) עם קבועי יציאה מוגדרים מראש
# ופונקציות ניהול state גלובלי.
# בודקת שכפילת אתחול, תרגום מצבים ופלט JSON תקין.

if env RESULT_MODEL_LOADED=1 bash -c \
  'source "$1"; [[ "$EXIT_AUDIT" == "14" ]]' _ \
  "$PROJECT_ROOT/scripts/lib/result.sh"; then
  printf 'PASS: exported initialization marker cannot bypass setup\n'
else
  printf 'FAIL: exported initialization marker bypassed setup\n' >&2
  exit 1
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local name="$3"
  [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
  printf 'PASS: %s\n' "$name"
}

result_start
result_partial "one item succeeded; one failed"
assert_equal "$RESULT_PARTIAL" "$RESULT_STATE" "partial state is not success"
assert_equal "$EXIT_PARTIAL" "$RESULT_EXIT_CODE" "partial exit code"
assert_equal "unknown" "$RESULT_POLICY_STATUS" "partial policy aggregate is unknown"
assert_equal "not_applicable" "$RESULT_AUDIT_STATUS" "partial audit default is valid"
if result_set "INVALID" 8 "unsupported code" 2>/dev/null; then
  fail "unsupported exit code was accepted"
fi
if result_set "$RESULT_POLICY_APPLIED_AUDIT_FAILED" "$EXIT_OK" \
  "invalid state/code pairing" 2>/dev/null; then
  fail "mismatched result state and exit code were accepted"
fi
if result_partial "invalid partial status" partial partial 2>/dev/null; then
  fail "unsupported partial statuses were accepted"
fi
assert_equal "$RESULT_PARTIAL" "$RESULT_STATE" "invalid result leaves state unchanged"

result_start
result_partial "partial batch with known audit outcome" unknown written \
  "batch_policy_incomplete" ""
assert_equal "unknown" "$RESULT_POLICY_STATUS" "partial batch accepts valid policy status"
assert_equal "written" "$RESULT_AUDIT_STATUS" "partial batch accepts valid audit status"
assert_equal "batch_policy_incomplete" "$RESULT_POLICY_DETAIL_CODE" \
  "partial batch preserves policy detail code"

result_start
result_policy_applied "policy and audit verified"
assert_equal "applied" "$RESULT_POLICY_STATUS" "successful policy result"
assert_equal "written" "$RESULT_AUDIT_STATUS" "successful audit result"

result_start
result_operation_failed "precondition failed"
assert_equal "$EXIT_OPERATION" "$RESULT_EXIT_CODE" "operational failure exit code"
assert_equal "not_applied" "$RESULT_POLICY_STATUS" "operational failure policy result"

result_start
result_validation_failed "invalid input"
assert_equal "$EXIT_VALIDATION" "$RESULT_EXIT_CODE" "validation failure exit code"
assert_equal "$RESULT_VALIDATION_FAILED" "$RESULT_STATE" "validation failure state"

result_start
result_policy_failed "policy command rejected"
assert_equal "$EXIT_OPERATION" "$RESULT_EXIT_CODE" "known policy failure exit code"
assert_equal "not_applied" "$RESULT_POLICY_STATUS" "known policy failure outcome"

result_start
result_unknown "policy outcome cannot be verified"
assert_equal "$EXIT_INCONSISTENT" "$RESULT_EXIT_CODE" "unknown outcome exit code"
assert_equal "unknown" "$RESULT_POLICY_STATUS" "unknown policy outcome"

result_start
result_recovery_required "manual recovery is required"
assert_equal "$EXIT_INCONSISTENT" "$RESULT_EXIT_CODE" "recovery exit code"

result_start
result_policy_applied_audit_failed $'audit "failed"\nsecond line\tend; apostrophe: \047; Unicode: \u00e9; control: \001'
assert_equal "$EXIT_AUDIT" "$RESULT_EXIT_CODE" "audit failure exit code"
assert_equal "applied" "$RESULT_POLICY_STATUS" "policy outcome retained"
assert_equal "failed" "$RESULT_AUDIT_STATUS" "audit failure distinguished"
[[ "$RESULT_CORRELATION_ID" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]] ||
  fail "correlation ID is not a UUID"

if result_add_item "invalid-device" "$RESULT_POLICY_FAILED" "$EXIT_OPERATION" \
  "contradictory status" applied written 2>/dev/null; then
  fail "per-item status contradicting its result state was accepted"
fi
assert_equal "0" "${#RESULT_ITEM_JSON[@]}" "invalid item is not appended"
result_add_item "device-01" "$RESULT_SUCCESS" "$EXIT_OK" "approved" \
  applied written
result_add_item "device-02" "$RESULT_POLICY_FAILED" "$EXIT_OPERATION" \
  "policy rejected" not_applied not_applicable "policy_rejected"
result_print_json > "$TEST_DIR/result.json"
python3 -m json.tool "$TEST_DIR/result.json" >/dev/null ||
  fail "result JSON is invalid"
assert_equal "applied" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["policy_result"]["status"])' "$TEST_DIR/result.json")" \
  "JSON contains separate policy result"
assert_equal "True" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["policy_result"]["detail_code"] is None)' "$TEST_DIR/result.json")" \
  "policy result includes nullable detail code"
assert_equal "failed" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["audit_result"]["status"])' "$TEST_DIR/result.json")" \
  "JSON contains separate audit result"
assert_equal "policy_rejected" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["items"][1]["policy_result"]["detail_code"])' "$TEST_DIR/result.json")" \
  "batch item preserves its policy detail code"
assert_equal "2" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$TEST_DIR/result.json")" \
  "JSON contains a result for each batch item"
assert_equal $'audit "failed"\nsecond line\tend; apostrophe: \047; Unicode: \u00e9; control: \001' \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["detail"], end="")' "$TEST_DIR/result.json")" \
  "JSON detail round-trip"

result_start
result_cancelled "cancelled before policy change"
assert_equal "$EXIT_CANCELLED" "$RESULT_EXIT_CODE" "cancelled exit code"
assert_equal "$RESULT_CANCELLED" "$RESULT_STATE" "cancellation state is distinct"
assert_equal "not_applied" "$RESULT_POLICY_STATUS" "cancelled policy outcome"

result_start
result_success "no batch items"
result_print_json > "$TEST_DIR/empty-items.json"
python3 -m json.tool "$TEST_DIR/empty-items.json" >/dev/null ||
  fail "result JSON without batch items is invalid"
assert_equal "0" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$TEST_DIR/empty-items.json")" \
  "JSON contains an empty items array for non-batch results"

printf 'All result-model checks passed\n'
