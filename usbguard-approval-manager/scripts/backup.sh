#!/usr/bin/env bash
# scripts/backup.sh
# Phase 5 - Backup with journal awareness, split-locking, atomic-write, audit
# SRS v4.5: Creates backup of RuleFile, RuleFolder, ttl.json, clock_state.json
# to /var/backups/usbguard-approval-manager/ with timestamp,
# keeps BACKUP_KEEP versions, uses atomic-write, locking, audit, result.sh JSON
#
# --- הסבר בעברית ---
# גיבוי שלב 5 עם מודעות יומן, נעילת פיצול, כתיבה אטומית ו-logs audit.
# יוצר גיבוי של RuleFile, RuleFolder, ttl.json, clock_state.json
# לתיקיית /var/backups/usbguard-approval-manager/ עם תג timestamp.
# שומר BACKUP_KEEP גרסאות, משתמש בכתיבה אטומית, נעילות, audit ו-result.sh JSON.
# תוכנת כך שגיבוי לא ישנה את מדיניות ה-USBGuard הקיימת אלא רק יעתיק נתונים.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
if [[ ! -d "$LIB_DIR" ]]; then
  # fallback when called from repo root or different layout
  LIB_DIR="$SCRIPT_DIR/../scripts/lib"
fi
if [[ ! -d "$LIB_DIR" ]]; then
  LIB_DIR="$(cd -- "$SCRIPT_DIR" && pwd)/lib"
fi
# Also support final location /opt style
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

BACKUP_ERROR=""
BACKUP_LAST_DIR=""
BACKUP_CORRELATION_ID=""

backup_error() {
  BACKUP_ERROR="$1"
  printf 'backup: ERROR: %s\n' "$1" >&2
}

backup_fsync_dir() {
  local dir="$1"
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "$dir" 2>/dev/null || true
}

backup_ensure_dir() {
  local dir="$1"
  local mode="${2:-700}"
  if [[ -z "$dir" ]]; then
    backup_error "ensure dir path empty"
    return 1
  fi
  if [[ "$dir" != /* ]]; then
    backup_error "dir must be absolute: $dir"
    return 1
  fi
  if [[ -L "$dir" ]]; then
    backup_error "dir is symlink - refusing: $dir"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    if ! mkdir -p "$dir"; then
      backup_error "unable to create dir $dir"
      return 1
    fi
  fi
  if ! chmod "$mode" "$dir" 2>/dev/null; then
    backup_error "chmod $mode failed for $dir"
    return 1
  fi
  backup_fsync_dir "$(dirname -- "$dir")"
  return 0
}

backup_generate_ids() {
  local epoch utc short_uuid

  if ! epoch="$(date +%s)" || [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    backup_error "unable to get epoch"
    return 1
  fi
  utc="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%d-%H%M%S 2>/dev/null || printf '%s' "$epoch")"
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    short_uuid="$(head -c 8 /proc/sys/kernel/random/uuid | tr -d '-')"
    # better: full uuid first 8
    if command -v cut >/dev/null 2>&1; then
      short_uuid="$(cut -d'-' -f1 /proc/sys/kernel/random/uuid 2>/dev/null || echo "$epoch")"
    fi
  else
    short_uuid="$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])" 2>/dev/null || echo "$epoch")"
  fi
  BACKUP_CORRELATION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")"
  printf '%s %s %s %s\n' "$epoch" "$utc" "$short_uuid" "$BACKUP_CORRELATION_ID"
}

backup_sha256_file() {
  local file="$1"
  if [[ ! -f "$file" || -L "$file" ]]; then
    printf 'missing\n'
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" 2>/dev/null | awk '{print $1}' || printf 'error\n'
  else
    python3 -c "import hashlib,sys; h=hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest(); print(h)" "$file" 2>/dev/null || printf 'error\n'
  fi
}

backup_copy_file_secure() {
  local src="$1"
  local dst="$2"
  local dst_dir
  dst_dir="$(dirname -- "$dst")"
  if [[ -L "$src" ]]; then
    backup_error "source is symlink refusing: $src"
    return 1
  fi
  if [[ ! -f "$src" ]]; then
    backup_error "source not regular file: $src"
    return 1
  fi
  if ! backup_ensure_dir "$dst_dir" 700; then
    return 1
  fi
  local tmp_dst
  tmp_dst="$dst_dir/.$(basename -- "$dst").tmp.$$.$RANDOM"
  if ! cp --no-dereference -p -- "$src" "$tmp_dst"; then
    backup_error "cp failed $src -> $tmp_dst"
    rm -f -- "$tmp_dst"
    return 1
  fi
  if ! chmod 600 "$tmp_dst"; then
    rm -f -- "$tmp_dst"
    backup_error "chmod 600 tmp failed"
    return 1
  fi
  # fsync file
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$tmp_dst" 2>/dev/null || true
  if ! mv -f -- "$tmp_dst" "$dst"; then
    rm -f -- "$tmp_dst"
    backup_error "mv tmp to final failed"
    return 1
  fi
  chmod 600 "$dst" || true
  backup_fsync_dir "$dst_dir"
  return 0
}

backup_copy_folder_secure() {
  local src_folder="$1"
  local dst_folder="$2"
  if [[ -L "$src_folder" ]]; then
    backup_error "RuleFolder source is symlink: $src_folder"
    return 1
  fi
  if [[ ! -d "$src_folder" ]]; then
    backup_error "RuleFolder not directory: $src_folder"
    return 1
  fi
  if ! backup_ensure_dir "$dst_folder" 700; then
    return 1
  fi
  local entry
  local copied=0
  for entry in "$src_folder"/*; do
    [[ -e "$entry" ]] || continue
    if [[ -L "$entry" ]]; then
      log_info "backup: skipping symlink in RuleFolder: $entry" 2>/dev/null || printf 'INFO: skipping symlink %s\n' "$entry"
      continue
    fi
    if [[ -f "$entry" ]]; then
      local base
      base="$(basename -- "$entry")"
      if backup_copy_file_secure "$entry" "$dst_folder/$base"; then
        copied=$((copied+1))
      else
        return 1
      fi
    fi
  done
  # fsync folder
  backup_fsync_dir "$dst_folder"
  # return 0 even if empty folder
  return 0
}

backup_prune_old() {
  local keep="$1"
  local base_dir="$2"
  if [[ ! "$keep" =~ ^[0-9]+$ ]] || (( keep < 1 )); then
    backup_error "invalid keep value $keep"
    return 1
  fi
  if [[ ! -d "$base_dir" ]]; then
    return 0
  fi
  # list dirs sorted lexical (timestamp sortable)
  local -a dirs
  mapfile -t dirs < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' 2>/dev/null | sort || ls -1 "$base_dir" 2>/dev/null | sort | while read -r n; do printf '%s/%s\n' "$base_dir" "$n"; done)
  local count=${#dirs[@]}
  if (( count <= keep )); then
    return 0
  fi
  local to_delete=$((count - keep))
  local i d
  for ((i=0; i<to_delete; i++)); do
    d="${dirs[i]}"
    # safety: must contain manifest.json and must be inside base_dir
    if [[ "$d" != "$base_dir"/* ]]; then
      continue
    fi
    if [[ -f "$d/manifest.json" ]]; then
      log_info "backup: pruning old backup $d" 2>/dev/null || true
      rm -rf -- "$d"
      backup_fsync_dir "$base_dir"
    fi
  done
  return 0
}

backup_release_locks() {
  journal_release_both_locks 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage: $0 [--help]

Backup USBGuard Approval Manager state and policy

Creates backup of RuleFile, RuleFolder, ttl.json, clock_state.json
to $BACKUP_BASE_DIR/<timestamp>_<uuid>

Options:
  --help          Show this help

Exit codes:
  0 success
  1 operational failure
  7 validation failure
  9 recovery required (restore journal exists)
  14 audit write failed

Environment:
  USBAM_CONFIG_PATH, USBAM_STATE_DIR, USBAM_BACKUP_BASE_DIR,
  USBAM_STATE_LOCK_FILE, USBAM_POLICY_LOCK_FILE
EOF
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --help)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown argument %s\n' "$arg" >&2
        usage >&2
        exit 7
        ;;
    esac
  done

  result_start

  # Load config if exists - data-only via config-reader, no source/eval
  local backup_keep="5"
  if [[ -f "$CONFIG_PATH" ]]; then
    if ! load_config "$CONFIG_PATH"; then
      backup_error "config invalid at $CONFIG_PATH"
      result_validation_failed "config invalid"
      result_print_json
      exit 7
    fi
    if get_config BACKUP_KEEP >/dev/null 2>&1; then
      backup_keep="$(get_config BACKUP_KEEP)"
    fi
  fi
  if [[ ! "$backup_keep" =~ ^[0-9]+$ ]] || (( backup_keep < 1 || backup_keep > 100 )); then
    backup_keep="5"
  fi

  # Check restore journal before any operation - if exists block
  if [[ -f "$RESTORE_JOURNAL_FILE" ]]; then
    backup_error "restore journal exists at $RESTORE_JOURNAL_FILE - recovery required, blocking backup"
    result_recovery_required "restore journal exists - recovery required"
    result_print_json
    exit 9
  fi
  if ! journal_check_and_block "$RESTORE_JOURNAL_FILE"; then
    local rc=$?
    if (( rc == 9 )); then
      result_recovery_required "restore journal exists"
      result_print_json
      exit 9
    fi
  fi

  # Setup trap for locks release
  trap 'backup_release_locks' EXIT INT TERM

  # Acquire split locks - state first, then policy to avoid deadlock
  if ! journal_acquire_both_locks 5; then
    backup_error "unable to acquire state+policy locks (backup)"
    result_operation_failed "lock acquisition failed: $JOURNAL_ERROR"
    result_print_json
    exit 1
  fi

  log_info "backup: locks acquired state=$JOURNAL_STATE_LOCK_FILE policy=$JOURNAL_POLICY_LOCK_FILE" 2>/dev/null || true

  # Validate ttl.json if exists
  if [[ -f "$TTL_FILE" ]]; then
    if ! validate_ttl_json "$TTL_FILE"; then
      backup_release_locks
      trap - EXIT INT TERM
      backup_error "ttl.json invalid: $VALIDATORS_ERROR - recovery required"
      result_recovery_required "ttl.json invalid: $VALIDATORS_ERROR_CODE"
      result_print_json
      exit 9
    fi
  fi

  # Get persistent policy paths
  if ! get_persistent_policy_paths; then
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "policy source unavailable: $USBAM_POLICY_ERROR_CODE"
    result_operation_failed "policy source unavailable"
    result_print_json
    exit 1
  fi

  local rule_file="" rule_folder=""
  if [[ -n "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]+x}" ]]; then
    rule_file="${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]}"
  fi
  if [[ -n "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]+x}" ]]; then
    rule_folder="${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]}"
  fi

  if [[ -z "$rule_file" && -z "$rule_folder" ]]; then
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "no RuleFile or RuleFolder configured"
    result_operation_failed "policy source unconfigured"
    result_print_json
    exit 1
  fi

  # Ensure backup base dir exists with secure mode
  if ! backup_ensure_dir "$BACKUP_BASE_DIR" 700; then
    backup_release_locks
    trap - EXIT INT TERM
    result_operation_failed "unable to create backup base dir"
    result_print_json
    exit 1
  fi

  # Generate timestamp and correlation id
  local gen_line epoch utc short_uuid correlation_id
  gen_line="$(backup_generate_ids)"
  read -r epoch utc short_uuid correlation_id <<< "$gen_line"
  if [[ -z "$epoch" || -z "$utc" || -z "$correlation_id" ]]; then
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "failed to generate timestamp/correlation"
    result_operation_failed "id generation failed"
    result_print_json
    exit 1
  fi
  # override global correlation id for result.sh to use same id
  RESULT_CORRELATION_ID="$correlation_id"

  local backup_dir_name="${utc}_${short_uuid}"
  # sanitize: allow only alnum, T, Z, -, _, :
  # replace : with -
  backup_dir_name="${backup_dir_name//:/-}"
  local backup_dir="$BACKUP_BASE_DIR/$backup_dir_name"

  if [[ -e "$backup_dir" ]]; then
    backup_dir="${backup_dir}_$RANDOM"
  fi

  if ! mkdir -p "$backup_dir"; then
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "mkdir backup dir failed $backup_dir"
    result_operation_failed "mkdir backup dir failed"
    result_print_json
    exit 1
  fi
  chmod 700 "$backup_dir" || true
  BACKUP_LAST_DIR="$backup_dir"

  # Copy files with secure handling
  local rule_file_backup_name="" rule_file_sha="" rule_file_size=""
  local ttl_sha="" ttl_size="" clock_sha="" clock_size=""
  local rule_folder_copied="0"

  if [[ -n "$rule_file" ]]; then
    local rf_base
    rf_base="$(basename -- "$rule_file")"
    rule_file_backup_name="$rf_base"
    if ! backup_copy_file_secure "$rule_file" "$backup_dir/$rf_base"; then
      rm -rf -- "$backup_dir"
      backup_release_locks
      trap - EXIT INT TERM
      result_operation_failed "RuleFile backup copy failed"
      result_print_json
      exit 1
    fi
    rule_file_sha="$(backup_sha256_file "$backup_dir/$rf_base")"
    rule_file_size="$(stat -c '%s' "$backup_dir/$rf_base" 2>/dev/null || echo 0)"
  fi

  if [[ -n "$rule_folder" ]]; then
    if ! backup_copy_folder_secure "$rule_folder" "$backup_dir/RuleFolder"; then
      rm -rf -- "$backup_dir"
      backup_release_locks
      trap - EXIT INT TERM
      result_operation_failed "RuleFolder backup copy failed"
      result_print_json
      exit 1
    fi
    # count files
    rule_folder_copied="$(find "$backup_dir/RuleFolder" -type f 2>/dev/null | wc -l | tr -d ' ')"
  fi

  if [[ -f "$TTL_FILE" ]]; then
    if ! backup_copy_file_secure "$TTL_FILE" "$backup_dir/ttl.json"; then
      rm -rf -- "$backup_dir"
      backup_release_locks
      trap - EXIT INT TERM
      result_operation_failed "ttl.json backup copy failed"
      result_print_json
      exit 1
    fi
    ttl_sha="$(backup_sha256_file "$backup_dir/ttl.json")"
    ttl_size="$(stat -c '%s' "$backup_dir/ttl.json" 2>/dev/null || echo 0)"
  else
    ttl_sha="missing"
    ttl_size="0"
  fi

  if [[ -f "$CLOCK_STATE_FILE" ]]; then
    if ! backup_copy_file_secure "$CLOCK_STATE_FILE" "$backup_dir/clock_state.json"; then
      rm -rf -- "$backup_dir"
      backup_release_locks
      trap - EXIT INT TERM
      result_operation_failed "clock_state.json backup copy failed"
      result_print_json
      exit 1
    fi
    clock_sha="$(backup_sha256_file "$backup_dir/clock_state.json")"
    clock_size="$(stat -c '%s' "$backup_dir/clock_state.json" 2>/dev/null || echo 0)"
  else
    clock_sha="missing"
    clock_size="0"
  fi

  # Get ttl records count
  local ttl_records_count=0
  if [[ -f "$backup_dir/ttl.json" ]]; then
    ttl_records_count="$(jq '.records | length' "$backup_dir/ttl.json" 2>/dev/null || echo 0)"
    if [[ ! "$ttl_records_count" =~ ^[0-9]+$ ]]; then
      ttl_records_count=0
    fi
  fi

  local hostname
  hostname="$(hostname 2>/dev/null || echo unknown)"
  local uid
  uid="$(id -u 2>/dev/null || echo 0)"
  local pid
  pid="$$"

  # Build manifest JSON atomically via jq then atomic-write.py
  local manifest_json
  if ! manifest_json="$(jq -n \
    --argjson schema_version 1 \
    --argjson backup_epoch "$epoch" \
    --arg backup_timestamp "$utc" \
    --arg correlation_id "$correlation_id" \
    --arg hostname "$hostname" \
    --argjson pid "$pid" \
    --argjson uid "$uid" \
    --argjson backup_keep "$backup_keep" \
    --arg source_rule_file "${rule_file:-}" \
    --arg source_rule_folder "${rule_folder:-}" \
    --arg rule_file_backup_name "${rule_file_backup_name:-}" \
    --arg rule_file_sha "${rule_file_sha:-missing}" \
    --argjson rule_file_size "${rule_file_size:-0}" \
    --arg ttl_sha "${ttl_sha:-missing}" \
    --argjson ttl_size "${ttl_size:-0}" \
    --arg clock_sha "${clock_sha:-missing}" \
    --argjson clock_size "${clock_size:-0}" \
    --argjson ttl_records_count "$ttl_records_count" \
    --argjson rule_folder_copied "${rule_folder_copied:-0}" \
    '{
      schema_version: $schema_version,
      backup_epoch: $backup_epoch,
      backup_timestamp: $backup_timestamp,
      correlation_id: $correlation_id,
      hostname: $hostname,
      pid: $pid,
      creator_uid: $uid,
      backup_keep: $backup_keep,
      source_rule_file: $source_rule_file,
      source_rule_folder: $source_rule_folder,
      ttl_records_count: $ttl_records_count,
      files: {
        rule_file: {
          original_path: $source_rule_file,
          backup_name: $rule_file_backup_name,
          sha256: $rule_file_sha,
          size: $rule_file_size
        },
        rule_folder: {
          original_path: $source_rule_folder,
          backup_dir: "RuleFolder",
          file_count: $rule_folder_copied
        },
        ttl_json: {
          backup_name: "ttl.json",
          sha256: $ttl_sha,
          size: $ttl_size
        },
        clock_state_json: {
          backup_name: "clock_state.json",
          sha256: $clock_sha,
          size: $clock_size
        }
      }
    }')"; then
    rm -rf -- "$backup_dir"
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "failed to build manifest json"
    result_operation_failed "manifest build failed"
    result_print_json
    exit 1
  fi

  # Atomic write manifest.json
  if [[ ! -r "$ATOMIC_WRITE_HELPER" ]]; then
    rm -rf -- "$backup_dir"
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "atomic-write helper missing $ATOMIC_WRITE_HELPER"
    result_operation_failed "atomic-write helper missing"
    result_print_json
    exit 1
  fi

  if ! python3 "$ATOMIC_WRITE_HELPER" --file "$backup_dir/manifest.json" --data "$manifest_json"; then
    rm -rf -- "$backup_dir"
    backup_release_locks
    trap - EXIT INT TERM
    backup_error "atomic write manifest failed"
    result_operation_failed "manifest atomic write failed"
    result_print_json
    exit 1
  fi
  chmod 600 "$backup_dir/manifest.json" 2>/dev/null || true
  backup_fsync_dir "$backup_dir"
  backup_fsync_dir "$BACKUP_BASE_DIR"

  # Prune old backups respecting BACKUP_KEEP
  if ! backup_prune_old "$backup_keep" "$BACKUP_BASE_DIR"; then
    log_error "backup: pruning failed but backup succeeded" 2>/dev/null || true
    # not fatal
  fi

  # Release locks before audit (audit doesn't need lock)
  backup_release_locks
  trap - EXIT INT TERM

  # Audit - best effort
  local audit_failed=0
  if [[ -r "$AUDIT_WRITER" ]]; then
    if ! python3 "$AUDIT_WRITER" \
      --action "backup" \
      --policy-result "not_applicable" \
      --correlation-id "$correlation_id" \
      --details "backup created at $backup_dir ttl_records=$ttl_records_count keep=$backup_keep"; then
      log_error "backup: audit write failed" 2>/dev/null || true
      audit_failed=1
    fi
  else
    # fallback via logger.sh log_audit if audit_write missing
    if declare -F log_audit >/dev/null 2>&1; then
      if ! log_audit "backup" "not_applicable" "$correlation_id" "backup created at $backup_dir"; then
        audit_failed=1
      fi
    fi
  fi

  # Also operational log
  if declare -F log_info >/dev/null 2>&1; then
    log_info "backup created at $backup_dir correlation_id=$correlation_id" 2>/dev/null || true
  fi

  if (( audit_failed )); then
    result_policy_applied_audit_failed "backup created at $backup_dir but audit failed"
    result_print_json
    exit 14
  fi

  result_success "backup created at $backup_dir"
  # add detail as item for better observability (optional)
  # result_add_item would need batch but we just print simple success
  result_print_json
  exit 0
}

main "$@"
