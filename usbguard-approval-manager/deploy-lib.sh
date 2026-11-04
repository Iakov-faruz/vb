#!/usr/bin/env bash
# Shared, testable helpers for transactional deployment.
#
# --- הסבר בעברית ---
# עזרים משותפים להתקנה טרנזקציונית.
# ספרייה של פונקציות עזר הניתנות לבדיקה, לתהליכי התקנה ומחיקה טרנזקציוניים.
# מבטיחה שפעולות deployment הן אטומיות וניתנות להפיכה, ושמצב המערכת
# נשאר תקין לאורך כל תהליך ההתקנה או המחיקה.

DEPLOY_ROOT="/"
DEPLOY_STAGE=0
DEPLOY_SNAPSHOT_DIR=""
declare -ga DEPLOY_TRACKED_PATHS=()
declare -ga DEPLOY_TRACKED_KINDS=()
declare -ga DEPLOY_CREATED_DIRS=()

deploy_error() {
  printf 'deploy: ERROR: %s\n' "$*" >&2
}

deploy_set_root() {
  local requested="${1:-/}"
  if [[ "$requested" == "/" ]]; then
    DEPLOY_ROOT="/"
    DEPLOY_STAGE=0
    return 0
  fi
  if [[ "$requested" != /* || "$requested" == *"/../"* ||
    "$requested" == */.. || ! -d "$requested" || -L "$requested" ]]; then
    deploy_error "staging root must be an existing absolute, non-symlink directory"
    return 1
  fi
  DEPLOY_ROOT="$(cd -- "$requested" && pwd -P)" || {
    deploy_error "unable to resolve staging root"
    return 1
  }
  if [[ "$DEPLOY_ROOT" == "/" ]]; then
    deploy_error "staging root cannot resolve to /"
    return 1
  fi
  DEPLOY_STAGE=1
}

deploy_path() {
  local path="$1"
  if [[ "$path" != /* || "$path" == *"/../"* || "$path" == */.. ]]; then
    deploy_error "managed path is not a normalized absolute path: $path"
    return 1
  fi
  if [[ "$DEPLOY_ROOT" == "/" ]]; then
    printf '%s\n' "$path"
  else
    printf '%s%s\n' "${DEPLOY_ROOT%/}" "$path"
  fi
}

deploy_expected_owner() {
  if (( DEPLOY_STAGE )); then
    printf '%s:%s\n' "$(id -u)" "$(id -g)"
  else
    printf '0:%s\n' "$1"
  fi
}

deploy_group_id() {
  local group="$1"
  if (( DEPLOY_STAGE )); then
    id -g
  else
    getent group "$group" | awk -F: 'NR == 1 { print $3 }'
  fi
}

deploy_begin_transaction() {
  local temp_base="${TMPDIR:-/tmp}"
  if [[ ! -d "$temp_base" || -L "$temp_base" ]]; then
    deploy_error "temporary directory is unavailable or unsafe"
    return 1
  fi
  DEPLOY_SNAPSHOT_DIR="$(mktemp -d "$temp_base/usbam-deploy.XXXXXX")" || {
    deploy_error "unable to create deployment rollback area"
    return 1
  }
  chmod 700 "$DEPLOY_SNAPSHOT_DIR"
  DEPLOY_TRACKED_PATHS=()
  DEPLOY_TRACKED_KINDS=()
  DEPLOY_CREATED_DIRS=()
}

deploy_track_path() {
  local path="$1"
  local destination index existing
  local i
  for i in "${!DEPLOY_TRACKED_PATHS[@]}"; do
    [[ "${DEPLOY_TRACKED_PATHS[$i]}" == "$path" ]] && return 0
  done
  destination="$(deploy_path "$path")" || return 1
  index="${#DEPLOY_TRACKED_PATHS[@]}"
  if [[ -L "$destination" ]]; then
    deploy_error "refusing to replace symbolic link: $path"
    return 1
  elif [[ -e "$destination" ]]; then
    existing="present"
    if ! cp -a -- "$destination" "$DEPLOY_SNAPSHOT_DIR/$index"; then
      deploy_error "unable to save rollback copy of $path"
      return 1
    fi
  else
    existing="absent"
  fi
  DEPLOY_TRACKED_PATHS+=("$path")
  DEPLOY_TRACKED_KINDS+=("$existing")
}

deploy_ensure_directory() {
  local path="$1" mode="$2" owner="$3" group="$4"
  local destination group_id expected actual
  mode="${mode#0}"
  destination="$(deploy_path "$path")" || return 1
  deploy_ensure_parent "$(dirname -- "$path")" "$owner" "$group" || return 1
  group_id="$(deploy_group_id "$group")" || {
    deploy_error "required group is unavailable: $group"
    return 1
  }
  expected="$(deploy_expected_owner "$group_id"):$mode"

  if [[ -L "$destination" ]]; then
    deploy_error "directory must not be a symbolic link: $path"
    return 1
  fi
  if [[ -e "$destination" ]]; then
    if [[ ! -d "$destination" ]]; then
      deploy_error "path exists but is not a directory: $path"
      return 1
    fi
    actual="$(stat -c '%u:%g:%a' -- "$destination")" || return 1
    if [[ "$actual" != "$expected" ]]; then
      deploy_error "unsafe directory ownership or mode for $path (expected $expected, got $actual)"
      return 1
    fi
    return 0
  fi

  deploy_track_path "$path" || return 1
  if ! install -d -m "$mode" -o "$owner" -g "$group" -- "$destination"; then
    deploy_error "unable to create directory: $path"
    return 1
  fi
  DEPLOY_CREATED_DIRS+=("$path")
}

deploy_ensure_parent() {
  local path="$1" owner="${2:-root}" group="${3:-root}"
  local destination actual actual_owner mode parent
  destination="$(deploy_path "$path")" || return 1
  if [[ -L "$destination" ]]; then
    deploy_error "managed parent is a symbolic link: $path"
    return 1
  fi
  if [[ ! -d "$destination" ]]; then
    if (( ! DEPLOY_STAGE )) || [[ "$path" == "/" ]]; then
      deploy_error "managed parent is missing or not a directory: $path"
      return 1
    fi
    parent="$(dirname -- "$path")"
    deploy_ensure_parent "$parent" "$owner" "$group" || return 1
    deploy_track_path "$path" || return 1
    if ! install -d -m 0755 -o "$owner" -g "$group" -- "$destination"; then
      deploy_error "unable to create staging parent: $path"
      return 1
    fi
    DEPLOY_CREATED_DIRS+=("$path")
  fi
  actual="$(stat -c '%u:%a' -- "$destination")" || return 1
  actual_owner="${actual%%:*}"
  mode="${actual##*:}"
  if (( DEPLOY_STAGE )); then
    [[ "$actual_owner" == "$(id -u)" ]] || {
      deploy_error "staging parent is not owned by the current user: $path"
      return 1
    }
  elif [[ "$actual_owner" != "0" ]]; then
    deploy_error "managed parent must be root-owned and not group/world writable: $path"
    return 1
  elif (( (8#$mode & 0022) != 0 )); then
    if [[ "$path" == "/run/lock" ]] && (( (8#$mode & 01000) != 0 )); then
      return 0
    fi
    deploy_error "managed parent must be root-owned and not group/world writable: $path"
    return 1
  fi
}

deploy_install_file() {
  local source="$1" path="$2" mode="$3" owner="$4" group="$5"
  local destination parent temp group_id
  mode="${mode#0}"
  if [[ -L "$source" || ! -f "$source" || ! -r "$source" ]]; then
    deploy_error "source is missing, unreadable, or not a regular file: $source"
    return 1
  fi
  destination="$(deploy_path "$path")" || return 1
  parent="$(dirname -- "$destination")"
  if [[ ! -d "$parent" || -L "$parent" ]]; then
    deploy_error "destination parent is missing or unsafe: $path"
    return 1
  fi
  if [[ -L "$destination" ]]; then
    deploy_error "refusing to replace symbolic link: $path"
    return 1
  fi
  if [[ -f "$destination" ]] && cmp -s -- "$source" "$destination" &&
    [[ "$(stat -c '%a' -- "$destination")" == "$mode" ]]; then
    group_id="$(deploy_group_id "$group")" || return 1
    if [[ "$(stat -c '%u:%g' -- "$destination")" == "$(deploy_expected_owner "$group_id")" ]]; then
      return 0
    fi
  fi

  deploy_track_path "$path" || return 1
  temp="$(mktemp "$parent/.usbam-install.XXXXXX")" || {
    deploy_error "unable to stage installed file: $path"
    return 1
  }
  group_id="$(deploy_group_id "$group")" || {
    rm -f -- "$temp"
    return 1
  }
  if ! install -m "$mode" -o "$owner" -g "$group" -- "$source" "$temp"; then
    rm -f -- "$temp"
    deploy_error "unable to set installed file permissions: $path"
    return 1
  fi
  if ! mv -f -- "$temp" "$destination"; then
    rm -f -- "$temp"
    deploy_error "unable to atomically install: $path"
    return 1
  fi
}

deploy_rollback() {
  local i path destination
  local failed=0
  for ((i=${#DEPLOY_TRACKED_PATHS[@]}-1; i>=0; i--)); do
    path="${DEPLOY_TRACKED_PATHS[$i]}"
    destination="$(deploy_path "$path")" || { failed=1; continue; }
    if [[ -e "$destination" || -L "$destination" ]]; then
      if ! rm -rf -- "$destination"; then
        deploy_error "rollback could not remove changed path: $path"
        failed=1
        continue
      fi
    fi
    if [[ "${DEPLOY_TRACKED_KINDS[$i]}" == "present" ]]; then
      if ! cp -a -- "$DEPLOY_SNAPSHOT_DIR/$i" "$destination"; then
        deploy_error "rollback could not restore: $path"
        failed=1
      fi
    fi
  done
  for ((i=${#DEPLOY_CREATED_DIRS[@]}-1; i>=0; i--)); do
    path="${DEPLOY_CREATED_DIRS[$i]}"
    destination="$(deploy_path "$path")" || { failed=1; continue; }
    if [[ -d "$destination" ]] && ! rmdir -- "$destination" 2>/dev/null; then
      deploy_error "rollback left non-empty directory in place: $path"
      failed=1
    fi
  done
  if [[ -n "$DEPLOY_SNAPSHOT_DIR" && -d "$DEPLOY_SNAPSHOT_DIR" ]]; then
    if ! rm -rf -- "$DEPLOY_SNAPSHOT_DIR"; then
      deploy_error "unable to remove deployment rollback data"
      failed=1
    fi
  fi
  DEPLOY_SNAPSHOT_DIR=""
  return "$failed"
}

deploy_commit() {
  if [[ -n "$DEPLOY_SNAPSHOT_DIR" && -d "$DEPLOY_SNAPSHOT_DIR" ]]; then
    rm -rf -- "$DEPLOY_SNAPSHOT_DIR" || {
      deploy_error "unable to remove committed deployment rollback data"
      return 1
    }
  fi
  DEPLOY_SNAPSHOT_DIR=""
}
