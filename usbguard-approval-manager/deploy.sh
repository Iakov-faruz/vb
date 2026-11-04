#!/usr/bin/env bash
# Install the application without changing USBGuard policy or enabling units.

set -euo pipefail
umask 077

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/deploy-lib.sh"
source "$PROJECT_ROOT/scripts/lib/config-reader.sh"
source "$PROJECT_ROOT/scripts/lib/validators.sh"
source "$PROJECT_ROOT/scripts/lib/usbguard-policy.sh"

CONFIG_REL="/etc/usbguard-approval-manager/approval-manager.conf"
STATE_REL="/var/lib/usbguard-approval-manager"
BACKUP_REL="/var/backups/usbguard-approval-manager"
LOG_REL="/var/log/usbguard-approval-manager"
LOCK_REL="/run/lock/usbguard-approval-manager.lock"
LIBEXEC_REL="/usr/libexec/usbguard-approval-manager"
SERVICE_REL="/etc/systemd/system/usbguard-approval-ttl.service"
TIMER_REL="/etc/systemd/system/usbguard-approval-ttl.timer"
SUDOERS_REL="/etc/sudoers.d/usbguard-approval-manager"
LOGROTATE_REL="/etc/logrotate.d/usbguard-approval-manager"
REAPER_SERVICE_REL="/etc/systemd/system/usbguard-approval-manager-reaper.service"
REAPER_TIMER_REL="/etc/systemd/system/usbguard-approval-manager-reaper.timer"
CONFIG_CONF_REL="/etc/usbguard-approval-manager/config/usbguard-approval-manager.conf.example"
DEPLOY_ABORTING=0

usage() {
  cat <<'EOF'
Usage: deploy.sh [--root STAGING_DIRECTORY] [--help]

Install application files and protected data directories. A staging root is
for packaging/tests only; it must already exist and cannot be /. A live
installation requires root, USBGuard IPC, and an interactive confirmation.
The installer never edits USBGuard rules or enables/starts the TTL timer.
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
  if (( status != 0 )) && [[ -n "$DEPLOY_SNAPSHOT_DIR" ]] &&
    (( DEPLOY_ABORTING == 0 )); then
    DEPLOY_ABORTING=1
    printf 'deploy: rolling back the incomplete installation\n' >&2
    if ! deploy_rollback; then
      printf 'deploy: ERROR: rollback was incomplete; inspect the reported paths\n' >&2
      status=1
    fi
    if (( ! DEPLOY_STAGE )) && command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload || {
        printf 'deploy: ERROR: systemd could not reload the restored units\n' >&2
        status=1
      }
    fi
  fi
  exit "$status"
}
trap 'on_exit $?' EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    deploy_error "required command is unavailable: $1"
    return 1
  }
}

preflight_live_host() {
  local available_kb needed_kb version config_path os_release distro_id distro_version
  local -a required=(bash python3 jq flock timeout usbguard systemctl systemd-analyze visudo logrotate install stat df du awk diff whiptail)
  local command_name

  if (( EUID != 0 )); then
    deploy_error "live installation requires root"
    return 1
  fi
  for command_name in "${required[@]}"; do
    require_command "$command_name" || return 1
  done
  if ! getent group usbadmins >/dev/null; then
    deploy_error "the required usbadmins group does not exist"
    return 1
  fi
  os_release="$(deploy_path /etc/os-release)"
  if [[ -L "$os_release" || ! -f "$os_release" || ! -r "$os_release" ]]; then
    deploy_error "the target distribution cannot be identified from /etc/os-release"
    return 1
  fi
  distro_id="$(awk -F= '$1 == "ID" { gsub(/^"|"$/, "", $2); print $2; exit }' "$os_release")"
  distro_version="$(awk -F= '$1 == "VERSION_ID" { gsub(/^"|"$/, "", $2); print $2; exit }' "$os_release")"
  if [[ -z "$distro_id" ]]; then
    deploy_error "the target distribution identifier is missing"
    return 1
  fi
  printf 'Target distribution: %s %s\n' "$distro_id" "${distro_version:-version-unknown}"
  if ! usbguard --version >/dev/null 2>&1; then
    deploy_error "USBGuard is unavailable"
    return 1
  fi
  if ! timeout --foreground 5s usbguard list-rules >/dev/null 2>&1; then
    deploy_error "USBGuard IPC is unavailable; refusing deployment"
    return 1
  fi

  config_path="$(deploy_path "$CONFIG_REL")"
  if [[ -L "$config_path" || ( -e "$config_path" && ! -f "$config_path" ) ]]; then
    deploy_error "existing application configuration is not a regular file"
    return 1
  fi
  if [[ -f "$config_path" ]]; then
    load_config "$config_path" || {
      deploy_error "existing application configuration is invalid; it was not replaced"
      return 1
    }
  else
    load_config "$PROJECT_ROOT/conf/approval-manager.conf.example" || return 1
  fi

  local state_path ttl_path
  state_path="$(deploy_path "$STATE_REL")"
  ttl_path="$state_path/ttl.json"
  if [[ -L "$state_path" || ( -e "$state_path" && ! -d "$state_path" ) ]]; then
    deploy_error "existing state path is not a directory"
    return 1
  fi
  if [[ -L "$ttl_path" || ( -e "$ttl_path" && ! -f "$ttl_path" ) ]]; then
    deploy_error "existing ttl.json is not a regular file"
    return 1
  fi
  if [[ -f "$ttl_path" ]] && ! validate_ttl_json "$ttl_path"; then
    deploy_error "existing ttl.json is invalid; state was not replaced"
    return 1
  fi

  if ! get_usbguard_version; then
    deploy_error "unable to determine the USBGuard version"
    return 1
  fi
  version="$USBAM_POLICY_VERSION"
  if ! get_persistent_policy_paths; then
    deploy_error "unable to read the active USBGuard policy configuration"
    return 1
  fi
  printf 'USBGuard version: %s\n' "$version"
  printf 'RuleFile: %s\n' "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-not configured}"
  printf 'RuleFolder: %s\n' "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-not configured}"
  printf 'USBGuard policy diff: empty; policy files are not installation targets and no rules will be changed.\n'

  available_kb="$(df -Pk "$DEPLOY_ROOT" | awk 'NR == 2 { print $4 }')"
  needed_kb="$(du -sk "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/systemd" \
    "$PROJECT_ROOT/sudoers" "$PROJECT_ROOT/logrotate" "$PROJECT_ROOT/config" | awk '{ total += $1 } END { print total + 1024 }')"
  if [[ ! "$available_kb" =~ ^[0-9]+$ || ! "$needed_kb" =~ ^[0-9]+$ ]] ||
    (( available_kb < needed_kb )); then
    deploy_error "insufficient disk space for installation"
    return 1
  fi

  local policy_path
  for policy_path in "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}" \
    "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}"; do
    [[ -n "$policy_path" ]] || continue
    if [[ -e "$policy_path" ]]; then
      printf 'policy_source_sha256=%s  %s\n' \
        "$(sha256sum -- "$policy_path" 2>/dev/null | awk '{ print $1 }' || printf 'unavailable')" \
        "$policy_path"
    fi
  done
}

confirm_live_install() {
  if (( DEPLOY_STAGE )); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    deploy_error "live installation requires an interactive confirmation"
    return 1
  fi
  printf 'Install USBGuard Approval Manager? Existing configuration, TTL, Audit and backups are preserved. [y/N] '
  local answer
  IFS= read -r answer || return 1
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf 'Installation cancelled.\n'; return 130 ;;
  esac
}

show_application_diff() {
  local source target name result changed=0
  shopt -s nullglob
  for source in "$PROJECT_ROOT"/scripts/*.sh "$PROJECT_ROOT"/scripts/lib/*; do
    name="$(basename -- "$source")"
    if [[ "$source" == "$PROJECT_ROOT"/scripts/lib/* ]]; then
      target="$LIBEXEC_REL/lib/$name"
    else
      target="$LIBEXEC_REL/$name"
    fi
    target="$(deploy_path "$target")"
    if [[ -L "$target" ]]; then
      shopt -u nullglob
      deploy_error "installed application path is a symbolic link: $target"
      return 1
    fi
    if [[ -f "$target" ]] && ! cmp -s -- "$source" "$target"; then
      changed=1
      printf '\n--- installed update: %s ---\n' "$target"
      diff -u -- "$target" "$source" || result=$?
      if [[ "${result:-0}" -gt 1 ]]; then
        shopt -u nullglob
        deploy_error "unable to compare installed file: $target"
        return 1
      fi
      result=0
    fi
  done
  shopt -u nullglob
  if (( changed == 0 )); then
    printf 'Application file diff: empty (new install or already current).\n'
  fi
}

verify_managed_directories() {
  local root_group="root" app_owner="root" admins_group="usbadmins"
  if (( DEPLOY_STAGE )); then
    app_owner="$(id -un)"
    root_group="$(id -gn)"
    admins_group="$root_group"
  fi

  if (( DEPLOY_STAGE )); then
    deploy_ensure_directory /usr/libexec 0755 "$app_owner" "$root_group"
    deploy_ensure_directory /etc/systemd/system 0755 "$app_owner" "$root_group"
    deploy_ensure_directory /etc/sudoers.d 0750 "$app_owner" "$root_group"
    deploy_ensure_directory /etc/logrotate.d 0755 "$app_owner" "$root_group"
    deploy_ensure_directory /run/lock 0755 "$app_owner" "$root_group"
  else
    deploy_ensure_parent /usr/libexec
    deploy_ensure_parent /etc/systemd/system
    deploy_ensure_parent /etc/sudoers.d
    deploy_ensure_parent /etc/logrotate.d
    deploy_ensure_parent /run/lock
  fi
  deploy_ensure_directory "$LIBEXEC_REL" 0750 "$app_owner" "$root_group"
  deploy_ensure_directory "$LIBEXEC_REL/lib" 0750 "$app_owner" "$root_group"
  deploy_ensure_directory /etc/usbguard-approval-manager 0750 "$app_owner" "$root_group"
  deploy_ensure_directory "$STATE_REL" 0700 "$app_owner" "$root_group"
  deploy_ensure_directory "$BACKUP_REL" 0700 "$app_owner" "$root_group"
  deploy_ensure_directory "$LOG_REL" 0750 "$app_owner" "$admins_group"
}

install_managed_files() {
  local app_owner="root" root_group="root" admins_group="usbadmins"
  local file name target mode source_path
  if (( DEPLOY_STAGE )); then
    app_owner="$(id -un)"
    root_group="$(id -gn)"
    admins_group="$root_group"
  fi

  shopt -s nullglob
  for file in "$PROJECT_ROOT"/scripts/*.sh; do
    [[ -f "$file" && ! -L "$file" ]] || {
      deploy_error "unexpected non-regular script source"
      return 1
    }
    name="$(basename -- "$file")"
    target="$LIBEXEC_REL/$name"
    deploy_install_file "$file" "$target" 0750 "$app_owner" "$root_group"
  done
  for file in "$PROJECT_ROOT"/scripts/lib/*; do
    [[ -f "$file" && ! -L "$file" ]] || {
      deploy_error "unexpected non-regular library source"
      return 1
    }
    name="$(basename -- "$file")"
    target="$LIBEXEC_REL/lib/$name"
    mode=0640
    [[ "$name" == *.sh ]] && mode=0640
    deploy_install_file "$file" "$target" "$mode" "$app_owner" "$root_group"
  done
  shopt -u nullglob

  local config_path state_path log_path lock_path
  config_path="$(deploy_path "$CONFIG_REL")"
  state_path="$(deploy_path "$STATE_REL")"
  log_path="$(deploy_path "$LOG_REL")"
  lock_path="$(deploy_path "$LOCK_REL")"

  if [[ ! -e "$config_path" ]]; then
    deploy_install_file "$PROJECT_ROOT/conf/approval-manager.conf.example" \
      "$CONFIG_REL" 0600 "$app_owner" "$root_group"
  fi
  if [[ ! -e "$state_path/ttl.json" ]]; then
    source_path="$DEPLOY_SNAPSHOT_DIR/initial-ttl.json"
    printf '%s\n' '{"schema_version":1,"records":[]}' > "$source_path"
    chmod 600 "$source_path"
    deploy_install_file "$source_path" "$STATE_REL/ttl.json" 0600 "$app_owner" "$root_group"
  fi
  if [[ ! -e "$log_path/audit.jsonl" ]]; then
    source_path="$DEPLOY_SNAPSHOT_DIR/initial-audit.jsonl"
    : > "$source_path"
    chmod 600 "$source_path"
    deploy_install_file "$source_path" "$LOG_REL/audit.jsonl" \
      0640 "$app_owner" "$admins_group"
  fi
  if [[ ! -e "$lock_path" ]]; then
    source_path="$DEPLOY_SNAPSHOT_DIR/initial-lock"
    : > "$source_path"
    chmod 600 "$source_path"
    deploy_install_file "$source_path" "$LOCK_REL" 0600 "$app_owner" "$root_group"
  fi

  deploy_install_file "$PROJECT_ROOT/systemd/usbguard-approval-ttl.service" \
    "$SERVICE_REL" 0644 "$app_owner" "$root_group"
  deploy_install_file "$PROJECT_ROOT/systemd/usbguard-approval-ttl.timer" \
    "$TIMER_REL" 0644 "$app_owner" "$root_group"
  deploy_install_file "$PROJECT_ROOT/sudoers/usbguard-approval-manager" \
    "$SUDOERS_REL" 0440 "$app_owner" "$root_group"
  deploy_install_file "$PROJECT_ROOT/logrotate/usbguard-approval-manager" \
    "$LOGROTATE_REL" 0644 "$app_owner" "$root_group"

  deploy_install_file "$PROJECT_ROOT/systemd/usbguard-approval-manager-reaper.service" \
    "$REAPER_SERVICE_REL" 0644 "$app_owner" "$root_group"
  deploy_install_file "$PROJECT_ROOT/systemd/usbguard-approval-manager-reaper.timer" \
    "$REAPER_TIMER_REL" 0644 "$app_owner" "$root_group"

  if [[ ! -e "$(deploy_path "$CONFIG_CONF_REL")" ]]; then
    deploy_install_file "$PROJECT_ROOT/config/usbguard-approval-manager.conf.example" \
      "$CONFIG_CONF_REL" 0600 "$app_owner" "$root_group"
  fi
}

verify_installed_files() {
  local systemd_root="$DEPLOY_ROOT" result
  if command -v visudo >/dev/null 2>&1; then
    local sudoers_path
    sudoers_path="$(deploy_path "$SUDOERS_REL")"
    visudo -c -f "$sudoers_path" || {
      deploy_error "sudoers validation failed"
      return 1
    }
  elif (( ! DEPLOY_STAGE )); then
    deploy_error "visudo is required to validate the sudoers policy"
    return 1
  else
    printf 'UNVERIFIED: visudo is unavailable in staging; sudoers syntax check skipped\n'
  fi

  if command -v systemd-analyze >/dev/null 2>&1; then
    local service_path timer_path
    service_path="$(deploy_path "$SERVICE_REL")"
    timer_path="$(deploy_path "$TIMER_REL")"
    if (( DEPLOY_STAGE )); then
      systemd-analyze --root="$systemd_root" verify "$service_path" "$timer_path" || {
        deploy_error "systemd unit validation failed"
        return 1
      }
    else
      systemd-analyze verify "$service_path" "$timer_path" || {
        deploy_error "systemd unit validation failed"
        return 1
      }
    fi
  elif (( ! DEPLOY_STAGE )); then
    deploy_error "systemd-analyze is required to validate service units"
    return 1
  else
    printf 'UNVERIFIED: systemd-analyze is unavailable in staging; unit syntax check skipped\n'
  fi

  if command -v logrotate >/dev/null 2>&1; then
    local logrotate_path
    logrotate_path="$(deploy_path "$LOGROTATE_REL")"
    logrotate --debug --state /dev/null "$logrotate_path" >/dev/null || {
      deploy_error "logrotate configuration validation failed"
      return 1
    }
  elif (( ! DEPLOY_STAGE )); then
    deploy_error "logrotate is required to validate log rotation"
    return 1
  else
    printf 'UNVERIFIED: logrotate is unavailable in staging; syntax check skipped\n'
  fi

  if (( DEPLOY_STAGE )); then
    if USBAM_ROOT="$DEPLOY_ROOT" bash "$PROJECT_ROOT/validate_all.sh" --static; then
      result=0
    else
      result=$?
    fi
  else
    if bash "$PROJECT_ROOT/validate_all.sh" --static; then
      result=0
    else
      result=$?
    fi
  fi
  (( result == 0 )) || {
    deploy_error "static installation validation failed"
    return 1
  }
}

main() {
  parse_args "$@" || exit $?
  if (( ! DEPLOY_STAGE )); then
    preflight_live_host
    show_application_diff
  fi
  confirm_live_install || exit $?
  deploy_begin_transaction
  verify_managed_directories
  install_managed_files
  verify_installed_files

  if (( ! DEPLOY_STAGE )); then
    systemctl daemon-reload || {
      deploy_error "systemd daemon-reload failed"
      return 1
    }
  fi

  deploy_commit
  printf 'Installation completed. Existing config, TTL state, Audit and backups were preserved.\n'
  printf 'The TTL timer activation state was not changed; enable it only after required G-01 and release gates are approved.\n'
  if (( DEPLOY_STAGE )); then
    printf 'Staging root: %s (no host services, devices or policy were changed).\n' "$DEPLOY_ROOT"
  fi
}

main "$@"
