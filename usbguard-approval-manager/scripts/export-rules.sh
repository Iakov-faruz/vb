#!/usr/bin/env bash
# Export only validated, non-system permanent allow rules and active TTL records.
#
# --- הסבר בעברית ---
# ייצוא רק כללי Allow מאומן, לא-מערכתיים, ורשומות TTL פעילות.
# מייצאת אך ורק כללי allow שנבדקו ואומתו, שאינם כללים מערכתיים (00-system.rules),
# ורשומות TTL הפעילות במערכת.
# תוכנת לפי SRS v4.5 ומבטיחה תקינות של כללי היציאה.
#
# תלויה: lib/lifecycle.sh, lib/validators.sh, jq

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PYTHON3="${PYTHON3:-python3}"
CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
USBAM_DAEMON_CONFIG_PATH="${USBAM_DAEMON_CONFIG_PATH:-/etc/usbguard/usbguard-daemon.conf}"

usage() {
  printf 'Usage: %s [--help]\nWrites schema-version-1 JSON to standard output.\n' "$0"
}

if (( $# )); then
  if (( $# == 1 )) && [[ "$1" == "--help" ]]; then
    usage
    exit 0
  fi
  usage >&2
  exit 7
fi

source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lifecycle.sh"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"

if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
  lifecycle_error "restore journal exists; export is blocked until recovery"
  exit 9
fi
if [[ -e "$CONFIG_PATH" || -L "$CONFIG_PATH" ]]; then
  if [[ -L "$CONFIG_PATH" || ! -f "$CONFIG_PATH" || ! -r "$CONFIG_PATH" ]] ||
    ! load_config "$CONFIG_PATH"; then
    lifecycle_error "application configuration is invalid"
    exit 1
  fi
fi

if ! lifecycle_collect_export_json; then
  exit 1
fi
