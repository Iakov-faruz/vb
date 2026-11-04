#!/usr/bin/env bash
# Validate, stage, diff, and explicitly approve a schema-version-1 rules import.
#
# --- הסבר בעברית ---
# אימות, שלב, דיפי ואישור מפורש של ייבוא חוקים בגרסת סכימה 1.
# תוכנת לאמת, לשלב, להציג הבדלים (diff) ולאשר מפורשות ייבוא של חוקי USBGuard.
# פועלת לפי גרסת סכימה 1 ומבטיחה תאימות עם מבנה חוקים SRS v4.5.
# תומכת בהצגת הבדלים בין חוקים קיימים לחוקים חדשים לאישור.
#
# תלויה: lib/validators.sh, lib/lifecycle.sh, lib/result.sh, python3

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PYTHON3="${PYTHON3:-python3}"
CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
CLOCK_STATE_FILE="${USBAM_CLOCK_STATE_FILE:-$STATE_DIR/clock_state.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"
USBAM_DAEMON_CONFIG_PATH="${USBAM_DAEMON_CONFIG_PATH:-/etc/usbguard/usbguard-daemon.conf}"
IMPORT_FILE=""

usage() {
  printf 'Usage: %s --file EXPORT.json [--help]\n' "$0"
}

while (( $# )); do
  case "$1" in
    --file)
      if (( $# < 2 )) || [[ -z "$2" || -n "$IMPORT_FILE" ]]; then
        usage >&2
        exit 7
      fi
      IMPORT_FILE="$2"
      shift 2
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
if [[ -z "$IMPORT_FILE" ]]; then
  usage >&2
  exit 7
fi
if (( EUID != 0 )); then
  printf 'import-rules: ERROR: root privileges are required\n' >&2
  exit 1
fi

source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lifecycle.sh"
source "$LIB_DIR/logger.sh"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
CLOCK_STATE_FILE="${USBAM_CLOCK_STATE_FILE:-$STATE_DIR/clock_state.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"

if [[ -L "$IMPORT_FILE" || ! -f "$IMPORT_FILE" || ! -r "$IMPORT_FILE" ]]; then
  printf 'import-rules: ERROR: import file is missing, unsafe, or unreadable\n' >&2
  exit 1
fi
work_dir="$(mktemp -d)" || {
  printf 'import-rules: ERROR: unable to create private staging directory\n' >&2
  exit 1
}
chmod 700 "$work_dir" || {
  rmdir "$work_dir" 2>/dev/null || true
  printf 'import-rules: ERROR: unable to secure staging directory\n' >&2
  exit 1
}
cleanup() {
  rm -rf -- "$work_dir"
  if (( LOCK_HELD )); then
    lock_release
  fi
}
trap cleanup EXIT

if ! "$PYTHON3" "$USBAM_LIFECYCLE_HELPER" validate-export \
  --file "$IMPORT_FILE" > "$work_dir/import.json"; then
  exit 1
fi
chmod 600 "$work_dir/import.json" || exit 1
if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
  lifecycle_error "restore journal exists; import is blocked until recovery"
  exit 9
fi
if [[ -e "$CONFIG_PATH" || -L "$CONFIG_PATH" ]]; then
  if [[ -L "$CONFIG_PATH" || ! -f "$CONFIG_PATH" || ! -r "$CONFIG_PATH" ]] ||
    ! load_config "$CONFIG_PATH"; then
    printf 'import-rules: ERROR: application configuration is invalid\n' >&2
    exit 1
  fi
fi
if ! lifecycle_collect_export_json >/dev/null; then
  printf 'import-rules: ERROR: persistent policy sources are unsafe or invalid\n' >&2
  exit 9
fi
if ! check_daemon_status ||
  [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
  printf 'import-rules: ERROR: USBGuard daemon and IPC must be available\n' >&2
  exit 9
fi
if ! validate_ttl_json "$TTL_FILE"; then
  printf 'import-rules: ERROR: ttl.json is invalid\n' >&2
  exit 9
fi
if ! list_active_rules; then
  printf 'import-rules: ERROR: unable to read active rules\n' >&2
  exit 9
fi

declare -a ACTIVE_RULE_MAP=()
for active_line in "${USBAM_ACTIVE_RULES[@]}"; do
  if usbguard_parse_rule_line "$active_line" active_id active_rule; then
    ACTIVE_RULE_MAP+=("$active_rule")
  fi
done
mapfile -t IMPORT_PERMANENT < <(jq -r '.permanent_rules[]' "$work_dir/import.json")
mapfile -t IMPORT_TTL_RULES < <(jq -r '.ttl_records[].rule' "$work_dir/import.json")
mapfile -t IMPORT_TTL_EXPIRIES < <(jq -r '.ttl_records[].expires_at' "$work_dir/import.json")
for rule in "${IMPORT_PERMANENT[@]}" "${IMPORT_TTL_RULES[@]}"; do
  if ! usbguard_validate_rule "$rule" || [[ "$rule" != allow\ * ]] ||
    [[ "$(usbguard_canonicalize_rule "$rule")" != "$rule" ]]; then
    printf 'import-rules: ERROR: import contains an invalid or non-canonical allow rule\n' >&2
    exit 7
  fi
done
declare -a TO_ADD_PERMANENT=()
declare -a TO_ADD_TTL_RULES=()
declare -a TO_ADD_TTL_EXPIRIES=()
declare -a SEEN_IMPORTED_RULES=()
declare -a SEEN_IMPORTED_KINDS=()
current_epoch="$(date +%s)" || {
  printf 'import-rules: ERROR: unable to read current time\n' >&2
  exit 1
}

rule_is_active() {
  local item
  for item in "${ACTIVE_RULE_MAP[@]}"; do
    [[ "$item" == "$1" ]] && return 0
  done
  return 1
}

rule_kind_index() {
  local index
  for ((index = 0; index < ${#SEEN_IMPORTED_RULES[@]}; index++)); do
    if [[ "${SEEN_IMPORTED_RULES[$index]}" == "$1" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

for rule in "${IMPORT_PERMANENT[@]}"; do
  if rule_kind_index "$rule" >/dev/null; then
    printf 'import-rules: ERROR: rule appears more than once in import\n' >&2
    exit 1
  fi
  SEEN_IMPORTED_RULES+=("$rule")
  SEEN_IMPORTED_KINDS+=(permanent)
  if rule_is_active "$rule"; then
    if usbguard_rule_is_persistent "$rule"; then
      printf 'UNCHANGED permanent: %s\n' "$rule"
      continue
    fi
    printf 'import-rules: ERROR: active rule is not verified as permanent: %s\n' "$rule" >&2
    exit 9
  fi
  TO_ADD_PERMANENT+=("$rule")
  printf 'ADD permanent: %s\n' "$rule"
done

for ((index = 0; index < ${#IMPORT_TTL_RULES[@]}; index++)); do
  rule="${IMPORT_TTL_RULES[$index]}"
  expires_at="${IMPORT_TTL_EXPIRIES[$index]}"
  if existing_index="$(rule_kind_index "$rule")"; then
    if [[ "${SEEN_IMPORTED_KINDS[$existing_index]}" == permanent ]]; then
      printf 'import-rules: ERROR: a rule cannot be both permanent and temporary\n' >&2
      exit 1
    fi
    printf 'import-rules: ERROR: rule appears more than once in TTL records\n' >&2
    exit 1
  fi
  SEEN_IMPORTED_RULES+=("$rule")
  SEEN_IMPORTED_KINDS+=(temporary)
  if (( expires_at <= current_epoch )); then
    printf 'SKIPPED - expired: %s\n' "$rule"
    continue
  fi
  if usbguard_rule_is_persistent "$rule"; then
    printf 'import-rules: ERROR: temporary rule overlaps persistent policy: %s\n' "$rule" >&2
    exit 7
  else
    persistence_status=$?
    if (( persistence_status != 1 )); then
      printf 'import-rules: ERROR: unable to verify persistent policy for TTL rule\n' >&2
      exit 9
    fi
  fi
  if rule_is_active "$rule"; then
    if jq -e --arg rule "$rule" --argjson expiry "$expires_at" '
      any(.records[]; .rule == $rule and .expires_at == $expiry and .status == "active")
    ' "$TTL_FILE" >/dev/null 2>&1; then
      printf 'UNCHANGED temporary: %s\n' "$rule"
      continue
    fi
    printf 'import-rules: ERROR: matching active rule lacks the expected TTL record: %s\n' \
      "$rule" >&2
    exit 9
  fi
  TO_ADD_TTL_RULES+=("$rule")
  TO_ADD_TTL_EXPIRIES+=("$expires_at")
  printf 'ADD temporary (expires %s): %s\n' "$expires_at" "$rule"
done

if (( ${#TO_ADD_PERMANENT[@]} == 0 && ${#TO_ADD_TTL_RULES[@]} == 0 )); then
  printf 'import-rules: no changes required\n'
  exit 0
fi
if ! is_g01_verified; then
  printf 'import-rules: ERROR: G-01 verification is required before policy changes\n' >&2
  exit 7
fi
if [[ ! -t 0 ]]; then
  printf 'import-rules: ERROR: changes require an interactive confirmation\n' >&2
  exit 7
fi
printf 'Apply the staged import? [y/N] '
IFS= read -r answer || exit 7
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
  printf 'import-rules: cancelled; no changes made\n'
  exit 0
fi

before_rules="$(printf '%s\n' "${USBAM_ACTIVE_RULES[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
if [[ -f "$TTL_FILE" ]]; then
  before_ttl="$(sha256sum -- "$TTL_FILE" | awk '{print $1}')" || exit 9
else
  before_ttl="missing"
fi
if ! lock_acquire 5; then
  printf 'import-rules: ERROR: unable to acquire the state lock\n' >&2
  exit 9
fi
if ! lifecycle_require_no_journal; then
  exit 9
fi
if ! check_daemon_status || ! list_active_rules; then
  printf 'import-rules: ERROR: USBGuard state became unavailable\n' >&2
  exit 9
fi
after_rules="$(printf '%s\n' "${USBAM_ACTIVE_RULES[@]}" | LC_ALL=C sort | sha256sum | awk '{print $1}')"
if [[ "$before_rules" != "$after_rules" ]]; then
  printf 'import-rules: ERROR: policy changed while awaiting confirmation; re-run the import\n' >&2
  exit 9
fi
if [[ -f "$TTL_FILE" ]]; then
  after_ttl="$(sha256sum -- "$TTL_FILE" | awk '{print $1}')" || exit 9
else
  after_ttl="missing"
fi
if [[ "$before_ttl" != "$after_ttl" ]]; then
  printf 'import-rules: ERROR: TTL state changed while awaiting confirmation; re-run the import\n' >&2
  exit 9
fi
if ! validate_ttl_json "$TTL_FILE"; then
  printf 'import-rules: ERROR: ttl.json changed to an invalid state\n' >&2
  exit 9
fi

for rule in "${TO_ADD_PERMANENT[@]}"; do
  if ! stages_approve_permanent "$rule"; then
    printf 'import-rules: ERROR: permanent rule import stopped after a partial batch\n' >&2
    exit 1
  fi
  correlation_id="$( "$PYTHON3" -c 'import uuid; print(uuid.uuid4())' )" || exit 1
  if ! log_audit "import_permanent" "applied" "$correlation_id" "validated rule imported"; then
    printf 'import-rules: ERROR: permanent policy applied but Audit failed\n' >&2
    exit 14
  fi
done
for ((index = 0; index < ${#TO_ADD_TTL_RULES[@]}; index++)); do
  rule="${TO_ADD_TTL_RULES[$index]}"
  expires_at="${TO_ADD_TTL_EXPIRIES[$index]}"
  if ! managed_id="$(stages_import_temporary "$rule" "$expires_at")"; then
    printf 'import-rules: ERROR: temporary rule import stopped after a partial batch\n' >&2
    exit 1
  fi
  correlation_id="$(jq -r --arg id "$managed_id" \
    '.records[] | select(.managed_id == $id) | .correlation_id' "$TTL_FILE")"
  if [[ -z "$correlation_id" || "$correlation_id" == "null" ]] ||
    ! log_audit "import_temporary" "applied" "$correlation_id" "validated TTL rule imported"; then
    printf 'import-rules: ERROR: temporary policy applied but Audit failed\n' >&2
    exit 14
  fi
done
printf 'import-rules: import completed\n'
