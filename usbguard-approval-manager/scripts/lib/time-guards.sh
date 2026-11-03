#!/usr/bin/env bash
# Calendar-time checks using verified system NTP synchronization evidence.

if [[ -z "${USBAM_TIME_GUARDS_LOADED+x}" ]]; then
  readonly USBAM_TIME_GUARDS_VERSION="1.0.0"
  readonly USBAM_CLOCK_STATE_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/clock_state.py"
  declare -g CLOCK_STATE_PATH="/var/lib/usbguard-approval-manager/clock_state.json"
  declare -g CLOCK_SYNC_PROVIDER=""
  declare -g CLOCK_SYNC_STATUS=""
  declare -g CLOCK_TRUST_STATUS="untrusted"
  declare -g CLOCK_TRUST_DETAIL_CODE="clock_sync_provider_unverified"
  declare -gr USBAM_TIME_GUARDS_LOADED=1
fi

clock_error() {
  printf 'time-guards: ERROR: %s\n' "$1" >&2
}

clock_sync_evidence() {
  CLOCK_SYNC_PROVIDER=""
  CLOCK_SYNC_STATUS=""
  CLOCK_TRUST_DETAIL_CODE="clock_sync_evidence_unavailable"

  local provider sync_status peers
  if ! command -v timeout >/dev/null 2>&1 ||
    ! command -v systemctl >/dev/null 2>&1 ||
    ! command -v timedatectl >/dev/null 2>&1 ||
    ! command -v ntpq >/dev/null 2>&1 ||
    ! command -v awk >/dev/null 2>&1; then
    CLOCK_TRUST_DETAIL_CODE="clock_sync_tools_unavailable"
    return 1
  fi

  provider=""
  if timeout --foreground --signal=TERM --kill-after=1s 5s \
    systemctl is-active --quiet ntpsec; then
    provider="ntpsec"
  elif timeout --foreground --signal=TERM --kill-after=1s 5s \
    systemctl is-active --quiet ntp; then
    provider="ntp"
  else
    CLOCK_TRUST_DETAIL_CODE="clock_sync_provider_inactive"
    return 1
  fi

  if ! sync_status="$(
    timeout --foreground --signal=TERM --kill-after=1s 5s \
      timedatectl show -p NTPSynchronized --value 2>/dev/null
  )"; then
    CLOCK_TRUST_DETAIL_CODE="clock_sync_status_unavailable"
    return 1
  fi
  if [[ "$sync_status" != "yes" ]]; then
    CLOCK_TRUST_DETAIL_CODE="clock_sync_not_synchronized"
    return 1
  fi

  if ! peers="$(
    timeout --foreground --signal=TERM --kill-after=1s 5s \
      ntpq -pn 2>/dev/null
  )" || ! awk '
    $1 ~ /^\*/ {
      selected++
      if ($3 !~ /^[0-9]+$/ || $3 < 1 || $3 > 15 ||
          $7 !~ /^[0-7]+$/ || $7 ~ /^0+$/) {
        invalid = 1
      }
    }
    END { exit !(selected == 1 && !invalid) }
  ' <<< "$peers"; then
    CLOCK_TRUST_DETAIL_CODE="clock_sync_peer_unavailable"
    return 1
  fi

  CLOCK_SYNC_PROVIDER="$provider"
  CLOCK_SYNC_STATUS="synchronized"
  CLOCK_TRUST_DETAIL_CODE="clock_sync_verified"
  return 0
}

get_current_epoch() {
  local epoch
  if ! epoch="$(date +%s)" || [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    clock_error "unable to read a non-negative Unix Epoch"
    return 1
  fi
  printf '%s\n' "$epoch"
}

clock_decimal_less_than() {
  local left="$1"
  local right="$2"

  while [[ "${#left}" -gt 1 && "${left:0:1}" == "0" ]]; do
    left="${left:1}"
  done
  while [[ "${#right}" -gt 1 && "${right:0:1}" == "0" ]]; do
    right="${right:1}"
  done
  if [[ "${#left}" -lt "${#right}" ]]; then
    return 0
  fi
  if [[ "${#left}" -gt "${#right}" ]]; then
    return 1
  fi
  [[ "$left" < "$right" ]]
}

is_clock_reasonable() {
  local epoch minimum
  if (( $# > 1 )); then
    clock_error "is_clock_reasonable accepts at most one Epoch value"
    return 1
  fi
  if (( $# == 1 )); then
    epoch="$1"
  elif ! epoch="$(get_current_epoch)"; then
    return 1
  fi
  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    clock_error "Epoch must be a non-negative integer"
    return 1
  fi
  if ! minimum="$(clock_config_value MIN_REASONABLE_EPOCH)"; then
    clock_error "MIN_REASONABLE_EPOCH is unavailable"
    return 1
  fi
  if [[ ! "$minimum" =~ ^[0-9]+$ ]] ||
    ! clock_decimal_less_than "$minimum" "$epoch"; then
    return 1
  fi
}

clock_config_value() {
  local key="$1"
  local declaration
  declaration="$(declare -p CONFIG_VALUES 2>/dev/null || true)"
  if [[ "$declaration" == "declare -A CONFIG_VALUES="* ]]; then
    if [[ -n "${CONFIG_VALUES[$key]+present}" ]]; then
      printf '%s\n' "${CONFIG_VALUES[$key]}"
      return 0
    fi
  fi
  if [[ -n "${!key-}" ]]; then
    printf '%s\n' "${!key}"
    return 0
  fi
  return 1
}

clock_read_boot_id() {
  local boot_id
  if ! IFS= read -r boot_id < /proc/sys/kernel/random/boot_id ||
    [[ ! "$boot_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    clock_error "unable to read a valid boot_id"
    return 1
  fi
  printf '%s\n' "$boot_id"
}

clock_read_boottime_seconds() {
  local uptime
  if ! IFS=' ' read -r uptime _ < /proc/uptime ||
    [[ ! "$uptime" =~ ^([0-9]+)([.][0-9]+)?$ ]]; then
    clock_error "unable to read CLOCK_BOOTTIME seconds"
    return 1
  fi
  printf '%s\n' "${uptime%%.*}"
}

detect_clock_jump() {
  local state_path="${1:-$CLOCK_STATE_PATH}"
  local has_records="${2:-}"
  local epoch boot_id boottime provider sync_status minimum max_jump
  local helper_status

  CLOCK_TRUST_STATUS="untrusted"
  CLOCK_TRUST_DETAIL_CODE="clock_evidence_unavailable"
  if (( $# > 2 )) || [[ -z "$state_path" ]] ||
    [[ "$has_records" != "yes" && "$has_records" != "no" ]]; then
    clock_error "detect_clock_jump requires a state path and yes/no non-expired-record flag"
    return 1
  fi
  if ! epoch="$(get_current_epoch)" || ! is_clock_reasonable "$epoch"; then
    CLOCK_TRUST_DETAIL_CODE="clock_epoch_unreasonable"
    return 9
  fi
  if ! clock_sync_evidence; then
    if [[ "$has_records" == "yes" ]]; then
      CLOCK_TRUST_STATUS="recovery_required"
      CLOCK_TRUST_DETAIL_CODE="clock_state_recovery_required"
      return 9
    fi
    CLOCK_TRUST_DETAIL_CODE="${CLOCK_TRUST_DETAIL_CODE:-clock_sync_provider_unverified}"
    return 9
  fi
  provider="$CLOCK_SYNC_PROVIDER"
  sync_status="$CLOCK_SYNC_STATUS"
  if [[ -z "$provider" || "$sync_status" != "synchronized" ]]; then
    CLOCK_TRUST_DETAIL_CODE="clock_sync_not_verified"
    return 9
  fi
  if ! boot_id="$(clock_read_boot_id)" ||
    ! boottime="$(clock_read_boottime_seconds)"; then
    CLOCK_TRUST_DETAIL_CODE="clock_monotonic_evidence_unavailable"
    return 9
  fi
  if ! minimum="$(clock_config_value MIN_REASONABLE_EPOCH)" ||
    ! max_jump="$(clock_config_value MAX_CLOCK_JUMP_SECONDS)" ||
    [[ ! "$minimum" =~ ^[0-9]+$ || ! "$max_jump" =~ ^[0-9]+$ ]]; then
    clock_error "clock threshold configuration is missing or invalid"
    CLOCK_TRUST_DETAIL_CODE="clock_configuration_invalid"
    return 1
  fi
  if [[ ! -r "$USBAM_CLOCK_STATE_HELPER" ]]; then
    clock_error "clock-state validator is missing or unreadable"
    CLOCK_TRUST_DETAIL_CODE="clock_state_helper_unavailable"
    return 1
  fi
  if [[ ! "$epoch" =~ ^[0-9]+$ || ! "$boottime" =~ ^[0-9]+$ ]]; then
    CLOCK_TRUST_DETAIL_CODE="clock_sample_invalid"
    return 9
  fi

  if CLOCK_TRUST_STATUS="$(
    python3 "$USBAM_CLOCK_STATE_HELPER" \
      --state "$state_path" \
      --epoch "$epoch" \
      --provider "$provider" \
      --sync-status "$sync_status" \
      --boot-id "$boot_id" \
      --boottime-seconds "$boottime" \
      --min-reasonable-epoch "$minimum" \
      --max-clock-jump-seconds "$max_jump" \
      --has-non-expired-records "$has_records"
  )"; then
    CLOCK_TRUST_DETAIL_CODE="clock_trusted"
    return 0
  else
    helper_status=$?
  fi

  case "$CLOCK_TRUST_STATUS" in
    recovery_required)
      CLOCK_TRUST_DETAIL_CODE="clock_state_recovery_required"
      return 9
      ;;
    untrusted_clock)
      CLOCK_TRUST_DETAIL_CODE="clock_untrusted"
      return 9
      ;;
    *)
      CLOCK_TRUST_STATUS="untrusted"
      CLOCK_TRUST_DETAIL_CODE="clock_state_error"
      if (( helper_status != 9 )); then
        clock_error "clock-state evaluation or durable state update failed"
        return 1
      fi
      return 9
      ;;
  esac
}
