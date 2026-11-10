#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
REVOKE="$PROJECT_ROOT/scripts/usb-revoke.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if bash "$REVOKE" --managed-id >/dev/null 2>&1; then
  fail "missing managed ID value was accepted"
else
  status=$?
fi
[[ "$status" == 7 ]] || fail "missing managed ID returned $status instead of 7"

if bash "$REVOKE" --managed-id 11111111-1111-4111-8111-111111111111 --device \
  >/dev/null 2>&1; then
  fail "missing device ID value was accepted"
else
  status=$?
fi
[[ "$status" == 7 ]] || fail "missing device ID returned $status instead of 7"

bash "$REVOKE" --help >/dev/null
printf 'All usb-revoke argument checks passed\n'
