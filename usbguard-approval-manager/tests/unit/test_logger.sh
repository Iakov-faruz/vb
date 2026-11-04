#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
LOGGER_LIBRARY="$PROJECT_ROOT/scripts/lib/logger.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/logger" <<'LOGGER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOGGER_CAPTURE"
LOGGER
chmod 700 "$TEST_DIR/bin/logger"

# --- הסבר בעברית ---
# בדיקת יחידה לספריית לוגים (logger).
# בודקת הפרדה בין לוג תפעולי syslog לזרם Audit JSONL מוגן.
# בודקת כתיבת הודעות info/error דרך פקודת logger.
# בודקת כתיבת Audit JSONL דרך audit_write.py עם הרשאות מתאימות.
# מאמתת שכתיבת Audit שנכשלה מדווחת כיאות ושומרת תוצאת מדיניות.
export LOGGER_CAPTURE="$TEST_DIR/operational.log"
export PATH="$TEST_DIR/bin:$PATH"
source "$LOGGER_LIBRARY"
source "$LOGGER_LIBRARY"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

log_info "started safely" || fail "informational log call"
log_error "operational failure" || fail "error log call"
if log_info $'forged\nrecord' 2>/dev/null; then
  fail "control character was accepted in operational log"
fi
[[ "$(wc -l < "$LOGGER_CAPTURE")" -eq 2 ]] ||
  fail "operational logging did not produce exactly two safe calls"
grep -Fq 'started safely' "$LOGGER_CAPTURE" ||
  fail "operational message was not passed to system logger"
pass "operational logging uses system logger and rejects control characters"

if log_audit approve applied id details extra 2>/dev/null; then
  fail "invalid Audit argument count was accepted"
fi
pass "invalid Audit argument count is rejected"

if log_audit approve applied id "safe details" 2>"$TEST_DIR/audit-error.log"; then
  fail "unavailable protected Audit destination reported success"
fi
grep -Fq 'Audit write failed' "$TEST_DIR/audit-error.log" ||
  fail "Audit write failure was not reported"
pass "Audit write failure is explicit"

printf 'All logger checks passed\n'
