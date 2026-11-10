#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
LOCK_LIBRARY="$PROJECT_ROOT/scripts/lib/lock.sh"
TEST_DIR="$(mktemp -d)"
LOCK_PATH="$TEST_DIR/manager.lock"
touch "$LOCK_PATH"
chmod 600 "$LOCK_PATH"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

bash -c '
  source "$1"
  LOCK_FILE="$2"
  lock_acquire 1
  [[ "$LOCK_HELD" == 1 ]]
  lock_release
  [[ "$LOCK_HELD" == 0 ]]
' _ "$LOCK_LIBRARY" "$LOCK_PATH" ||
  fail "free lock acquisition and explicit release"
pass "free lock acquisition and explicit release"

READY="$TEST_DIR/ready"
bash -c '
  source "$1"
  LOCK_FILE="$2"
  lock_acquire 1
  : > "$3"
  sleep 0.6
' _ "$LOCK_LIBRARY" "$LOCK_PATH" "$READY" &
HOLDER_PID=$!
for _ in {1..100}; do
  [[ -e "$READY" ]] && break
  sleep 0.01
done
[[ -e "$READY" ]] || fail "lock holder did not start"
if bash -c '
  source "$1"
  LOCK_FILE="$2"
  lock_acquire 0.1
' _ "$LOCK_LIBRARY" "$LOCK_PATH" 2>/dev/null; then
  fail "second process acquired a held lock"
fi
wait "$HOLDER_PID" || fail "lock holder failed"
pass "competing process times out safely"

bash -c '
  source "$1"
  LOCK_FILE="$2"
  lock_acquire 1
' _ "$LOCK_LIBRARY" "$LOCK_PATH" ||
  fail "EXIT trap did not release lock"
pass "EXIT trap releases lock"

if bash -c '
  source "$1"
  LOCK_FILE="$2"
  trap ":" EXIT
  lock_acquire 1
' _ "$LOCK_LIBRARY" "$LOCK_PATH" 2>/dev/null; then
  fail "lock acquisition replaced a caller EXIT trap"
fi
pass "existing EXIT trap is preserved and acquisition fails closed"

bash -c '
  source "$1"
  LOCK_FILE="$2"
  trap "lock_release; :" EXIT
  lock_acquire 1
  [[ "$LOCK_HELD" == 1 ]]
' _ "$LOCK_LIBRARY" "$LOCK_PATH" ||
  fail "composed EXIT trap was rejected"
pass "composed caller EXIT trap retains lock release"

if bash -c '
  source "$1"
  LOCK_FILE="$2"
  trap ":; lock_release" EXIT
  lock_acquire 1
' _ "$LOCK_LIBRARY" "$LOCK_PATH" 2>/dev/null; then
  fail "EXIT trap with cleanup before lock release was accepted"
fi
pass "unsafe EXIT trap ordering is rejected"

if bash -c '
  source "$1"
  LOCK_FILE="$2"
  lock_acquire -1
' _ "$LOCK_LIBRARY" "$LOCK_PATH" 2>/dev/null; then
  fail "negative timeout was accepted"
fi
pass "invalid timeout is rejected"

LINK_PATH="$TEST_DIR/linked.lock"
ln -s "$LOCK_PATH" "$LINK_PATH"
if bash -c '
  source "$1"
  LOCK_FILE="$2"
  lock_acquire 1
' _ "$LOCK_LIBRARY" "$LINK_PATH" 2>/dev/null; then
  fail "symbolic-link lock path was accepted"
fi
pass "symbolic-link lock path is rejected"

printf 'All lock checks passed\n'
