#!/usr/bin/env bash
# Validate and restore one Phase 5 archive, or idempotently recover a journal.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PYTHON3="${PYTHON3:-python3}"
CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"
USBAM_DAEMON_CONFIG_PATH="${USBAM_DAEMON_CONFIG_PATH:-/etc/usbguard/usbguard-daemon.conf}"
BACKUP_FILE=""
RECOVER=0

usage() {
  printf 'Usage: %s --backup ARCHIVE.tar.gz [--help]\n       %s --recover [--help]\n' "$0" "$0"
}

while (( $# )); do
  case "$1" in
    --backup)
      if (( $# < 2 )) || [[ -z "$2" || -n "$BACKUP_FILE" ]]; then
        usage >&2
        exit 7
      fi
      BACKUP_FILE="$2"
      shift 2
      ;;
    --recover)
      if (( RECOVER != 0 )); then
        usage >&2
        exit 7
      fi
      RECOVER=1
      shift
      ;;
    --help)
      if (( $# != 1 )); then
        usage >&2
        exit 7
      fi
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 7
      ;;
  esac
done
if { (( RECOVER == 1 )) && [[ -n "$BACKUP_FILE" ]]; } ||
  { (( RECOVER == 0 )) && [[ -z "$BACKUP_FILE" ]]; }; then
  usage >&2
  exit 7
fi
if (( EUID != 0 )); then
  printf 'restore-rules: ERROR: root privileges are required\n' >&2
  exit 1
fi

source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lifecycle.sh"
source "$LIB_DIR/logger.sh"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
ROLLBACK_ROOT="$STATE_DIR/restore-rollback"

case "$CONFIG_PATH:$TTL_FILE:$RESTORE_JOURNAL_FILE" in
  *00-system.rules*)
    printf 'restore-rules: ERROR: restore paths must not target protected system policy\n' >&2
    exit 7
    ;;
esac
if [[ -L "$CONFIG_PATH" || ( -e "$CONFIG_PATH" && ! -f "$CONFIG_PATH" ) ]]; then
  printf 'restore-rules: ERROR: application configuration path is unsafe\n' >&2
  exit 1
fi
if [[ -f "$CONFIG_PATH" ]] && ! load_config "$CONFIG_PATH"; then
  printf 'restore-rules: ERROR: current application configuration is invalid\n' >&2
  exit 1
fi
for protected_state_file in "$CONFIG_PATH" "$TTL_FILE"; do
  if [[ -e "$protected_state_file" || -L "$protected_state_file" ]]; then
    if [[ -L "$protected_state_file" || ! -f "$protected_state_file" ]] ||
      [[ "$(stat -c '%u:%a' -- "$protected_state_file")" != "0:600" ]]; then
      printf 'restore-rules: ERROR: config and TTL files must be root-owned mode 0600\n' >&2
      exit 9
    fi
  fi
done

if ! lock_acquire 5; then
  printf 'restore-rules: ERROR: unable to acquire the state lock\n' >&2
  exit 9
fi
if [[ -L "$STATE_DIR" ]]; then
  printf 'restore-rules: ERROR: state directory must not be a symbolic link\n' >&2
  exit 9
fi
if [[ ! -d "$STATE_DIR" ]]; then
  mkdir -m 700 -p -- "$STATE_DIR" || {
    printf 'restore-rules: ERROR: unable to create state directory\n' >&2
    exit 9
  }
fi
chmod 700 -- "$STATE_DIR" || exit 9

if ! check_daemon_status && [[ "$USBAM_DAEMON_STATUS" != "stopped" ]]; then
  printf 'restore-rules: ERROR: unable to prove that USBGuard is stopped\n' >&2
  exit 9
fi
if [[ "$USBAM_DAEMON_STATUS" != "stopped" ]]; then
  printf 'restore-rules: ERROR: daemon must be stopped before restore or recovery\n' >&2
  exit 9
fi
if ! get_persistent_policy_paths; then
  printf 'restore-rules: ERROR: persistent policy paths are unavailable\n' >&2
  exit 9
fi
RULE_FILE="${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}"
RULE_FOLDER="${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}"
if [[ -z "$RULE_FILE" ]]; then
  printf 'restore-rules: ERROR: safe restore requires a configured RuleFile\n' >&2
  exit 9
fi

work_parent="$(mktemp -d "$STATE_DIR/.restore-work.XXXXXX")" || {
  printf 'restore-rules: ERROR: unable to create private staging directory\n' >&2
  exit 1
}
chmod 700 "$work_parent" || {
  rmdir "$work_parent" 2>/dev/null || true
  printf 'restore-rules: ERROR: unable to secure staging directory\n' >&2
  exit 1
}
cleanup() {
  rm -rf -- "$work_parent"
  if (( LOCK_HELD )); then
    lock_release
  fi
}
trap cleanup EXIT

targets_file="$work_parent/targets.json"
if ! jq -cn --arg config "$CONFIG_PATH" --arg ttl "$TTL_FILE" --arg policy "$RULE_FILE" \
  '{config:$config,ttl:$ttl,policy:$policy}' > "$targets_file"; then
  printf 'restore-rules: ERROR: unable to build the restore allowlist\n' >&2
  exit 1
fi
chmod 600 "$targets_file" || exit 1

if (( RECOVER )); then
  if ! "$PYTHON3" "$USBAM_LIFECYCLE_HELPER" restore-recover \
    --journal "$RESTORE_JOURNAL_FILE" \
    --rollback-root "$ROLLBACK_ROOT" \
    --targets "$targets_file"; then
    exit 9
  fi
  printf 'restore-rules: previous state recovered and verified\n'
  exit 0
fi

if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
  lifecycle_error "restore journal already exists; use --recover"
  exit 9
fi
if [[ -L "$BACKUP_FILE" || ! -f "$BACKUP_FILE" || ! -r "$BACKUP_FILE" ]]; then
  printf 'restore-rules: ERROR: backup archive is missing, unsafe, or unreadable\n' >&2
  exit 1
fi
if ! is_g01_verified; then
  printf 'restore-rules: ERROR: G-01 verification is required before policy restore\n' >&2
  exit 7
fi
if ! "$PYTHON3" "$USBAM_LIFECYCLE_HELPER" backup-extract \
  --backup "$BACKUP_FILE" --staging "$work_parent/extracted"; then
  exit 1
fi

backup_config="$work_parent/extracted/config/approval-manager.conf"
backup_ttl="$work_parent/extracted/state/ttl.json"
backup_export="$work_parent/extracted/policy/export.json"
staged_rule_file="$work_parent/extracted/policy/rules.conf"
if ! load_config "$backup_config"; then
  printf 'restore-rules: ERROR: archived application configuration is invalid\n' >&2
  exit 1
fi
if ! validate_ttl_json "$backup_ttl"; then
  printf 'restore-rules: ERROR: archived ttl.json is invalid\n' >&2
  exit 1
fi
if [[ -e "$TTL_FILE" || -L "$TTL_FILE" ]]; then
  if [[ -L "$TTL_FILE" || ! -f "$TTL_FILE" || ! -r "$TTL_FILE" ]] ||
    ! validate_ttl_json "$TTL_FILE"; then
    printf 'restore-rules: ERROR: current ttl.json is invalid or unsafe\n' >&2
    exit 9
  fi
fi

if [[ -e "$RULE_FILE" || -L "$RULE_FILE" ]]; then
  if [[ -L "$RULE_FILE" || ! -f "$RULE_FILE" || ! -r "$RULE_FILE" ]]; then
    printf 'restore-rules: ERROR: current RuleFile is unsafe or unreadable\n' >&2
    exit 9
  fi
  if [[ "$(stat -c '%u' -- "$RULE_FILE")" != "0" ]] ||
    (( (8#$(stat -c '%a' -- "$RULE_FILE") & 0022) != 0 )); then
    printf 'restore-rules: ERROR: current RuleFile ownership or permissions are unsafe\n' >&2
    exit 9
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ [[:cntrl:]] ]] || ! usbguard_validate_rule "$line" ||
      [[ "$line" != allow\ * ]]; then
      printf 'restore-rules: ERROR: current RuleFile has policy outside the approved allowlist\n' >&2
      exit 9
    fi
  done < "$RULE_FILE"
fi

if [[ -n "$RULE_FOLDER" ]]; then
  if [[ "$(stat -c '%u' -- "$RULE_FOLDER")" != "0" ]] ||
    (( (8#$(stat -c '%a' -- "$RULE_FOLDER") & 0022) != 0 )); then
    printf 'restore-rules: ERROR: RuleFolder ownership or permissions are unsafe\n' >&2
    exit 9
  fi
  folder_entries="$work_parent/rule-folder.entries"
  if ! find "$RULE_FOLDER" -mindepth 1 -maxdepth 1 -print0 > "$folder_entries"; then
    printf 'restore-rules: ERROR: unable to inspect RuleFolder\n' >&2
    exit 9
  fi
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" ]]; then
      printf 'restore-rules: ERROR: RuleFolder contains a symbolic link\n' >&2
      exit 9
    fi
    if [[ "${entry##*/}" != "00-system.rules" ]]; then
      printf 'restore-rules: ERROR: safe restore cannot replace a non-system RuleFolder entry\n' >&2
      exit 9
    fi
    [[ -f "$entry" ]] || {
      printf 'restore-rules: ERROR: protected system rule entry is not a regular file\n' >&2
      exit 9
    }
  done < "$folder_entries"
fi

restore_snapshot() {
  local target snapshot
  local -a targets=("$CONFIG_PATH" "$TTL_FILE" "$RULE_FILE" "$USBAM_DAEMON_CONFIG_PATH")
  for target in "${targets[@]}"; do
    if [[ -L "$target" ]]; then
      return 1
    elif [[ -e "$target" ]]; then
      [[ -f "$target" ]] || return 1
      snapshot="$(sha256sum -- "$target" | awk '{print $1}')" || return 1
      printf '%s:%s\n' "$target" "$snapshot"
    else
      printf '%s:missing\n' "$target"
    fi
  done
  if [[ -n "$RULE_FOLDER" ]]; then
    snapshot="$(find "$RULE_FOLDER" -mindepth 1 -maxdepth 1 \
      -printf '%f:%y:%s:%T@\n' | LC_ALL=C sort | sha256sum | awk '{print $1}')" || return 1
    printf 'RuleFolder:%s\n' "$snapshot"
  fi
}
before_snapshot="$(restore_snapshot)" || {
  printf 'restore-rules: ERROR: unable to establish a safe pre-restore snapshot\n' >&2
  exit 9
}

: > "$staged_rule_file"
while IFS= read -r rule; do
  [[ -n "$rule" ]] || continue
  if ! usbguard_validate_rule "$rule" || [[ "$rule" != allow\ * ]]; then
    printf 'restore-rules: ERROR: archive contains an invalid permanent rule\n' >&2
    exit 1
  fi
  printf '%s\n' "$rule" >> "$staged_rule_file" || exit 1
done < <(jq -r '.permanent_rules[]' "$backup_export")
chmod 600 "$staged_rule_file" || exit 1

printf 'Restore diff:\n'
printf '  config: replace with validated archived configuration\n'
printf '  RuleFile: replace approved permanent allow rules (%s rules)\n' \
  "$(wc -l < "$staged_rule_file" | tr -d '[:space:]')"
active_ttl_count="$(jq '[.records[] | select(.status == "active")] | length' "$backup_ttl")"
printf '  TTL: %s archived active record(s) become recovery_required; no temporary rule is applied\n' \
  "$active_ttl_count"
if [[ ! -t 0 ]]; then
  printf 'restore-rules: ERROR: restore requires interactive confirmation\n' >&2
  exit 7
fi
printf 'Apply this restore? [y/N] '
IFS= read -r answer || exit 7
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
  printf 'restore-rules: cancelled; no changes made\n'
  exit 0
fi
if ! check_daemon_status && [[ "$USBAM_DAEMON_STATUS" != "stopped" ]]; then
  printf 'restore-rules: ERROR: unable to re-verify stopped daemon after confirmation\n' >&2
  exit 9
fi
if [[ "$USBAM_DAEMON_STATUS" != "stopped" ]] || ! is_g01_verified; then
  printf 'restore-rules: ERROR: daemon state or G-01 verification changed after confirmation\n' >&2
  exit 9
fi
if ! get_persistent_policy_paths ||
  [[ "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}" != "$RULE_FILE" ||
    "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}" != "$RULE_FOLDER" ]]; then
  printf 'restore-rules: ERROR: configured policy paths changed after confirmation\n' >&2
  exit 9
fi
after_snapshot="$(restore_snapshot)" || {
  printf 'restore-rules: ERROR: unable to recheck restore targets\n' >&2
  exit 9
}
if [[ "$before_snapshot" != "$after_snapshot" ]]; then
  printf 'restore-rules: ERROR: restore targets changed while awaiting confirmation\n' >&2
  exit 9
fi

if ! "$PYTHON3" "$USBAM_LIFECYCLE_HELPER" restore-apply \
  --journal "$RESTORE_JOURNAL_FILE" \
  --rollback-root "$ROLLBACK_ROOT" \
  --targets "$targets_file" \
  --staging "$work_parent/extracted"; then
  exit 9
fi
correlation_id="$( "$PYTHON3" -c 'import uuid; print(uuid.uuid4())' )" || exit 9
if ! log_audit "restore_rules" "applied" "$correlation_id" "validated archive restored"; then
  printf 'restore-rules: ERROR: restore applied but Audit failed\n' >&2
  exit 14
fi
printf 'restore-rules: restore completed; restored TTL records require explicit recovery\n'
