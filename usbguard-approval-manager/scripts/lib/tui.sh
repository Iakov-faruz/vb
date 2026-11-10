#!/usr/bin/env bash
set -euo pipefail

# USBGuard Approval Manager - TUI whiptail wrappers (Phase 4 - SRS v4.5)
# Provides safe whiptail wrappers with control-char validation
# SEC-01, FR-02 compliant: no source/eval, strict input validation

if [[ -z "${USBAM_TUI_LOADED+x}" ]]; then
  readonly USBAM_TUI_VERSION="1.0.0"
  readonly USBAM_TUI_DEFAULT_HEIGHT=20
  readonly USBAM_TUI_DEFAULT_WIDTH=78
  readonly USBAM_TUI_DEFAULT_MENU_HEIGHT=10
  declare -gr USBAM_TUI_LOADED=1
fi

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
tui_error() {
  printf 'tui: ERROR: %s\n' "$1" >&2
}

tui_has_control_chars() {
  # Returns 0 if contains any control char (including newline, tab, etc.)
  local s="$1"
  [[ "$s" =~ [[:cntrl:]] ]]
}

tui_has_control_chars_except_newline_tab() {
  # Returns 0 if contains control chars other than \n and \t
  # Allows multiline messages in msgbox
  local s="$1"
  local tmp="${s//$'\n'/}"
  tmp="${tmp//$'\t'/}"
  tmp="${tmp//$'\r'/}"  # strip CR, then check remaining
  [[ "$tmp" =~ [[:cntrl:]] ]]
}

tui_validate_no_control() {
  local value="$1"
  local context="${2:-field}"
  if tui_has_control_chars "$value"; then
    tui_error "$context contains control characters"
    return 1
  fi
  if [[ "$value" == -* ]]; then
    tui_error "$context starts with dash (potential option injection)"
    return 1
  fi
  return 0
}

tui_validate_allow_newline() {
  local value="$1"
  local context="${2:-field}"
  if tui_has_control_chars_except_newline_tab "$value"; then
    tui_error "$context contains forbidden control characters"
    return 1
  fi
  # Also forbid leading dash for title but not for body? Check only title elsewhere
  return 0
}

tui_require_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    tui_error "whiptail is not installed or not in PATH"
    return 1
  fi
  return 0
}

tui_validate_positive_int() {
  local val="$1"
  local name="${2:-value}"
  if [[ ! "$val" =~ ^[0-9]+$ ]] || (( val <= 0 )); then
    tui_error "$name must be positive integer, got '$val'"
    return 1
  fi
  return 0
}

tui_sanitize_display() {
  # Sanitize string for safe display in whiptail list: remove control chars, truncate
  local input="$1"
  local max_len="${2:-80}"
  local one_line="${input//$'\n'/ }"
  one_line="${one_line//$'\r'/ }"
  one_line="${one_line//$'\t'/ }"
  # Replace any remaining control chars with ?
  # Use bash pattern replacement in loop for portability
  local cleaned=""
  local i ch
  for ((i=0; i<${#one_line}; i++)); do
    ch="${one_line:i:1}"
    if [[ "$ch" =~ [[:cntrl:]] ]]; then
      cleaned+='?'
    else
      cleaned+="$ch"
    fi
  done
  if (( ${#cleaned} > max_len )); then
    cleaned="${cleaned:0:$((max_len-3))}..."
  fi
  printf '%s' "$cleaned"
}

# ---------------------------------------------------------------------------
# Public whiptail wrappers
# ---------------------------------------------------------------------------

tui_msgbox() {
  # tui_msgbox <title> <message> [height] [width]
  if (( $# < 2 || $# > 4 )); then
    tui_error "tui_msgbox requires title, message, [height], [width]"
    return 2
  fi
  local title="$1"
  local message="$2"
  local height="${3:-$USBAM_TUI_DEFAULT_HEIGHT}"
  local width="${4:-$USBAM_TUI_DEFAULT_WIDTH}"

  if ! tui_validate_no_control "$title" "msgbox title"; then return 1; fi
  if ! tui_validate_allow_newline "$message" "msgbox message"; then return 1; fi
  if ! tui_validate_positive_int "$height" "height"; then return 1; fi
  if ! tui_validate_positive_int "$width" "width"; then return 1; fi
  if ! tui_require_whiptail; then return 1; fi

  local rc
  set +e
  whiptail --title "$title" --msgbox "$message" "$height" "$width"
  rc=$?
  set -e
  return $rc
}

tui_yesno() {
  # tui_yesno <title> <question> [height] [width] -> 0=yes, 1=no, 255=cancel/esc
  if (( $# < 2 || $# > 4 )); then
    tui_error "tui_yesno requires title, question, [height], [width]"
    return 2
  fi
  local title="$1"
  local question="$2"
  local height="${3:-$USBAM_TUI_DEFAULT_HEIGHT}"
  local width="${4:-$USBAM_TUI_DEFAULT_WIDTH}"

  if ! tui_validate_no_control "$title" "yesno title"; then return 1; fi
  if ! tui_validate_allow_newline "$question" "yesno question"; then return 1; fi
  if ! tui_validate_positive_int "$height" "height"; then return 1; fi
  if ! tui_validate_positive_int "$width" "width"; then return 1; fi
  if ! tui_require_whiptail; then return 1; fi

  local rc
  set +e
  whiptail --title "$title" --yesno "$question" "$height" "$width"
  rc=$?
  set -e
  return $rc
}

tui_inputbox() {
  # tui_inputbox <title> <prompt> [height] [width] [default]
  # Prints user input to stdout, returns whiptail exit code
  if (( $# < 2 || $# > 5 )); then
    tui_error "tui_inputbox requires title, prompt, [height], [width], [default]"
    return 2
  fi
  local title="$1"
  local prompt="$2"
  local height="${3:-$USBAM_TUI_DEFAULT_HEIGHT}"
  local width="${4:-$USBAM_TUI_DEFAULT_WIDTH}"
  local default_value="${5:-}"

  if ! tui_validate_no_control "$title" "inputbox title"; then return 1; fi
  if ! tui_validate_allow_newline "$prompt" "inputbox prompt"; then return 1; fi
  if ! tui_validate_positive_int "$height" "height"; then return 1; fi
  if ! tui_validate_positive_int "$width" "width"; then return 1; fi
  if [[ -n "$default_value" ]] && tui_has_control_chars "$default_value"; then
    tui_error "inputbox default contains control characters"
    return 1
  fi
  if ! tui_require_whiptail; then return 1; fi

  local result rc
  set +e
  result=$(whiptail --title "$title" --inputbox "$prompt" "$height" "$width" "$default_value" 3>&1 1>&2 2>&3)
  rc=$?
  set -e

  if (( rc == 0 )); then
    if tui_has_control_chars "$result"; then
      tui_error "input contains control characters - rejected"
      return 1
    fi
    printf '%s' "$result"
  fi
  return $rc
}

tui_menu() {
  # tui_menu <title> <prompt> <height> <width> <menu_height> <tag> <item> ...
  # Prints selected tag to stdout
  if (( $# < 6 )); then
    tui_error "tui_menu requires title, prompt, height, width, menu_height, tag/item pairs"
    return 2
  fi
  local title="$1"
  local prompt="$2"
  local height="$3"
  local width="$4"
  local menu_height="$5"
  shift 5

  if (( $# % 2 != 0 )); then
    tui_error "tui_menu requires even number of tag/item arguments"
    return 1
  fi

  if ! tui_validate_no_control "$title" "menu title"; then return 1; fi
  if ! tui_validate_allow_newline "$prompt" "menu prompt"; then return 1; fi
  if ! tui_validate_positive_int "$height" "height"; then return 1; fi
  if ! tui_validate_positive_int "$width" "width"; then return 1; fi
  if ! tui_validate_positive_int "$menu_height" "menu_height"; then return 1; fi
  if ! tui_require_whiptail; then return 1; fi

  local -a items=("$@")
  local tag item
  local idx=0
  while (( idx < ${#items[@]} )); do
    tag="${items[idx]}"
    item="${items[idx+1]}"
    if ! tui_validate_no_control "$tag" "menu tag"; then return 1; fi
    # item may be multiline? For menu, we forbid control but allow spaces
    if tui_has_control_chars "$item"; then
      tui_error "menu item contains control characters: tag=$tag"
      return 1
    fi
    idx=$((idx+2))
  done

  local result rc
  set +e
  result=$(whiptail --title "$title" --menu "$prompt" "$height" "$width" "$menu_height" "${items[@]}" 3>&1 1>&2 2>&3)
  rc=$?
  set -e

  if (( rc == 0 )); then
    printf '%s' "$result"
  fi
  return $rc
}

tui_checklist() {
  # tui_checklist <title> <prompt> <height> <width> <list_height> <tag> <item> <status> ...
  # Status ON/OFF. Prints selected tags (space-separated, quoted by whiptail) to stdout
  if (( $# < 6 )); then
    tui_error "tui_checklist requires title, prompt, height, width, list_height, tag/item/status triples"
    return 2
  fi
  local title="$1"
  local prompt="$2"
  local height="$3"
  local width="$4"
  local list_height="$5"
  shift 5

  if (( $# % 3 != 0 )); then
    tui_error "tui_checklist requires triples of tag/item/status"
    return 1
  fi

  if ! tui_validate_no_control "$title" "checklist title"; then return 1; fi
  if ! tui_validate_allow_newline "$prompt" "checklist prompt"; then return 1; fi
  if ! tui_validate_positive_int "$height" "height"; then return 1; fi
  if ! tui_validate_positive_int "$width" "width"; then return 1; fi
  if ! tui_validate_positive_int "$list_height" "list_height"; then return 1; fi
  if ! tui_require_whiptail; then return 1; fi

  local -a entries=("$@")
  local tag item status
  local idx=0
  while (( idx < ${#entries[@]} )); do
    tag="${entries[idx]}"
    item="${entries[idx+1]}"
    status="${entries[idx+2]}"
    if ! tui_validate_no_control "$tag" "checklist tag"; then return 1; fi
    if tui_has_control_chars "$item"; then
      tui_error "checklist item contains control characters: tag=$tag"
      return 1
    fi
    if [[ "$status" != "ON" && "$status" != "OFF" ]]; then
      tui_error "checklist status must be ON or OFF, got '$status'"
      return 1
    fi
    idx=$((idx+3))
  done

  local result rc
  set +e
  result=$(whiptail --title "$title" --checklist "$prompt" "$height" "$width" "$list_height" "${entries[@]}" 3>&1 1>&2 2>&3)
  rc=$?
  set -e

  if (( rc == 0 )); then
    printf '%s' "$result"
  fi
  return $rc
}

tui_radiolist() {
  # tui_radiolist <title> <prompt> <height> <width> <list_height> <tag> <item> <status> ...
  if (( $# < 6 )); then
    tui_error "tui_radiolist requires title, prompt, height, width, list_height, tag/item/status triples"
    return 2
  fi
  local title="$1"
  local prompt="$2"
  local height="$3"
  local width="$4"
  local list_height="$5"
  shift 5

  if (( $# % 3 != 0 )); then
    tui_error "tui_radiolist requires triples"
    return 1
  fi

  if ! tui_validate_no_control "$title" "radiolist title"; then return 1; fi
  if ! tui_validate_allow_newline "$prompt" "radiolist prompt"; then return 1; fi
  if ! tui_validate_positive_int "$height" "height"; then return 1; fi
  if ! tui_validate_positive_int "$width" "width"; then return 1; fi
  if ! tui_validate_positive_int "$list_height" "list_height"; then return 1; fi
  if ! tui_require_whiptail; then return 1; fi

  local -a entries=("$@")
  local tag item status
  local idx=0
  while (( idx < ${#entries[@]} )); do
    tag="${entries[idx]}"
    item="${entries[idx+1]}"
    status="${entries[idx+2]}"
    if ! tui_validate_no_control "$tag" "radiolist tag"; then return 1; fi
    if tui_has_control_chars "$item"; then
      tui_error "radiolist item contains control characters: tag=$tag"
      return 1
    fi
    if [[ "$status" != "ON" && "$status" != "OFF" ]]; then
      tui_error "radiolist status must be ON or OFF"
      return 1
    fi
    idx=$((idx+3))
  done

  local result rc
  set +e
  result=$(whiptail --title "$title" --radiolist "$prompt" "$height" "$width" "$list_height" "${entries[@]}" 3>&1 1>&2 2>&3)
  rc=$?
  set -e

  if (( rc == 0 )); then
    printf '%s' "$result"
  fi
  return $rc
}

# Self-test when run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "tui.sh version $USBAM_TUI_VERSION - whiptail wrappers with control-char validation"
fi
