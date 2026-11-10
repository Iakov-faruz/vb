#!/usr/bin/env bash
# scripts/restore.sh
# Phase 5 - Restore with journal, validators, atomic restores, clock trust, G-01 gate
# SRS v4.5: Restores from backup, creates restore_journal.json before any change
# to block operations until recovery, validates backup, restores RuleFile and
# ttl.json atomically, deletes journal at end, with clock trust check.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
if [[ ! -d "$LIB_DIR" ]]; then
  LIB_DIR="$SCRIPT_DIR/../scripts/lib"
fi
if [[ ! -f "$LIB_DIR/config-reader.sh" ]]; then
  for cand in "/opt/usbguard-approval-manager/scripts/lib" "./scripts/lib" "$SCRIPT_DIR/lib"; do
    if [[ -f "$cand/config-reader.sh" ]]; then
      LIB_DIR="$cand"
      break
    fi
  done
fi

# shellcheck source=/dev/null
source "$LIB_DIR/config-reader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/lock.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/logger.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/result.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/validators.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/usbguard-policy.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/time-guards.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/journal.sh"

CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="$STATE_DIR/ttl.json"
CLOCK_STATE_FILE="$STATE_DIR/clock_state.json"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
BACKUP_BASE_DIR="${USBAM_BACKUP_BASE_DIR:-/var/backups/usbguard-approval-manager}"
STATE_LOCK_FILE="${USBAM_STATE_LOCK_FILE:-/run/lock/usbguard-approval-manager-state.lock}"
POLICY_LOCK_FILE="${USBAM_POLICY_LOCK_FILE:-/run/lock/usbguard-approval-manager-policy.lock}"
ATOMIC_WRITE_HELPER="$LIB_DIR/atomic-write.py"
AUDIT_WRITER="$LIB_DIR/audit_write.py"

RESTORE_ERROR=""
RESTORE_BACKUP_PATH=""
RESTORE_DRY_RUN=0
RESTORE_FORCE=0

restore_error() {
  RESTORE_ERROR="$1"
  printf 'restore: ERROR: %s\n' "$1" >&2
}

restore_fsync_dir() {
  local dir="$1"
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "$dir" 2>/dev/null || true
}

restore_atomic_copy() {
  local src="$1"
  local dst="$2"
  local dst_dir tmp_dst

  if [[ -L "$src" ]]; then
    restore_error "source is symlink: $src"
    return 1
  fi
  if [[ ! -f "$src" ]]; then
    restore_error "source not regular file: $src"
    return 1
  fi
  dst_dir="$(dirname -- "$dst")"
  if [[ -L "$dst_dir" ]]; then
    restore_error "dest dir is symlink: $dst_dir"
    return 1
  fi
  if [[ ! -d "$dst_dir" ]]; then
    if ! mkdir -p "$dst_dir"; then
      restore_error "mkdir dest dir failed $dst_dir"
      return 1
    fi
    chmod 700 "$dst_dir" 2>/dev/null || true
  fi
  tmp_dst="$dst_dir/.$(basename -- "$dst").tmp.$$.$RANDOM"
  if ! cp --no-dereference -p -- "$src" "$tmp_dst"; then
    rm -f -- "$tmp_dst"
    restore_error "cp failed $src -> $tmp_dst"
    return 1
  fi
  chmod 600 "$tmp_dst" || true
  # fsync file
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$tmp_dst" 2>/dev/null || true
  if ! mv -f -- "$tmp_dst" "$dst"; then
    rm -f -- "$tmp_dst"
    restore_error "mv $tmp_dst -> $dst failed"
    return 1
  fi
  chmod 600 "$dst" 2>/dev/null || true
  restore_fsync_dir "$dst_dir"
  return 0
}

restore_atomic_copy_folder() {
  local src_folder="$1"
  local dst_folder="$2"
  local dst_parent tmp_new old_backup

  if [[ -L "$src_folder" ]]; then
    restore_error "src folder is symlink: $src_folder"
    return 1
  fi
  if [[ ! -d "$src_folder" ]]; then
    restore_error "src folder not directory: $src_folder"
    return 1
  fi

  dst_parent="$(dirname -- "$dst_folder")"
  if [[ ! -d "$dst_parent" ]]; then
    if ! mkdir -p "$dst_parent"; then
      restore_error "mkdir parent $dst_parent failed"
      return 1
    fi
    chmod 700 "$dst_parent" 2>/dev/null || true
  fi

  tmp_new="$dst_parent/.$(basename -- "$dst_folder").new.$$.$RANDOM"
  old_backup="$dst_folder.old.$(date +%s).$$"

  if ! mkdir -p "$tmp_new"; then
    restore_error "mkdir tmp new $tmp_new failed"
    return 1
  fi
  chmod 700 "$tmp_new" || true

  # copy files securely, skip symlinks
  local entry
  for entry in "$src_folder"/*; do
    [[ -e "$entry" ]] || continue
    if [[ -L "$entry" ]]; then
      restore_error "skipping symlink in src backup folder: $entry"
      continue
    fi
    if [[ -f "$entry" ]]; then
      local base
      base="$(basename -- "$entry")"
      if ! cp --no-dereference -p -- "$entry" "$tmp_new/$base"; then
        rm -rf -- "$tmp_new"
        restore_error "copy $entry -> $tmp_new/$base failed"
        return 1
      fi
      chmod 600 "$tmp_new/$base" 2>/dev/null || true
      python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$tmp_new/$base" 2>/dev/null || true
    fi
  done
  restore_fsync_dir "$tmp_new"

  # backup old folder if exists
  if [[ -d "$dst_folder" ]]; then
    if ! mv -- "$dst_folder" "$old_backup"; then
      rm -rf -- "$tmp_new"
      restore_error "mv old folder $dst_folder -> $old_backup failed"
      return 1
    fi
    restore_fsync_dir "$dst_parent"
  fi

  if ! mv -- "$tmp_new" "$dst_folder"; then
    # try to restore old backup
    if [[ -d "$old_backup" ]]; then
      mv -- "$old_backup" "$dst_folder" 2>/dev/null || true
    fi
    rm -rf -- "$tmp_new"
    restore_error "mv new $tmp_new -> $dst_folder failed"
    return 1
  fi
  restore_fsync_dir "$dst_parent"
  # fsync restored folder
  restore_fsync_dir "$dst_folder"
  # remove old backup after successful restore
  rm -rf -- "$old_backup" 2>/dev/null || true
  restore_fsync_dir "$dst_parent"
  return 0
}

restore_release_locks() {
  journal_release_both_locks 2>/dev/null || true
}

restore_release_state_only() {
  journal_release_state_lock 2>/dev/null || true
}

validate_backup_dir() {
  local bdir="$1"
  if [[ -z "$bdir" ]]; then
    restore_error "backup path empty"
    return 1
  fi
  if [[ "$bdir" =~ [[:cntrl:]] ]]; then
    restore_error "backup path contains control chars"
    return 1
  fi
  if [[ -L "$bdir" ]]; then
    restore_error "backup path is symlink: $bdir"
    return 1
  fi
  if [[ ! -d "$bdir" ]]; then
    restore_error "backup dir not found: $bdir"
    return 1
  fi
  if [[ ! -f "$bdir/manifest.json" ]]; then
    restore_error "manifest.json missing in backup dir: $bdir"
    return 1
  fi
  if [[ -L "$bdir/manifest.json" ]]; then
    restore_error "manifest.json is symlink"
    return 1
  fi
  if ! jq -e . "$bdir/manifest.json" >/dev/null 2>&1; then
    restore_error "manifest.json not valid JSON"
    return 1
  fi
  local schema
  schema="$(jq -r '.schema_version // empty' "$bdir/manifest.json")"
  if [[ "$schema" != "1" ]]; then
    restore_error "manifest schema_version must be 1, got $schema"
    return 1
  fi
  # check correlation_id uuid
  local cid
  cid="$(jq -r '.correlation_id // empty' "$bdir/manifest.json")"
  if [[ -n "$cid" ]] && ! journal_is_uuid_v4 "$cid"; then
    restore_error "manifest correlation_id not UUID v4"
    return 1
  fi
  # if ttl.json exists in backup, validate it
  if [[ -f "$bdir/ttl.json" ]]; then
    if [[ -L "$bdir/ttl.json" ]]; then
      restore_error "backup ttl.json is symlink"
      return 1
    fi
    if ! validate_ttl_json "$bdir/ttl.json"; then
      restore_error "backup ttl.json invalid: $VALIDATORS_ERROR"
      return 1
    fi
  fi
  # clock_state.json if exists, basic JSON check
  if [[ -f "$bdir/clock_state.json" ]]; then
    if ! jq -e . "$bdir/clock_state.json" >/dev/null 2>&1; then
      restore_error "backup clock_state.json invalid JSON"
      return 1
    fi
  fi
  return 0
}

restore_check_clock_trust() {
  local backup_ttl="$1"
  # if backup has no non-expired records, clock trust not needed for restore?
  # But per task we must check clock trust
  if [[ ! -f "$backup_ttl" ]]; then
    return 0
  fi
  local has_records
  has_records="$(has_non_expired_records "$backup_ttl")"
  if [[ "$has_records" != "yes" ]]; then
    # no active records, no need for trusted clock, but still try to detect if possible
    return 0
  fi
  # has non-expired -> need trusted clock
  # use detect_clock_jump with current state file
  local clock_state_path="$CLOCK_STATE_FILE"
  if ! detect_clock_jump "$clock_state_path" "yes"; then
    local trust_status="$CLOCK_TRUST_STATUS"
    local detail_code="$CLOCK_TRUST_DETAIL_CODE"
    restore_error "clock not trusted for restore (has non-expired backup records): $trust_status $detail_code"
    return 9
  fi
  return 0
}

usage() {
  cat <<EOF
Usage: $0 --backup <path> [--dry-run] [--force] [--help]

Restore USBGuard Approval Manager from backup

Creates $RESTORE_JOURNAL_FILE before any change to block operations
until recovery, validates backup, restores RuleFile and ttl.json atomically.

Options:
  --backup <path>   Backup directory (full path or name under $BACKUP_BASE_DIR)
  --dry-run         Validate backup and show what would be restored, no changes
  --force           Allow restore even if journal exists or clock untrusted (use with caution)
  --help            Show this help

Exit codes:
  0 success
  1 operational failure
  7 validation / G-01 not verified
  9 recovery required / clock untrusted
  14 audit write failed

Environment:
  USBAM_CONFIG_PATH, USBAM_STATE_DIR, USBAM_BACKUP_BASE_DIR,
  USBAM_STATE_LOCK_FILE, USBAM_POLICY_LOCK_FILE

Security:
  - Requires G-01 verification (SEC-19)
  - Split-locking: state lock then policy lock
  - Journal blocks all operations until removed (EXIT 9)
  - Never calls block-device automatically
EOF
}

main() {
  local backup_arg=""
  while (( $# )); do
    case "$1" in
      --backup)
        backup_arg="${2:-}"
        shift 2
        ;;
      --dry-run)
        RESTORE_DRY_RUN=1
        shift
        ;;
      --force)
        RESTORE_FORCE=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown argument %s\n' "$1" >&2
        usage >&2
        exit 7
        ;;
    esac
  done

  if [[ -z "$backup_arg" ]]; then
    printf 'ERROR: --backup is required\n' >&2
    usage >&2
    exit 7
  fi
  if [[ "$backup_arg" =~ [[:cntrl:]] ]]; then
    printf 'ERROR: backup path contains control characters\n' >&2
    exit 7
  fi

  result_start

  # Load config - data-only, no source/eval
  if [[ -f "$CONFIG_PATH" ]]; then
    if ! load_config "$CONFIG_PATH"; then
      restore_error "config invalid"
      result_validation_failed "config invalid"
      result_print_json
      exit 7
    fi
  fi

  # G-01 mandatory gate
  if ! is_g01_verified; then
    restore_error "G-01 not verified - restore requires G-01 verification (SEC-19). Set USBAM_G01_VERIFIED=1 or create /var/lib/usbguard-approval-manager/g01-verified"
    result_validation_failed "G-01 not verified for restore"
    result_print_json
    exit 7
  fi

  # Resolve backup path: if not absolute, try under BACKUP_BASE_DIR
  local resolved_backup=""
  if [[ "$backup_arg" == /* ]]; then
    resolved_backup="$backup_arg"
  else
    if [[ -d "$BACKUP_BASE_DIR/$backup_arg" ]]; then
      resolved_backup="$BACKUP_BASE_DIR/$backup_arg"
    else
      # try to find latest matching prefix? For simplicity require absolute or name under base
      resolved_backup="$BACKUP_BASE_DIR/$backup_arg"
    fi
  fi
  RESTORE_BACKUP_PATH="$resolved_backup"

  if [[ -L "$resolved_backup" ]]; then
    restore_error "backup path is symlink: $resolved_backup"
    result_validation_failed "backup path is symlink"
    result_print_json
    exit 7
  fi

  if ! validate_backup_dir "$resolved_backup"; then
    result_validation_failed "backup validation failed: $RESTORE_ERROR"
    result_print_json
    exit 7
  fi

  log_info "restore: backup validated at $resolved_backup" 2>/dev/null || printf 'INFO: backup validated %s\n' "$resolved_backup"

  # Clock trust check before journal creation (read-only check)
  local backup_ttl_path="$resolved_backup/ttl.json"
  if [[ -f "$backup_ttl_path" ]]; then
    if ! restore_check_clock_trust "$backup_ttl_path"; then
      local rc=$?
      if (( rc == 9 )) && (( RESTORE_FORCE == 0 )); then
        result_recovery_required "clock not trusted for restore: $CLOCK_TRUST_STATUS $CLOCK_TRUST_DETAIL_CODE"
        result_print_json
        exit 9
      elif (( RESTORE_FORCE )); then
        log_error "restore: clock untrusted but --force overrides: $CLOCK_TRUST_STATUS" 2>/dev/null || true
        printf 'WARN: clock untrusted but --force used: %s\n' "$CLOCK_TRUST_STATUS" >&2
      fi
    fi
  fi

  if (( RESTORE_DRY_RUN )); then
    printf 'DRY-RUN: would restore from %s\n' "$resolved_backup"
    if [[ -f "$resolved_backup/manifest.json" ]]; then
      cat "$resolved_backup/manifest.json"
    fi
    # show what files would be restored
    if [[ -f "$resolved_backup/ttl.json" ]]; then
      local cnt
      cnt="$(jq '.records | length' "$resolved_backup/ttl.json" 2>/dev/null || echo 0)"
      printf 'DRY-RUN: ttl.json with %s records would be restored to %s\n' "$cnt" "$TTL_FILE"
    fi
    local current_rule_file="" current_rule_folder=""
    if get_persistent_policy_paths 2>/dev/null; then
      current_rule_file="${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}"
      current_rule_folder="${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}"
      printf 'DRY-RUN: current RuleFile=%s RuleFolder=%s\n' "${current_rule_file:-none}" "${current_rule_folder:-none}"
    fi
    result_success "dry-run validated backup $resolved_backup"
    result_print_json
    exit 0
  fi

  # Check journal exists before acquiring locks - if exists, block unless --force
  if journal_exists; then
    if (( RESTORE_FORCE == 0 )); then
      restore_error "restore journal already exists at $JOURNAL_FILE - previous restore may have crashed, recovery required"
      result_recovery_required "restore journal exists - recovery required"
      result_print_json
      exit 9
    else
      log_error "restore: journal exists but --force will overwrite" 2>/dev/null || true
    fi
  fi

  # Acquire state lock first (split locking order)
  trap 'restore_release_locks' EXIT INT TERM

  if ! journal_acquire_state_lock 5; then
    restore_error "unable to acquire state lock: $JOURNAL_ERROR"
    result_operation_failed "state lock acquisition failed"
    result_print_json
    exit 1
  fi

  # Re-check journal under state lock
  if journal_exists && (( RESTORE_FORCE == 0 )); then
    restore_release_locks
    trap - EXIT INT TERM
    restore_error "restore journal exists under lock - recovery required"
    result_recovery_required "journal exists under lock"
    result_print_json
    exit 9
  fi

  # Create journal BEFORE any change - this blocks other operations (stages.sh checks EXIT 9)
  if ! journal_create "$resolved_backup" "restore"; then
    restore_release_locks
    trap - EXIT INT TERM
    restore_error "failed to create restore journal: $JOURNAL_ERROR"
    result_operation_failed "journal creation failed"
    result_print_json
    exit 1
  fi

  local correlation_id
  correlation_id="$(journal_last_correlation_id)"
  if [[ -z "$correlation_id" ]]; then
    correlation_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo unknown)"
  fi
  RESULT_CORRELATION_ID="$correlation_id"

  log_info "restore: journal created at $JOURNAL_FILE correlation=$correlation_id" 2>/dev/null || true

  # Now acquire policy lock while still holding state lock (split-locking both)
  if ! journal_acquire_policy_lock 5; then
    # journal remains to block operations - recovery required
    restore_release_state_only
    trap - EXIT INT TERM
    restore_error "unable to acquire policy lock after journal creation - journal remains, recovery required: $JOURNAL_ERROR"
    result_recovery_required "policy lock failed after journal creation - journal preserved"
    result_print_json
    exit 9
  fi

  log_info "restore: both locks acquired" 2>/dev/null || true

  # Get current policy paths under locks
  if ! get_persistent_policy_paths; then
    # keep journal - recovery required
    restore_release_locks
    trap - EXIT INT TERM
    restore_error "policy source unavailable under locks: $USBAM_POLICY_ERROR_CODE"
    result_recovery_required "policy source unavailable under lock - journal preserved"
    result_print_json
    exit 9
  fi

  local current_rule_file="" current_rule_folder=""
  current_rule_file="${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}"
  current_rule_folder="${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}"

  # Re-validate backup under locks (TOCTOU protection) and check daemon?
  if ! validate_backup_dir "$resolved_backup"; then
    restore_release_locks
    trap - EXIT INT TERM
    result_validation_failed "backup invalid under lock: $RESTORE_ERROR - journal preserved for recovery"
    result_print_json
    exit 7
  fi

  # Check daemon status - must be running for policy verification but not fatal for file restore?
  if ! check_daemon_status; then
    if [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
      log_error "restore: daemon not running or IPC unavailable - proceeding with file restore but policy verification will be limited" 2>/dev/null || true
      # not fatal, but warn
    fi
  fi

  # --- Restore RuleFile ---
  local backup_manifest_rule_name
  backup_manifest_rule_name="$(jq -r '.files.rule_file.backup_name // empty' "$resolved_backup/manifest.json" 2>/dev/null || echo "")"
  local backup_rulefile_src=""
  if [[ -n "$backup_manifest_rule_name" && -f "$resolved_backup/$backup_manifest_rule_name" ]]; then
    backup_rulefile_src="$resolved_backup/$backup_manifest_rule_name"
  else
    # fallback: find first file that is not manifest, ttl, clock_state, and not dir RuleFolder
    local candidate
    for candidate in "$resolved_backup"/*; do
      [[ -f "$candidate" ]] || continue
      local b
      b="$(basename -- "$candidate")"
      case "$b" in
        manifest.json|ttl.json|clock_state.json) continue ;;
        *) backup_rulefile_src="$candidate"; break ;;
      esac
    done
  fi

  if [[ -n "$backup_rulefile_src" && -n "$current_rule_file" ]]; then
    if ! restore_atomic_copy "$backup_rulefile_src" "$current_rule_file"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "RuleFile restore failed - journal preserved"
      result_recovery_required "RuleFile restore failed - journal preserved at $JOURNAL_FILE"
      result_print_json
      exit 9
    fi
    log_info "restore: RuleFile restored $backup_rulefile_src -> $current_rule_file" 2>/dev/null || true
  else
    if [[ -n "$current_rule_file" ]]; then
      log_info "restore: no RuleFile in backup, skipping" 2>/dev/null || true
    fi
  fi

  # --- Restore RuleFolder ---
  local backup_rulefolder_src="$resolved_backup/RuleFolder"
  if [[ -d "$backup_rulefolder_src" && -n "$current_rule_folder" ]]; then
    if ! restore_atomic_copy_folder "$backup_rulefolder_src" "$current_rule_folder"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "RuleFolder restore failed - journal preserved"
      result_recovery_required "RuleFolder restore failed - journal preserved"
      result_print_json
      exit 9
    fi
    log_info "restore: RuleFolder restored $backup_rulefolder_src -> $current_rule_folder" 2>/dev/null || true
  elif [[ -d "$backup_rulefolder_src" ]]; then
    # current system may not have RuleFolder configured but backup does - warn
    log_info "restore: backup contains RuleFolder but current config has no RuleFolder - skipping" 2>/dev/null || true
  fi

  # --- Restore ttl.json atomically via atomic-write.py ---
  if [[ -f "$resolved_backup/ttl.json" ]]; then
    local ttl_content
    if ! ttl_content="$(cat "$resolved_backup/ttl.json")"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "failed to read backup ttl.json"
      result_recovery_required "ttl.json read failed - journal preserved"
      result_print_json
      exit 9
    fi
    # Ensure state dir exists
    if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "state dir creation failed"
      result_recovery_required "state dir unavailable - journal preserved"
      result_print_json
      exit 9
    fi
    chmod 700 "$STATE_DIR" 2>/dev/null || true

    if [[ ! -r "$ATOMIC_WRITE_HELPER" ]]; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "atomic-write helper missing"
      result_recovery_required "atomic-write helper missing - journal preserved"
      result_print_json
      exit 9
    fi

    if ! python3 "$ATOMIC_WRITE_HELPER" --file "$TTL_FILE" --data "$ttl_content"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "atomic write ttl.json failed"
      result_recovery_required "ttl.json atomic write failed - journal preserved"
      result_print_json
      exit 9
    fi
    chmod 600 "$TTL_FILE" 2>/dev/null || true
    restore_fsync_dir "$STATE_DIR"

    if ! validate_ttl_json "$TTL_FILE"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "restored ttl.json invalid: $VALIDATORS_ERROR"
      result_recovery_required "restored ttl.json invalid - journal preserved"
      result_print_json
      exit 9
    fi
    log_info "restore: ttl.json restored" 2>/dev/null || true
  else
    log_info "restore: backup has no ttl.json, skipping" 2>/dev/null || true
  fi

  # --- Restore clock_state.json atomically if exists ---
  if [[ -f "$resolved_backup/clock_state.json" ]]; then
    local clock_content
    if ! clock_content="$(cat "$resolved_backup/clock_state.json")"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "failed to read backup clock_state.json"
      result_recovery_required "clock_state.json read failed - journal preserved"
      result_print_json
      exit 9
    fi
    if ! python3 "$ATOMIC_WRITE_HELPER" --file "$CLOCK_STATE_FILE" --data "$clock_content"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "atomic write clock_state.json failed"
      result_recovery_required "clock_state.json write failed - journal preserved"
      result_print_json
      exit 9
    fi
    chmod 600 "$CLOCK_STATE_FILE" 2>/dev/null || true
    restore_fsync_dir "$STATE_DIR"
    log_info "restore: clock_state.json restored" 2>/dev/null || true
  fi

  # Validate final state
  if [[ -f "$TTL_FILE" ]]; then
    if ! validate_ttl_json "$TTL_FILE"; then
      restore_release_locks
      trap - EXIT INT TERM
      restore_error "final ttl.json invalid after restore: $VALIDATORS_ERROR"
      result_recovery_required "final validation failed - journal preserved"
      result_print_json
      exit 9
    fi
  fi

  # Success path - delete journal before releasing locks (journal deletion under locks ensures no race)
  if ! journal_delete "$JOURNAL_FILE"; then
    restore_release_locks
    trap - EXIT INT TERM
    restore_error "failed to delete journal after successful restore - manual deletion required but restore considered successful"
    # We have restored files, but journal deletion failed - this is still recovery_required because journal blocks operations
    result_recovery_required "restore succeeded but journal deletion failed - manual recovery needed"
    result_print_json
    exit 9
  fi

  log_info "restore: journal deleted after successful restore" 2>/dev/null || true

  # Release both locks
  restore_release_locks
  trap - EXIT INT TERM

  # Audit
  local audit_failed=0
  if [[ -r "$AUDIT_WRITER" ]]; then
    if ! python3 "$AUDIT_WRITER" \
      --action "restore" \
      --policy-result "applied" \
      --correlation-id "$correlation_id" \
      --details "restore from $resolved_backup completed"; then
      log_error "restore: audit write failed" 2>/dev/null || true
      audit_failed=1
    fi
  else
    if declare -F log_audit >/dev/null 2>&1; then
      if ! log_audit "restore" "applied" "$correlation_id" "restore from $resolved_backup completed"; then
        audit_failed=1
      fi
    fi
  fi

  if declare -F log_info >/dev/null 2>&1; then
    log_info "restore completed from $resolved_backup correlation_id=$correlation_id" 2>/dev/null || true
  fi

  if (( audit_failed )); then
    result_policy_applied_audit_failed "restore completed from $resolved_backup but audit failed, journal removed"
    result_print_json
    exit 14
  fi

  result_success "restore completed from $resolved_backup"
  result_print_json
  exit 0
}

main "$@"
