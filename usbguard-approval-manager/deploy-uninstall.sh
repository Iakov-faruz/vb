#!/usr/bin/env bash
# Remove application code and integration files while preserving all user data.

set -euo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/deploy-lib.sh"

LIBEXEC_REL="/usr/libexec/usbguard-approval-manager"
SERVICE_REL="/etc/systemd/system/usbguard-approval-ttl.service"
TIMER_REL="/etc/systemd/system/usbguard-approval-ttl.timer"
SUDOERS_REL="/etc/sudoers.d/usbguard-approval-manager"
LOGROTATE_REL="/etc/logrotate.d/usbguard-approval-manager"
REAPER_SERVICE_REL="/etc/systemd/system/usbguard-approval-manager-reaper.service"
REAPER_TIMER_REL="/etc/systemd/system/usbguard-approval-manager-reaper.timer"
TIMER_UNIT="usbguard-approval-ttl.timer"
SERVICE_UNIT="usbguard-approval-ttl.service"
REAPER_TIMER_UNIT="usbguard-approval-manager-reaper.timer"
REAPER_SERVICE_UNIT="usbguard-approval-manager-reaper.service"
WAS_ACTIVE=0
WAS_ENABLED=0
WAS_REAPER_ACTIVE=0
WAS_REAPER_ENABLED=0

usage() {
  cat <<'EOF'
Usage: deploy-uninstall.sh [--root STAGING_DIRECTORY] [--help]

Remove installed code, systemd units, sudoers and logrotate configuration.
The application configuration, TTL state, Audit log, backups and lock file
are always preserved.
EOF
}

parse_args() {
  local root="/"
  while (( $# )); do
    case "$1" in
      --root)
        if (( $# < 2 )) || [[ -z "$2" || "$root" != "/" ]]; then
          usage >&2
          return 7
        fi
        root="$2"
        shift 2
        ;;
      --help)
        if (( $# != 1 )); then usage >&2; return 7; fi
        usage
        exit 0
        ;;
      *)
        usage >&2
        return 7
        ;;
    esac
  done
  deploy_set_root "$root"
}

on_exit() {
  local status="$1"
  trap - EXIT
  if (( status != 0 )); then
    if [[ -n "$DEPLOY_SNAPSHOT_DIR" ]]; then
      printf 'uninstall: rolling back removed application files\n' >&2
      if ! deploy_rollback; then status=1; fi
      if (( ! DEPLOY_STAGE )); then
        systemctl daemon-reload || status=1
      fi
    fi
    if (( ! DEPLOY_STAGE )); then
      if (( WAS_ENABLED )); then systemctl enable "$TIMER_UNIT" || status=1; fi
      if (( WAS_ACTIVE )); then systemctl start "$TIMER_UNIT" || status=1; fi
      if (( WAS_REAPER_ENABLED )); then systemctl enable "$REAPER_TIMER_UNIT" || status=1; fi
      if (( WAS_REAPER_ACTIVE )); then systemctl start "$REAPER_TIMER_UNIT" || status=1; fi
    fi
  fi
  exit "$status"
}
trap 'on_exit $?' EXIT

wait_for_service_idle() {
  local attempt
  for ((attempt=0; attempt<60; attempt++)); do
    if ! systemctl is-active --quiet "$SERVICE_UNIT"; then
      return 0
    fi
    sleep 1
  done
  deploy_error "TTL service did not finish within 60 seconds; files were not removed"
  return 1
}

confirm_uninstall() {
  if (( DEPLOY_STAGE )); then return 0; fi
  if (( EUID != 0 )); then
    deploy_error "live uninstallation requires root"
    return 1
  fi
  if [[ ! -t 0 ]]; then
    deploy_error "live uninstallation requires an interactive confirmation"
    return 1
  fi
  printf 'Remove application code and service integrations? Config, TTL, Audit and backups are preserved. [y/N] '
  local answer
  IFS= read -r answer || return 1
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf 'Uninstallation cancelled.\n'; return 130 ;;
  esac
}

stop_timer_safely() {
  if (( DEPLOY_STAGE )); then return 0; fi
  command -v systemctl >/dev/null 2>&1 || {
    deploy_error "systemctl is unavailable"
    return 1
  }
  if systemctl is-enabled --quiet "$TIMER_UNIT"; then WAS_ENABLED=1; fi
  if systemctl is-active --quiet "$TIMER_UNIT"; then
    WAS_ACTIVE=1
    systemctl stop "$TIMER_UNIT" || {
      deploy_error "unable to stop the TTL timer"
      return 1
    }
  fi
  if systemctl is-enabled --quiet "$REAPER_TIMER_UNIT"; then WAS_REAPER_ENABLED=1; fi
  if systemctl is-active --quiet "$REAPER_TIMER_UNIT"; then
    WAS_REAPER_ACTIVE=1
    systemctl stop "$REAPER_TIMER_UNIT" || {
      deploy_error "unable to stop the reaper timer"
      return 1
    }
  fi
  wait_for_service_idle
  if (( WAS_ENABLED )); then
    systemctl disable "$TIMER_UNIT" || {
      deploy_error "unable to disable the TTL timer"
      return 1
    }
  fi
  if (( WAS_REAPER_ENABLED )); then
    systemctl disable "$REAPER_TIMER_UNIT" || {
      deploy_error "unable to disable the reaper timer"
      return 1
    }
  fi
}

remove_managed_path() {
  local relative="$1" path
  path="$(deploy_path "$relative")" || return 1
  [[ -e "$path" || -L "$path" ]] || return 0
  deploy_track_path "$relative" || return 1
  if [[ -d "$path" && ! -L "$path" ]]; then
    rm -rf -- "$path"
  else
    rm -f -- "$path"
  fi
}

main() {
  parse_args "$@" || exit $?
  confirm_uninstall || exit $?
  stop_timer_safely
  deploy_begin_transaction

  remove_managed_path "$LIBEXEC_REL"
  remove_managed_path "$SERVICE_REL"
  remove_managed_path "$TIMER_REL"
  remove_managed_path "$REAPER_SERVICE_REL"
  remove_managed_path "$REAPER_TIMER_REL"
  remove_managed_path "$SUDOERS_REL"
  remove_managed_path "$LOGROTATE_REL"

  if (( ! DEPLOY_STAGE )); then
    systemctl daemon-reload || {
      deploy_error "systemd daemon-reload failed"
      return 1
    }
  fi
  deploy_commit
  printf 'Application files removed. Configuration, TTL state, Audit, backups and lock were preserved.\n'
}

main "$@"
