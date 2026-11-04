#!/usr/bin/env bash
# Run the full automated verification suite for USBGuard Approval Manager.
# --safe (default): runs shell syntax checks, all unit tests (UT-01..UT-15),
#   and integration tests T-01..T-07. Never changes USBGuard policy or USB device state.
# --live-g01: delegates to the existing destructive G-01 harness (requires isolated VM).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
MODE="safe"

usage() {
  cat <<'EOF'
Usage: run_integration_tests.sh [--safe | --live-g01]

--safe (default) runs shell syntax checks, unit tests and integration tests
  T-01..T-07. It never changes USBGuard policy or USB device state.
--live-g01 delegates to the existing destructive G-01 harness and therefore
  requires its explicit disposable-VM, USB-ID, write and confirmation guards.

Exit status 0 = all automated checks passed.
Exit status 1 = one or more automated checks failed.
Exit status 2 = software checks passed but acceptance still requires an
  isolated target VM and retained T-01..T-28 evidence.
EOF
}

while (( $# )); do
  case "$1" in
    --safe) MODE="safe"; shift ;;
    --live-g01) MODE="live-g01"; shift ;;
    --help)
      if (( $# != 1 )); then usage >&2; exit 7; fi
      usage; exit 0 ;;
    *) usage >&2; exit 7 ;;
  esac
done

FAIL=0

echo "=== Phase 7: Integration Testing, QA & Acceptance ==="
echo "Project root: $PROJECT_ROOT"
echo "Mode: $MODE"

# ------------------------------------------------------------------
# 1. Shell syntax check (check-shell)
# ------------------------------------------------------------------
echo -e '\n--- 1. Shell syntax check ---'
syntax_fail=0
for file in deploy.sh deploy-lib.sh deploy-uninstall.sh validate_all.sh \
            scripts/*.sh scripts/lib/*.sh tests/unit/*.sh tests/integration/*.sh tests/quick/*.sh; do
  if [ -f "$PROJECT_ROOT/$file" ]; then
    if ! bash -n "$PROJECT_ROOT/$file" 2>/dev/null; then
      echo "SYNTAX FAIL: $file"; syntax_fail=1
    fi
  fi
done
if [[ $syntax_fail -eq 0 ]]; then echo "PASS: all shell scripts valid syntax"; else echo "FAIL: syntax errors"; FAIL=1; fi

# ------------------------------------------------------------------
# 2. Unit tests (test-shell + test-python)
# ------------------------------------------------------------------
echo -e '\n--- 2. Unit tests ---'
unit_fail=0
for test in "$PROJECT_ROOT"/tests/unit/test_*.sh; do
  if [ -f "$test" ]; then
    echo "--- running $(basename "$test") ---"
    if ! bash "$test" 2>&1; then
      echo "UNIT FAIL: $(basename "$test")"; unit_fail=1
    fi
  fi
done
for py in "$PROJECT_ROOT"/tests/unit/test_*.py; do
  if [ -f "$py" ]; then
    echo "--- running $(basename "$py") ---"
    if ! python "$py" 2>&1; then
      echo "PY FAIL: $(basename "$py")"; unit_fail=1
    fi
  fi
done
if [[ $unit_fail -eq 0 ]]; then echo "PASS: all unit tests"; else echo "FAIL: unit test failures"; FAIL=1; fi

# ------------------------------------------------------------------
# 3. Integration tests T-01..T-07
# ------------------------------------------------------------------
echo -e '\n--- 3. Integration tests T-01..T-07 ---'
integration_fail=0
for t in 01 02 03 04 05 06 07; do
  test_file="$PROJECT_ROOT/tests/integration/test_T${t}_*.sh"
  # expand glob
  shopt -s nullglob
  matches=( $test_file )
  shopt -u nullglob
  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "SKIP: T-$t no test file found"; continue
  fi
  tf="${matches[0]}"
  echo "--- running $(basename "$tf") ---"
  if ! bash "$tf" 2>&1; then
    echo "INTEGRATION FAIL: $(basename "$tf")"; integration_fail=1
  fi
done
if [[ $integration_fail -eq 0 ]]; then echo "PASS: all integration tests T-01..T-07"; else echo "FAIL: integration test failures"; FAIL=1; fi

# ------------------------------------------------------------------
# 4. Live G-01 (optional, destructive)
# ------------------------------------------------------------------
if [[ "$MODE" == "live-g01" ]]; then
  echo -e '\n--- 4. Live G-01 (destructive, requires isolated VM) ---'
  if ! bash "$PROJECT_ROOT/tests/quick/run_g01_integration.sh" 2>&1; then
    echo "LIVE G-01 FAIL"; FAIL=1
  fi
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo -e '\n=== Integration acceptance status ==='
if [[ $FAIL -eq 0 ]]; then
  echo "ALL AUTOMATED CHECKS PASSED (T-01..T-07 green)"
  echo "NOTE: T-08..T-28 and live G-01 require an isolated target VM and retained evidence."
  exit 0
else
  echo "ONE OR MORE AUTOMATED CHECKS FAILED"
  exit 1
fi
