#!/usr/bin/env bash
# USBGuard Approval Manager - USBGuard Policy Adapte
# Phase 2 Full Implementation - SRS v4.5 Approved 28.10.2026
# This adapter is the ONLY layer that talks to USBGuard.
# Read-only operations are safe everywhere. Write operations require G-01 verification
# and must only run in an isolated lab VM with USB passthrough and recovery route.

if [[ -z "${USBAM_USB_POLICY_LOADED+x}" ]]; then
  declare -g USBAM_POLICY_STDOUT=""
  declare -g USBAM_POLICY_STDERR=""
  declare -g USBAM_POLICY_ERROR_CODE=""
  declare -g USBAM_POLICY_VERSION=""
  declare -g USBAM_DAEMON_CONFIG_PATH="/etc/usbguard/usbguard-daemon.conf"
  declare -ga USBAM_BLOCKED_DEVICES=()
  declare -ga USBAM_ACTIVE_RULES=()
  declare -gA USBAM_PERSISTENT_POLICY_PATHS=()
  declare -g USBAM_DAEMON_STATUS="unknown"
  declare -g USBAM_IPC_STATUS="unknown"
  declare -g USBAM_LAST_RULE_ID=""
  declare -g USBAM_MATCHED_RULE_ID=""
  declare -g USBAM_LAST_DEVICE_ID=""
  declare -gr USBAM_USB_POLICY_LOADED=1
fi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lock.sh"

usbguard_policy_error() {
  printf 'usbguard-policy: ERROR: %s\n' "$1" >&2
}

usbguard_policy_require_lock() {
  if (( LOCK_HELD == 0 )) || [[ "$LOCK_OWNER_PID" != "$BASHPID" ]]; then
    usbguard_policy_error "policy mutations require the global lock for the complete operation"
    USBAM_POLICY_ERROR_CODE="lock_not_held"
    return 1
  fi
}

usbguard_policy_timeout() {
  if declare -F get_config >/dev/null 2>&1; then
    get_config IPC_TIMEOUT_SECONDS
  else
    printf '%s\n' "${IPC_TIMEOUT_SECONDS:-5}"
  fi
}

# Internal runner - shared logic for read-only and write
_usbguard_run() {
  local timeout_seconds temp_dir status
  USBAM_POLICY_STDOUT=""
  USBAM_POLICY_STDERR=""
  USBAM_POLICY_ERROR_CODE=""

  if ! timeout_seconds="$(usbguard_policy_timeout)" ||
    [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    usbguard_policy_error "IPC_TIMEOUT_SECONDS must be a positive integer"
    USBAM_POLICY_ERROR_CODE="invalid_timeout"
    return 1
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    usbguard_policy_error "the timeout utility is unavailable"
    USBAM_POLICY_ERROR_CODE="timeout_unavailable"
    return 1
  fi
  if ! command -v usbguard >/dev/null 2>&1; then
    usbguard_policy_error "the usbguard CLI is unavailable"
    USBAM_POLICY_ERROR_CODE="usbguard_unavailable"
    return 1
  fi
  if ! temp_dir="$(mktemp -d)"; then
    usbguard_policy_error "unable to create a private command-output directory"
    USBAM_POLICY_ERROR_CODE="temporary_storage_unavailable"
    return 1
  fi

  if timeout --foreground --signal=TERM --kill-after=1s \
    "${timeout_seconds}s" usbguard "$@" \
    > "$temp_dir/stdout" 2> "$temp_dir/stderr"; then
    status=0
  else
    status=$?
  fi

  USBAM_POLICY_STDOUT="$(<"$temp_dir/stdout")"
  USBAM_POLICY_STDERR="$(<"$temp_dir/stderr")"
  if ! rm -rf -- "$temp_dir"; then
    usbguard_policy_error "unable to remove private command-output files"
    USBAM_POLICY_ERROR_CODE="temporary_storage_cleanup_failed"
    return 1
  fi

  if (( status == 0 )); then
    return 0
  fi
  if (( status == 124 || status == 137 )); then
    USBAM_POLICY_ERROR_CODE="command_timeout"
    usbguard_policy_error "USBGuard query exceeded ${timeout_seconds}s"
    return 1
  fi
  USBAM_POLICY_ERROR_CODE="command_failed"
  usbguard_policy_error "USBGuard query failed with exit status $status"
  return 1
}

usbguard_policy_run_readonly() {
  if (( $# == 0 )); then
    usbguard_policy_error "a read-only USBGuard subcommand is required"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  case "$1:$#" in
    --version:1|list-rules:1|list-devices:1)
      ;;
    list-devices:2)
      if [[ "$2" != "--blocked" ]]; then
        usbguard_policy_error "unsupported read-only USBGuard query"
        USBAM_POLICY_ERROR_CODE="invalid_command"
        return 1
      fi
      ;;
    *)
      usbguard_policy_error "unsupported read-only USBGuard query"
      USBAM_POLICY_ERROR_CODE="invalid_command"
      return 1
      ;;
  esac
  _usbguard_run "$@"
}

usbguard_policy_run_write() {
  if (( $# == 0 )); then
    usbguard_policy_error "a USBGuard write subcommand is required"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  case "$1" in
    allow-device|block-device|append-rule|remove-rule)
      ;;
    *)
      usbguard_policy_error "unsupported USBGuard write operation: $1"
      USBAM_POLICY_ERROR_CODE="invalid_command"
      return 1
      ;;
  esac
  if ! is_g01_verified; then
    usbguard_policy_error "policy changes require a verified G-01 evidence marker"
    USBAM_POLICY_ERROR_CODE="g01_not_verified"
    return 1
  fi
  if ! usbguard_policy_require_lock; then
    return 1
  fi
  _usbguard_run "$@"
}

usbguard_policy_parse_records() {
  local output="$1"
  local -n records_ref="$2"
  local line
  local -a parsed=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*[0-9]+: ]]; then
      usbguard_policy_error "USBGuard returned an unrecognized record"
      USBAM_POLICY_ERROR_CODE="invalid_command_output"
      return 1
    fi
    parsed+=("$line")
  done <<< "$output"

  records_ref=("${parsed[@]}")
}

usbguard_canonicalize_rule() {
  local rule="$1"
  # Trim leading/trailing whitespace, preserve internal
  rule="${rule#"${rule%%[![:space:]]*}"}"
  rule="${rule%"${rule##*[![:space:]]}"}"
  printf '%s' "$rule"
}

usbguard_hash_rule() {
  local rule="$1"
  local canonical
  canonical="$(usbguard_canonicalize_rule "$rule")"
  if ! command -v sha256sum >/dev/null 2>&1; then
    # Fallback to python3
    python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())" "$canonical"
  else
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
  fi
}

usbguard_parse_rule_line() {
  local line="$1"
  local id_var="$2"
  local rule_var="$3"
  if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*(.*)$ ]]; then
    local id="${BASH_REMATCH[1]}"
    local rule="${BASH_REMATCH[2]}"
    rule="$(usbguard_canonicalize_rule "$rule")"
    printf -v "$id_var" '%s' "$id"
    printf -v "$rule_var" '%s' "$rule"
    return 0
  fi
  usbguard_policy_error "invalid rule line format: $line"
  USBAM_POLICY_ERROR_CODE="invalid_command_output"
  return 1
}

usbguard_validate_device_id() {
  local device_id="$1"
  if [[ ! "$device_id" =~ ^[0-9]+$ ]]; then
    usbguard_policy_error "device ID must be a non-negative integer, got '$device_id'"
    USBAM_POLICY_ERROR_CODE="invalid_device_id"
    return 1
  fi
  return 0
}

usbguard_validate_rule() {
  local rule="$1"
  if [[ -z "$rule" ]]; then
    usbguard_policy_error "rule must not be empty"
    USBAM_POLICY_ERROR_CODE="invalid_rule"
    return 1
  fi
  if [[ "$rule" =~ [[:cntrl:]] ]]; then
    usbguard_policy_error "rule contains control characters"
    USBAM_POLICY_ERROR_CODE="invalid_rule"
    return 1
  fi
  if [[ "$rule" == *"00-system.rules"* ]]; then
    usbguard_policy_error "rule attempts to reference protected 00-system.rules"
    USBAM_POLICY_ERROR_CODE="protected_policy"
    return 1
  fi
  local canonical
  canonical="$(usbguard_canonicalize_rule "$rule")"
  if [[ ! "$canonical" =~ ^(allow|block|reject)[[:space:]] ]]; then
    usbguard_policy_error "rule must start with allow, block or reject"
    USBAM_POLICY_ERROR_CODE="invalid_rule"
    return 1
  fi
  return 0
}

usbguard_extract_id_pattern() {
  local rule="$1"
  # Extract id VID:PID if present
  if [[ "$rule" =~ id[[:space:]]+([0-9a-fA-F]{4}:[0-9a-fA-F]{4}) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf ''
  return 0
}

# --- Read-only API (unchanged behavior, must pass existing tests) ---

get_usbguard_version() {
  USBAM_POLICY_VERSION=""
  if (( $# != 0 )); then
    usbguard_policy_error "get_usbguard_version accepts no arguments"
    return 1
  fi
  if ! usbguard_policy_run_readonly --version; then
    return 1
  fi
  if [[ -z "$USBAM_POLICY_STDOUT" ]]; then
    usbguard_policy_error "USBGuard returned an empty version"
    USBAM_POLICY_ERROR_CODE="empty_version"
    return 1
  fi
  USBAM_POLICY_VERSION="$USBAM_POLICY_STDOUT"
  printf '%s\n' "$USBAM_POLICY_VERSION"
}

list_blocked_devices() {
  if (( $# != 0 )); then
    usbguard_policy_error "list_blocked_devices accepts no arguments"
    return 1
  fi
  USBAM_BLOCKED_DEVICES=()
  if ! usbguard_policy_run_readonly list-devices --blocked; then
    return 1
  fi
  usbguard_policy_parse_records "$USBAM_POLICY_STDOUT" USBAM_BLOCKED_DEVICES
}

list_active_rules() {
  if (( $# != 0 )); then
    usbguard_policy_error "list_active_rules accepts no arguments"
    return 1
  fi
  USBAM_ACTIVE_RULES=()
  if ! usbguard_policy_run_readonly list-rules; then
    return 1
  fi
  usbguard_policy_parse_records "$USBAM_POLICY_STDOUT" USBAM_ACTIVE_RULES
}

get_active_rules() {
  list_active_rules "$@"
}

get_persistent_policy_paths() {
  local raw_line line key value line_numbe
  local rule_file=""
  local rule_folder=""

  USBAM_PERSISTENT_POLICY_PATHS=()
  USBAM_POLICY_ERROR_CODE=""
  if (( $# != 0 )); then
    usbguard_policy_error "get_persistent_policy_paths accepts no arguments"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  if [[ -L "$USBAM_DAEMON_CONFIG_PATH" ||
    ! -f "$USBAM_DAEMON_CONFIG_PATH" ||
    ! -r "$USBAM_DAEMON_CONFIG_PATH" ]]; then
    usbguard_policy_error "USBGuard daemon configuration is unavailable or unsafe"
    USBAM_POLICY_ERROR_CODE="daemon_config_unavailable"
    return 1
  fi

  line_number=0
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line_number=$((line_number + 1))
    if [[ "$raw_line" =~ [[:cntrl:]] ]]; then
      usbguard_policy_error "control character in daemon configuration line $line_number"
      USBAM_POLICY_ERROR_CODE="invalid_daemon_config"
      return 1
    fi
    line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^(RuleFile|RuleFolder)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      continue
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "$value" || "$value" != /* ||
      "$value" == *"/../"* || "$value" == */.. ]]; then
      usbguard_policy_error "invalid $key path in daemon configuration"
      USBAM_POLICY_ERROR_CODE="invalid_policy_path"
      return 1
    fi
    if [[ "$value" == *"00-system.rules"* ]]; then
      usbguard_policy_error "daemon configuration points to protected 00-system.rules"
      USBAM_POLICY_ERROR_CODE="protected_policy"
      return 1
    fi
    if [[ "$key" == "RuleFile" ]]; then
      if [[ -n "$rule_file" ]]; then
        usbguard_policy_error "duplicate RuleFile in daemon configuration"
        USBAM_POLICY_ERROR_CODE="ambiguous_policy_source"
        return 1
      fi
      rule_file="$value"
    else
      if [[ -n "$rule_folder" ]]; then
        usbguard_policy_error "duplicate RuleFolder in daemon configuration"
        USBAM_POLICY_ERROR_CODE="ambiguous_policy_source"
        return 1
      fi
      rule_folder="$value"
    fi
  done < "$USBAM_DAEMON_CONFIG_PATH"

  if [[ -z "$rule_file" && -z "$rule_folder" ]]; then
    usbguard_policy_error "daemon configuration does not identify a persistent policy source"
    USBAM_POLICY_ERROR_CODE="policy_source_unconfigured"
    return 1
  fi

  if [[ -n "$rule_file" ]]; then
    if [[ -L "$rule_file" || ! -f "$rule_file" || ! -r "$rule_file" ]]; then
      usbguard_policy_error "configured RuleFile is missing, unsafe, or unreadable"
      USBAM_POLICY_ERROR_CODE="policy_source_unavailable"
      return 1
    fi
    USBAM_PERSISTENT_POLICY_PATHS[RuleFile]="$rule_file"
  fi
  if [[ -n "$rule_folder" ]] &&
    [[ -L "$rule_folder" || ! -d "$rule_folder" ||
      ! -r "$rule_folder" || ! -x "$rule_folder" ]]; then
    usbguard_policy_error "configured RuleFolder is missing, unsafe, or unreadable"
    USBAM_POLICY_ERROR_CODE="policy_source_unavailable"
    USBAM_PERSISTENT_POLICY_PATHS=()
    return 1
  fi
  if [[ -n "$rule_folder" ]]; then
    USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]="$rule_folder"
  fi
  return 0
}

check_daemon_status() {
  local timeout_seconds status
  USBAM_DAEMON_STATUS="unknown"
  USBAM_IPC_STATUS="unknown"
  USBAM_POLICY_ERROR_CODE=""

  if ! timeout_seconds="$(usbguard_policy_timeout)" ||
    [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
    usbguard_policy_error "IPC_TIMEOUT_SECONDS must be a positive integer"
    USBAM_POLICY_ERROR_CODE="invalid_timeout"
    return 1
  fi
  if ! command -v timeout >/dev/null 2>&1 ||
    ! command -v pgrep >/dev/null 2>&1; then
    usbguard_policy_error "timeout or pgrep utility is unavailable"
    USBAM_POLICY_ERROR_CODE="status_utility_unavailable"
    return 1
  fi

  if timeout --foreground --signal=TERM --kill-after=1s \
    "${timeout_seconds}s" pgrep -x usbguard-daemon >/dev/null 2>&1; then
    USBAM_DAEMON_STATUS="running"
  else
    status=$?
    if (( status == 1 )); then
      USBAM_DAEMON_STATUS="stopped"
      USBAM_IPC_STATUS="unavailable"
      return 9
    fi
    if (( status == 124 || status == 137 )); then
      USBAM_POLICY_ERROR_CODE="daemon_check_timeout"
    else
      USBAM_POLICY_ERROR_CODE="daemon_check_failed"
    fi
    usbguard_policy_error "unable to determine USBGuard daemon status"
    return 1
  fi

  if usbguard_policy_run_readonly list-devices; then
    USBAM_IPC_STATUS="connected"
    return 0
  fi
  USBAM_IPC_STATUS="unavailable"
  return 9
}

# --- New Phase 2: Write Operations ---

is_g01_verified() {
  local marker="/var/lib/usbguard-approval-manager/g01-verified"
  local owner mode
  local -a marker_lines=()

  if [[ -L "$marker" || ! -f "$marker" || ! -r "$marker" ]]; then
    return 1
  fi
  if ! owner="$(stat -c '%u' -- "$marker")" ||
    ! mode="$(stat -c '%a' -- "$marker")"; then
    return 1
  fi
  [[ "$owner" == "0" && "$mode" == "600" ]] || return 1
  mapfile -t marker_lines < "$marker" || return 1
  (( ${#marker_lines[@]} == 1 )) &&
    [[ "${marker_lines[0]}" == "G01_STATUS=PASS" ]]
}

usbguard_check_precedence() {
  local new_rule="$1"
  local canonical_new
  canonical_new="$(usbguard_canonicalize_rule "$new_rule")"
  local new_id_pattern
  new_id_pattern="$(usbguard_extract_id_pattern "$canonical_new")"

  if ! list_active_rules; then
    return 1
  fi

  local line existing_id existing_rule existing_id_pattern
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    usbguard_parse_rule_line "$line" existing_id existing_rule || continue
    # Fail closed unless the earlier block/reject is provably disjoint.
    if [[ "$existing_rule" =~ ^(block|reject)[[:space:]] &&
      "$canonical_new" =~ ^allow[[:space:]] ]]; then
      existing_id_pattern="$(usbguard_extract_id_pattern "$existing_rule")"
      if [[ -z "$existing_id_pattern" || -z "$new_id_pattern" ||
        "$new_id_pattern" == "$existing_id_pattern" ]]; then
        usbguard_policy_error "precedence conflict: existing block rule $existing_id ($existing_id_pattern) precedes new allow $new_id_pattern"
        USBAM_POLICY_ERROR_CODE="precedence_conflict"
        return 1
      fi
    fi
  done
  return 0
}

usbguard_find_rule_id_by_canonical() {
  local canonical_target="$1"
  canonical_target="$(usbguard_canonicalize_rule "$canonical_target")"
  if [[ -z "$canonical_target" ]]; then
    usbguard_policy_error "canonical rule target is empty"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi

  if ! list_active_rules; then
    return 1
  fi

  local line rid rtext
  local -a matches=()
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rtext" == "$canonical_target" ]]; then
      matches+=("$rid")
    fi
  done

  if (( ${#matches[@]} == 0 )); then
    usbguard_policy_error "no active rule matches canonical rule: $canonical_target"
    USBAM_POLICY_ERROR_CODE="rule_not_found"
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    usbguard_policy_error "ambiguous match: ${#matches[@]} rules match canonical rule"
    USBAM_POLICY_ERROR_CODE="ambiguous_rule_match"
    return 1
  fi

  USBAM_MATCHED_RULE_ID="${matches[0]}"
  printf '%s\n' "$USBAM_MATCHED_RULE_ID"
  return 0
}

approve_device() {
  local device_id="${1:-}"
  if (( $# != 1 )); then
    usbguard_policy_error "approve_device requires exactly one device ID"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  usbguard_validate_device_id "$device_id" || return 1
  usbguard_policy_require_lock || return 1

  if ! check_daemon_status; then
    if [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
      usbguard_policy_error "daemon not running or IPC unavailable for approve_device"
      USBAM_POLICY_ERROR_CODE="daemon_unavailable"
      return 1
    fi
  fi

  USBAM_LAST_DEVICE_ID="$device_id"
  if ! usbguard_policy_run_write allow-device "$device_id"; then
    return 1
  fi

  # Verify that the requested device still exists and is actually allowed.
  if ! usbguard_policy_run_readonly list-devices; then
    usbguard_policy_error "failed to verify device state after approve_device"
    USBAM_POLICY_ERROR_CODE="verification_failed"
    return 1
  fi
  local line found=0 state
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]+(allow|block|reject)[[:space:]] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$device_id" ]]; then
        if (( found != 0 )); then
          usbguard_policy_error "device $device_id appears more than once in USBGuard state"
          USBAM_POLICY_ERROR_CODE="ambiguous_device"
          return 1
        fi
        found=1
        state="${BASH_REMATCH[2]}"
      fi
    fi
  done <<< "$USBAM_POLICY_STDOUT"
  if (( found == 0 )); then
    usbguard_policy_error "device $device_id disappeared before approval could be verified"
    USBAM_POLICY_ERROR_CODE="device_not_found"
    return 1
  fi
  if [[ "$state" != "allow" ]]; then
    usbguard_policy_error "device $device_id is not allowed after allow-device"
    USBAM_POLICY_ERROR_CODE="device_still_blocked"
    return 1
  fi

  return 0
}

add_temporary_rule() {
  local rule="${1:-}"
  if (( $# != 1 )); then
    usbguard_policy_error "add_temporary_rule requires exactly one rule"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  usbguard_validate_rule "$rule" || return 1
  rule="$(usbguard_canonicalize_rule "$rule")"
  usbguard_policy_require_lock || return 1

  if ! check_daemon_status; then
    if [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
      usbguard_policy_error "daemon not running or IPC unavailable for add_temporary_rule"
      USBAM_POLICY_ERROR_CODE="daemon_unavailable"
      return 1
    fi
  fi

  if ! usbguard_check_precedence "$rule"; then
    return 1
  fi

  # Check duplicate - exact canonical match
  if ! list_active_rules; then
    return 1
  fi
  local line rid rtext
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rtext" == "$rule" ]]; then
      usbguard_policy_error "temporary rule already exists as active rule $rid"
      USBAM_POLICY_ERROR_CODE="duplicate_rule"
      return 1
    fi
  done

  if ! usbguard_policy_run_write append-rule --temporary "$rule"; then
    return 1
  fi

  USBAM_LAST_RULE_ID="$(usbguard_canonicalize_rule "$USBAM_POLICY_STDOUT")"
  # Some USBGuard versions output new rule ID in stdout, some output rule itself
  # Try to parse ID if stdout is numeric
  if [[ "$USBAM_LAST_RULE_ID" =~ ^[0-9]+$ ]]; then
    :
  else
    # If output is not numeric, try to find the rule by canonical match to get its ID
    if usbguard_find_rule_id_by_canonical "$rule"; then
      USBAM_LAST_RULE_ID="$USBAM_MATCHED_RULE_ID"
    else
      USBAM_LAST_RULE_ID=""
    fi
  fi

  # Verify rule exists
  if ! usbguard_find_rule_id_by_canonical "$rule" >/dev/null; then
    usbguard_policy_error "temporary rule not found after append-rule"
    USBAM_POLICY_ERROR_CODE="verification_failed"
    return 1
  fi

  return 0
}

add_permanent_rule() {
  local rule="${1:-}"
  if (( $# != 1 )); then
    usbguard_policy_error "add_permanent_rule requires exactly one rule"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  usbguard_validate_rule "$rule" || return 1
  rule="$(usbguard_canonicalize_rule "$rule")"
  usbguard_policy_require_lock || return 1

  if ! check_daemon_status; then
    if [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
      usbguard_policy_error "daemon not running or IPC unavailable for add_permanent_rule"
      USBAM_POLICY_ERROR_CODE="daemon_unavailable"
      return 1
    fi
  fi

  if ! get_persistent_policy_paths; then
    usbguard_policy_error "persistent policy source unavailable for permanent rule"
    return 1
  fi

  if ! usbguard_check_precedence "$rule"; then
    return 1
  fi

  if ! list_active_rules; then
    return 1
  fi
  local line rid rtext
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rtext" == "$rule" ]]; then
      usbguard_policy_error "permanent rule already exists as active rule $rid"
      USBAM_POLICY_ERROR_CODE="duplicate_rule"
      return 1
    fi
  done

  if ! usbguard_policy_run_write append-rule "$rule"; then
    return 1
  fi

  USBAM_LAST_RULE_ID="$(usbguard_canonicalize_rule "$USBAM_POLICY_STDOUT")"
  if [[ ! "$USBAM_LAST_RULE_ID" =~ ^[0-9]+$ ]]; then
    if usbguard_find_rule_id_by_canonical "$rule"; then
      USBAM_LAST_RULE_ID="$USBAM_MATCHED_RULE_ID"
    else
      USBAM_LAST_RULE_ID=""
    fi
  fi

  if ! usbguard_find_rule_id_by_canonical "$rule" >/dev/null; then
    usbguard_policy_error "permanent rule not found after append-rule"
    USBAM_POLICY_ERROR_CODE="verification_failed"
    return 1
  fi

  return 0
}

remove_rule_by_canonical_rule() {
  local canonical_rule="${1:-}"
  if (( $# != 1 )); then
    usbguard_policy_error "remove_rule_by_canonical_rule requires exactly one canonical rule"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  usbguard_validate_rule "$canonical_rule" || return 1
  canonical_rule="$(usbguard_canonicalize_rule "$canonical_rule")"
  usbguard_policy_require_lock || return 1

  if ! check_daemon_status; then
    if [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
      usbguard_policy_error "daemon not running or IPC unavailable for remove_rule"
      USBAM_POLICY_ERROR_CODE="daemon_unavailable"
      return 1
    fi
  fi

  local rule_id
  if ! rule_id="$(usbguard_find_rule_id_by_canonical "$canonical_rule")"; then
    return 1
  fi

  # Re-fetch immediately before removal to avoid TOCTOU (SEC-03)
  local fresh_id
  if ! fresh_id="$(usbguard_find_rule_id_by_canonical "$canonical_rule")"; then
    usbguard_policy_error "rule disappeared before removal (TOCTOU)"
    USBAM_POLICY_ERROR_CODE="rule_disappeared"
    return 1
  fi
  if [[ "$fresh_id" != "$rule_id" ]]; then
    usbguard_policy_error "rule ID changed between lookups (TOCTOU): $rule_id -> $fresh_id"
    USBAM_POLICY_ERROR_CODE="rule_id_changed"
    return 1
  fi

  if ! usbguard_policy_run_write remove-rule "$rule_id"; then
    return 1
  fi

  # Verify removal
  if ! list_active_rules; then
    usbguard_policy_error "failed to verify rule removal"
    USBAM_POLICY_ERROR_CODE="verification_failed"
    return 1
  fi
  local line rid rtext
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rid" == "$rule_id" ]]; then
      usbguard_policy_error "rule $rule_id still present after remove-rule"
      USBAM_POLICY_ERROR_CODE="rule_still_present"
      return 1
    fi
  done

  return 0
}

block_device() {
  local device_id="${1:-}"
  if (( $# != 1 )); then
    usbguard_policy_error "block_device requires exactly one device ID"
    USBAM_POLICY_ERROR_CODE="invalid_arguments"
    return 1
  fi
  usbguard_validate_device_id "$device_id" || return 1
  usbguard_policy_require_lock || return 1

  if ! check_daemon_status; then
    if [[ "$USBAM_DAEMON_STATUS" != "running" || "$USBAM_IPC_STATUS" != "connected" ]]; then
      usbguard_policy_error "daemon not running or IPC unavailable for block_device"
      USBAM_POLICY_ERROR_CODE="daemon_unavailable"
      return 1
    fi
  fi

  USBAM_LAST_DEVICE_ID="$device_id"
  if ! usbguard_policy_run_write block-device "$device_id"; then
    return 1
  fi

  if ! usbguard_policy_run_readonly list-devices; then
    usbguard_policy_error "failed to verify device state after block-device"
    USBAM_POLICY_ERROR_CODE="verification_failed"
    return 1
  fi
  local line found=0 state
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]+(allow|block|reject)[[:space:]] ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$device_id" ]]; then
        if (( found != 0 )); then
          usbguard_policy_error "device $device_id appears more than once in USBGuard state"
          USBAM_POLICY_ERROR_CODE="ambiguous_device"
          return 1
        fi
        found=1
        state="${BASH_REMATCH[2]}"
      fi
    fi
  done <<< "$USBAM_POLICY_STDOUT"
  if (( found == 0 )); then
    usbguard_policy_error "device $device_id disappeared before blocking could be verified"
    USBAM_POLICY_ERROR_CODE="device_not_found"
    return 1
  fi
  if [[ "$state" != "block" ]]; then
    usbguard_policy_error "device $device_id is not blocked after block-device"
    USBAM_POLICY_ERROR_CODE="device_not_blocked"
    return 1
  fi

  return 0
}

# Additional helpers for higher layers
get_rule_by_id() {
  local rule_id="${1:-}"
  if ! usbguard_validate_device_id "$rule_id"; then
    return 1
  fi
  if ! list_active_rules; then
    return 1
  fi
  local line rid rtext
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rid" == "$rule_id" ]]; then
      printf '%s\n' "$rtext"
      return 0
    fi
  done
  usbguard_policy_error "rule ID $rule_id not found"
  USBAM_POLICY_ERROR_CODE="rule_not_found"
  return 1
}
