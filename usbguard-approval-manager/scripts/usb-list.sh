#!/usr/bin/env bash
# usb-list.sh - List managed rules
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/validators.sh" 2>/dev/null || true
source "$LIB_DIR/tui.sh" 2>/dev/null || true

STATE_DIR="${STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${TTL_FILE:-$STATE_DIR/ttl.json}"

main(){
  if [[ ! -f "$TTL_FILE" ]]; then
    if command -v whiptail >/dev/null 2>&1; then
      whiptail --title "Managed Rules" --msgbox "No ttl.json found at $TTL_FILE" 10 70
    else
      echo "No ttl.json at $TTL_FILE"
    fi
    exit 0
  fi

  if ! validate_ttl_json "$TTL_FILE" 2>/dev/null; then
    echo "ttl.json invalid: $VALIDATORS_ERROR" >&2
    exit 1
  fi

  local records
  records="$(jq -r '.records[] | "\(.managed_id) | \(.status) | \(.rule) | expires \(.expires_at)"' "$TTL_FILE" 2>/dev/null)"

  if command -v whiptail >/dev/null 2>&1; then
    local display
    display="$(echo "$records" | head -n 50)"
    whiptail --title "Managed Rules" --msgbox "$display" 25 90
  else
    echo "$records"
  fi
}
main "$@"
