#!/usr/bin/env bash
# Create a private, integrity-checked Phase 5 backup archive.

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
BACKUP_DIR="${USBAM_BACKUP_DIR:-/var/backups/usbguard-approval-manager}"
USBAM_DAEMON_CONFIG_PATH="${USBAM_DAEMON_CONFIG_PATH:-/etc/usbguard/usbguard-daemon.conf}"

usage() {
  printf 'Usage: %s [--help]\nCreates a validated backup in %s.\n' "$0" "$BACKUP_DIR"
}

if (( $# )); then
  if (( $# == 1 )) && [[ "$1" == "--help" ]]; then
    usage
    exit 0
  fi
  usage >&2
  exit 7
fi
if (( EUID != 0 )); then
  printf 'backup-rules: ERROR: root privileges are required\n' >&2
  exit 1
fi

source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lifecycle.sh"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"

if [[ -L "$CONFIG_PATH" ]]; then
  printf 'backup-rules: ERROR: configuration must not be a symbolic link\n' >&2
  exit 1
fi
if [[ -f "$CONFIG_PATH" ]]; then
  CONFIG_SOURCE="$CONFIG_PATH"
else
  CONFIG_SOURCE="$SCRIPT_DIR/../conf/approval-manager.conf.example"
fi
if [[ ! -f "$CONFIG_SOURCE" || ! -r "$CONFIG_SOURCE" ]] || ! load_config "$CONFIG_SOURCE"; then
  printf 'backup-rules: ERROR: configuration is missing or invalid\n' >&2
  exit 1
fi

if ! lock_acquire 5; then
  printf 'backup-rules: ERROR: unable to acquire the state lock\n' >&2
  exit 9
fi
if ! lifecycle_require_no_journal; then
  exit 9
fi
if ! validate_ttl_json "$TTL_FILE"; then
  printf 'backup-rules: ERROR: ttl.json is invalid\n' >&2
  exit 9
fi
if [[ -L "$TTL_FILE" ]]; then
  printf 'backup-rules: ERROR: ttl.json must not be a symbolic link\n' >&2
  exit 9
fi

work_dir="$(mktemp -d)" || {
  printf 'backup-rules: ERROR: unable to create private staging directory\n' >&2
  exit 1
}
chmod 700 "$work_dir" || {
  rmdir "$work_dir" 2>/dev/null || true
  printf 'backup-rules: ERROR: unable to secure staging directory\n' >&2
  exit 1
}
cleanup() {
  rm -rf -- "$work_dir"
  if (( LOCK_HELD )); then
    lock_release
  fi
}
trap cleanup EXIT

if [[ -f "$TTL_FILE" ]]; then
  cp -- "$TTL_FILE" "$work_dir/ttl.json" || {
    printf 'backup-rules: ERROR: unable to stage ttl.json\n' >&2
    exit 1
  }
else
  printf '%s\n' '{"schema_version":1,"records":[]}' > "$work_dir/ttl.json"
fi
chmod 600 "$work_dir/ttl.json" || exit 1
if ! lifecycle_collect_export_json > "$work_dir/export.json"; then
  exit 1
fi
chmod 600 "$work_dir/export.json" || exit 1
if ! "$PYTHON3" "$USBAM_LIFECYCLE_HELPER" backup-create \
  --config "$CONFIG_SOURCE" \
  --ttl "$work_dir/ttl.json" \
  --export "$work_dir/export.json" \
  --directory "$BACKUP_DIR" \
  --keep "$(get_config BACKUP_KEEP)"; then
  exit 1
fi
