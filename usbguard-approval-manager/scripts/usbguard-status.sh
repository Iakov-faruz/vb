#!/usr/bin/env bash
# Read-only status endpoint (SRS v4.5, NFR-04 / T-23).
# נקודת קצה לקריאה בלבד - מציגה סטטוס של daemon, IPC, timer ו-TTL
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
STATUS_SCRIPT="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

# shellcheck source=/dev/null
source "$LIB_DIR/config-reader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/validators.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/usbguard-policy.sh"

CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
TIMER_UNIT="${USBAM_TIMER_UNIT:-usbguard-approval-manager.timer}"
WATCH=0
WATCH_INTERVAL=5
JSON_MODE=0

usage() {
  printf 'Usage: %s --json | --watch [SECONDS] | --help\n' "$0"
  # הסבר: מציגה אפשרויות שורת פקודה. --json לפלט JSON, --watch למעקב עם רווחים,
  # --help לתיעוד. רווחי ברירת מחדל הוא 5 שניות, עד 3600 שניות.
}

while (( $# )); do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --watch)
      WATCH=1
      shift
      if (( $# )) && [[ "$1" =~ ^[0-9]+$ ]]; then
        WATCH_INTERVAL="$1"
        shift
      fi
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 7
      ;;
  esac
done

if (( 10#$WATCH_INTERVAL < 1 || 10#$WATCH_INTERVAL > 3600 )); then
  printf 'usbguard-status: ERROR: watch interval must be between 1 and 3600 seconds\n' >&2
  exit 7
fi
if (( JSON_MODE == 0 && WATCH == 0 )); then
  usage >&2
  exit 7
fi

if (( WATCH )); then
  while :; do
    if ! status_output="$(bash "$STATUS_SCRIPT" --json)"; then
      printf 'usbguard-status: ERROR: status query failed during watch\n' >&2
      exit 1
    fi
    if ! jq -ce . <<< "$status_output"; then
      printf 'usbguard-status: ERROR: status query returned invalid JSON during watch\n' >&2
      exit 1
    fi
    if ! sleep "$WATCH_INTERVAL"; then
      printf 'usbguard-status: ERROR: watch interval wait failed\n' >&2
      exit 1
    fi
  done
fi

service_status="unknown"
daemon_status="unknown"
ipc_status="unknown"
timer_status="unknown"
detail_code=""
policy_status="unknown"
policy_detail_code=""

# ספירת מצבי TTL - pending, active, inconsistent, recovery_required, expired
declare -A ttl_counts=(
  [pending]=0
  [active]=0
  [inconsistent]=0
  [recovery_required]=0
  [expired]=0
)

if [[ -e "$CONFIG_PATH" || -L "$CONFIG_PATH" ]]; then
  if [[ -L "$CONFIG_PATH" || ! -f "$CONFIG_PATH" || ! -r "$CONFIG_PATH" ]] ||
    ! load_config "$CONFIG_PATH"; then
    detail_code="invalid_config"
  fi
fi

if check_daemon_status; then
  daemon_status="$USBAM_DAEMON_STATUS"
  ipc_status="$USBAM_IPC_STATUS"
else
  daemon_status="$USBAM_DAEMON_STATUS"
  ipc_status="$USBAM_IPC_STATUS"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet "$TIMER_UNIT"; then
    timer_status="active"
  else
    timer_rc=$?
    if (( timer_rc == 3 || timer_rc == 4 )); then
      timer_status="inactive"
    else
      timer_status="unknown"
    fi
  fi
fi

if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
  detail_code="restore_recovery_required"
fi

if validate_ttl_json "$TTL_FILE"; then
  if [[ -f "$TTL_FILE" ]]; then
    while IFS=$'\t' read -r status count; do
      if [[ -n "${ttl_counts[$status]+present}" && "$count" =~ ^[0-9]+$ ]]; then
        ttl_counts["$status"]="$count"
      fi
    done < <(
      jq -r '
        [.records[] | .status] |
        group_by(.)[] |
        "\(.[0])\t\(length)"
      ' "$TTL_FILE"
    )
  fi
else
  detail_code="${detail_code:-ttl_state_invalid}"
fi

if [[ "$ipc_status" == "connected" ]]; then
  if list_active_rules && get_persistent_policy_paths; then
    policy_status="not_applicable"
  else
    policy_status="unknown"
    policy_detail_code="${USBAM_POLICY_ERROR_CODE:-policy_query_failed}"
    detail_code="${detail_code:-policy_query_failed}"
  fi
fi

if [[ -n "$detail_code" ]]; then
  service_status="degraded"
elif [[ "$daemon_status" == "stopped" || "$ipc_status" == "unavailable" ]]; then
  service_status="unavailable"
elif [[ "$daemon_status" == "unknown" || "$ipc_status" == "unknown" ||
  "$timer_status" == "unknown" ]]; then
  service_status="unknown"
elif [[ "$timer_status" == "inactive" ]]; then
  service_status="degraded"
else
  service_status="healthy"
fi

jq -n \
  --arg service_status "$service_status" \
  --arg daemon_status "$daemon_status" \
  --arg ipc_status "$ipc_status" \
  --arg timer_status "$timer_status" \
  --arg detail_code "$detail_code" \
  --arg policy_status "$policy_status" \
  --arg policy_detail_code "$policy_detail_code" \
  --argjson pending "${ttl_counts[pending]}" \
  --argjson active "${ttl_counts[active]}" \
  --argjson inconsistent "${ttl_counts[inconsistent]}" \
  --argjson recovery_required "${ttl_counts[recovery_required]}" \
  --argjson expired "${ttl_counts[expired]}" \
  '{
    schema_version: 1,
    service_status: $service_status,
    daemon_status: $daemon_status,
    ipc_status: $ipc_status,
    timer_status: $timer_status,
    ttl_counts: {
      pending: $pending,
      active: $active,
      inconsistent: $inconsistent,
      recovery_required: $recovery_required,
      expired: $expired
    },
    policy_result: {
      status: $policy_status,
      detail_code: (if $policy_detail_code == "" then null else $policy_detail_code end)
    },
    audit_result: {
      status: "not_applicable",
      detail_code: null
    },
    detail_code: (if $detail_code == "" then null else $detail_code end)
  }'
