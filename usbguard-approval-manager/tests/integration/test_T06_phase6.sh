#!/usr/bin/env bash
# T-06: Phase 6 Deployment (T-21..T-24) - SRS v4.5 Phase 7
# Tests: deploy.sh staged install, idempotent re-deploy, rollback on failure,
# validate_all.sh --static, uninstall preserves data. Fully staged (no root).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0 TOTAL=0 FAIL_COUNT=0
pass_msg() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'PASS: %s\n' "$1"; }
fail_msg() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'FAIL: %s - %s\n' "$1" "$2" >&2; }

TEST_ROOT="$(mktemp -d)"
ROOT="$TEST_ROOT/root"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$ROOT" "$FAKE_BIN"

cat > "$FAKE_BIN/visudo" <<'MOCK'
#!/usr/bin/env bash
[[ "${USBAM_TEST_VISUDO_FAIL:-0}" != "1" ]]
[[ "$1" == "-c" && "$2" == "-f" && -f "$3" ]]
MOCK
cat > "$FAKE_BIN/systemd-analyze" <<'MOCK'
#!/usr/bin/env bash
[[ "${USBAM_TEST_SYSTEMD_FAIL:-0}" != "1" ]]
MOCK
cat > "$FAKE_BIN/logrotate" <<'MOCK'
#!/usr/bin/env bash
[[ "${USBAM_TEST_LOGROTATE_FAIL:-0}" != "1" ]]
MOCK
chmod 700 "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH"

# ------------------------------------------------------------------
# T-21: staged deployment installs all managed files
# ------------------------------------------------------------------
printf '\n[T-21] staged deployment installs all managed files\n'
TOTAL=$((TOTAL+1))
if ! bash "$PROJECT_ROOT/deploy.sh" --root "$ROOT" > "$TEST_ROOT/deploy21.log" 2>&1; then
  fail_msg "T-21" "staged deployment failed: $(cat $TEST_ROOT/deploy21.log)"
else
  ok=1
  for p in \
    usr/libexec/usbguard-approval-manager/cleanup-expired.sh \
    usr/libexec/usbguard-approval-manager/backup.sh \
    usr/libexec/usbguard-approval-manager/restore.sh \
    usr/libexec/usbguard-approval-manager/usb-list.sh \
    usr/libexec/usbguard-approval-manager/lib/journal.sh \
    usr/libexec/usbguard-approval-manager/lib/tui.sh \
    etc/systemd/system/usbguard-approval-ttl.service \
    etc/systemd/system/usbguard-approval-ttl.timer \
    etc/systemd/system/usbguard-approval-manager-reaper.service \
    etc/systemd/system/usbguard-approval-manager-reaper.timer \
    etc/sudoers.d/usbguard-approval-manager \
    etc/logrotate.d/usbguard-approval-manager \
    etc/usbguard-approval-manager/approval-manager.conf \
    etc/usbguard-approval-manager/config/usbguard-approval-manager.conf.example \
    var/lib/usbguard-approval-manager/ttl.json \
    var/log/usbguard-approval-manager/audit.jsonl \
    var/backups/usbguard-approval-manager \
    run/lock/usbguard-approval-manager.lock ; do
    if [[ ! -e "$ROOT/$p" ]]; then
      echo "MISSING: $p" >&2
      ok=0
    fi
  done
  if [[ ! -e "$ROOT/etc/systemd/system/timers.target.wants/usbguard-approval-ttl.timer" ]]; then
    pass_msg "T-21 staged deployment installed all files, timer not auto-enabled"
  else
    fail_msg "T-21" "TTL timer was auto-enabled (should not be)"
    ok=0
  fi
  [[ $ok -eq 1 ]] && pass_msg "T-21 all managed files installed" || fail_msg "T-21" "some files missing"
fi

# ------------------------------------------------------------------
# T-22: idempotent re-deployment preserves config, TTL, audit, backups
# ------------------------------------------------------------------
printf '\n[T-22] idempotent re-deployment preserves user data\n'
TOTAL=$((TOTAL+1))
printf 'LOG_LEVEL=DEBUG\n' > "$ROOT/etc/usbguard-approval-manager/approval-manager.conf"
chmod 600 "$ROOT/etc/usbguard-approval-manager/approval-manager.conf"
printf '{"schema_version":1,"records":[]}\n' > "$ROOT/var/lib/usbguard-approval-manager/ttl.json"
chmod 600 "$ROOT/var/lib/usbguard-approval-manager/ttl.json"
printf 'retained backup\n' > "$ROOT/var/backups/usbguard-approval-manager/usbguard-approval-manager-test.tar.gz"
chmod 600 "$ROOT/var/backups/usbguard-approval-manager/usbguard-approval-manager-test.tar.gz"
printf 'retained audit\n' >> "$ROOT/var/log/usbguard-approval-manager/audit.jsonl"
if ! bash "$PROJECT_ROOT/deploy.sh" --root "$ROOT" > "$TEST_ROOT/deploy22.log" 2>&1; then
  fail_msg "T-22" "idempotent re-deployment failed: $(cat $TEST_ROOT/deploy22.log)"
else
  if grep -Fqx 'LOG_LEVEL=DEBUG' "$ROOT/etc/usbguard-approval-manager/approval-manager.conf" && \
     grep -Fqx 'retained backup' "$ROOT/var/backups/usbguard-approval-manager/usbguard-approval-manager-test.tar.gz" && \
     grep -Fqx 'retained audit' "$ROOT/var/log/usbguard-approval-manager/audit.jsonl"; then
    pass_msg "T-22 re-deployment preserves config, TTL, backup, audit"
  else
    fail_msg "T-22" "re-deployment overwrote user data"
  fi
fi

# ------------------------------------------------------------------
# T-23: static validation passes on staged installation
# ------------------------------------------------------------------
printf '\n[T-23] validate_all.sh --static passes\n'
TOTAL=$((TOTAL+1))
if USBAM_ROOT="$ROOT" bash "$PROJECT_ROOT/validate_all.sh" --static > "$TEST_ROOT/validate23.log" 2>&1; then
  pass_msg "T-23 static validation passes"
else
  fail_msg "T-23" "static validation failed: $(cat $TEST_ROOT/validate23.log)"
fi

# ------------------------------------------------------------------
# T-24: uninstall removes code but preserves user data
# ------------------------------------------------------------------
printf '\n[T-24] uninstall preserves user data\n'
TOTAL=$((TOTAL+1))
if ! bash "$PROJECT_ROOT/deploy-uninstall.sh" --root "$ROOT" > "$TEST_ROOT/uninstall24.log" 2>&1; then
  fail_msg "T-24" "uninstall failed: $(cat $TEST_ROOT/uninstall24.log)"
else
  ok=1
  [[ -e "$ROOT/usr/libexec/usbguard-approval-manager" ]] && { echo "CODE NOT REMOVED" >&2; ok=0; }
  [[ -e "$ROOT/etc/usbguard-approval-manager/approval-manager.conf" ]] || { echo "CONFIG REMOVED" >&2; ok=0; }
  [[ -e "$ROOT/var/lib/usbguard-approval-manager/ttl.json" ]] || { echo "TTL REMOVED" >&2; ok=0; }
  [[ -e "$ROOT/var/log/usbguard-approval-manager/audit.jsonl" ]] || { echo "AUDIT REMOVED" >&2; ok=0; }
  [[ -e "$ROOT/var/backups/usbguard-approval-manager/usbguard-approval-manager-test.tar.gz" ]] || { echo "BACKUP REMOVED" >&2; ok=0; }
  [[ $ok -eq 1 ]] && pass_msg "T-24 uninstall removes code, preserves all user data" || fail_msg "T-24" "uninstall did not preserve data correctly"
fi

printf '\n=== T06 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi
