#!/usr/bin/env bash
# Secure, data-only reader for the approved SRS v4.5 configuration keys.
#
# --- הסבר בעברית ---
# קורא תצורה מאובטח (data-only) למפתחות SRS v4.5.
# קורא קובץ config (key=value), מאמת keys/types/ranges, ממלא defaults.
# תומך integer + enum. דוחה NUL, control chars, unknown/duplicate keys.
# מאפשר קריאה בטוחה של הגדרות ללא חשיפת מידע רגיש.
#
# CONFIG_KEY_SPECS מגדיר type|default|min|max לכל key.
"
# Secure, data-only reader for the approved SRS v4.5 configuration keys.

if [[ "$(declare -p CONFIG_READER_LOADED 2>/dev/null || true)" != \
  "declare -r CONFIG_READER_LOADED="* ]]; then
  readonly CONFIG_READER_VERSION="1.2.0"

  # Format: type|default|min|max. Empty bounds mean "not constrained".
  declare -grA CONFIG_KEY_SPECS=(
    ["TEMP_TTL_SECONDS"]="integer|3600|60|2592000"
    ["MIN_REASONABLE_EPOCH"]="integer|1577836800||"
    ["MAX_CLOCK_JUMP_SECONDS"]="integer|3600|60|86400"
    ["BACKUP_KEEP"]="integer|5|1|100"
    ["IPC_TIMEOUT_SECONDS"]="integer|5|1|60"
    ["LOG_LEVEL"]="enum:DEBUG,INFO,WARNING,ERROR|INFO||"
  )
  declare -gA CONFIG_VALUES=()
  declare -gr CONFIG_READER_LOADED=1
fi

# --- config: הדפסת שגיאה ---
config_error() {
  local line_number="$1"
  shift
  printf 'config-reader: ERROR: line %s: %s\n' "$line_number" "$*" >&2
  # הסבר: מדפיס הודעת שגיאה עם מספר שורה וממשיך לאיפוס CONFIG_VALUES
}

# --- config: נרמול עשרוני (הסרת אפסים מובילים) ---
config_normalize_decimal() {
  # מסירה אפסים מובילים ממספר Decimal - שומרת על ערך אחד לפחות
  local value="$1"
  while [[ "${#value}" -gt 1 && "${value:0:1}" == "0" ]]; do
    value="${value:1}"
  done
  printf '%s' "$value"
}

# --- config: השוואת עשרוניים (a < b) ---
config_decimal_less_than() {
  # משווה שני ערכים Decimal כנumbers (לא כטקסט) - מחזירה 0 אם left < right
  local left right
  left="$(config_normalize_decimal "$1")"
  right="$(config_normalize_decimal "$2")"

  if [[ "${#left}" -lt "${#right}" ]]; then
    return 0
  fi
  if [[ "${#left}" -gt "${#right}" ]]; then
    return 1
  fi
  [[ "$left" < "$right" ]]
}

# --- config: trim רווחים ---
config_trim() {
  #�רת רווחים מיותרים מתחילת ובסוף מחרוזת
  local value="$1"

  if [[ "$value" =~ ^[[:space:]]*$ ]]; then
    printf ''
    return 0
  fi

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# --- config: טעינה ואימות ---
# קורא קובץ, מאמת keys/types/ranges, ממלא defaults ל-CONFIG_VALUES.
load_config() {
  # טוענת ומאמתת קובץ configuration - מעבירה על כל שורה, מאמתת מפתחות, Types וערכים
  local LC_ALL=C
  local file_path line_number raw_line key value spec
  local value_type default_value min_value max_value
  local nul_probe
  local -A parsed_values=()

  if [[ "$#" -ne 1 || -z "$1" ]]; then
    printf 'config-reader: ERROR: load_config requires one file path\n' >&2
    CONFIG_VALUES=()
    return 1
  fi
  file_path="$1"

  if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
    printf 'config-reader: ERROR: config file is missing or unreadable\n' >&2
    CONFIG_VALUES=()
    return 1
  fi

  # Bash variables cannot represent NUL bytes, so detect them before parsing.
  # משתני Bash לא יכולים לייצג Bytes NUL, לכן מזהים אותם לפני parsing.
  if IFS= read -r -d '' nul_probe < "$file_path"; then
    printf 'config-reader: ERROR: config file contains a NUL byte\n' >&2
    CONFIG_VALUES=()
    return 1
  fi

  line_number=0
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line_number=$((line_number + 1))

    if [[ "$raw_line" =~ [[:cntrl:]] ]]; then
      config_error "$line_number" "control characters are not allowed"
      CONFIG_VALUES=()
      return 1
    fi

    raw_line="$(config_trim "$raw_line")"
    if [[ -z "$raw_line" || "$raw_line" == \#* ]]; then
      continue
    fi
    if [[ "$raw_line" != *"="* ]]; then
      config_error "$line_number" "missing '=' separator"
      CONFIG_VALUES=()
      return 1
    fi

    key="$(config_trim "${raw_line%%=*}")"
    value="$(config_trim "${raw_line#*=}")"

    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      config_error "$line_number" "invalid key name"
      CONFIG_VALUES=()
      return 1
    fi
    if [[ -z "${CONFIG_KEY_SPECS[$key]+present}" ]]; then
      config_error "$line_number" "unknown key '$key'"
      CONFIG_VALUES=()
      return 1
    fi
    if [[ -z "${parsed_values[$key]+present}" ]]; then
      config_error "$line_number" "duplicate key '$key'"
      CONFIG_VALUES=()
      return 1
    fi

    IFS='|' read -r value_type default_value min_value max_value \
      <<< "${CONFIG_KEY_SPECS[$key]}"
    case "$value_type" in
      integer)
        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
          config_error "$line_number" "value for '$key' must be a non-negative integer"
          CONFIG_VALUES=()
          return 1
        fi
        if [[ -n "$min_value" ]] && config_decimal_less_than "$value" "$min_value"; then
          config_error "$line_number" "value for '$key' is below its minimum"
          CONFIG_VALUES=()
          return 1
        fi
        if [[ -n "$max_value" ]] && config_decimal_less_than "$max_value" "$value"; then
          config_error "$line_number" "value for '$key' is above its maximum"
          CONFIG_VALUES=()
          return 1
        fi
        ;;
      enum:*)
        local allowed_values="${value_type#enum:}"
        case ",$allowed_values," in
          *,"$value",*) ;;
          *)
            config_error "$line_number" "value for '$key' is not an allowed option"
            CONFIG_VALUES=()
            return 1
            ;;
        esac
        ;;
      *)
        config_error "$line_number" "unsupported configuration type for '$key'"
        CONFIG_VALUES=()
        return 1
        ;;
    esac

    parsed_values["$key"]="$(config_normalize_decimal "$value")"
  done < "$file_path"

  for key in "${!CONFIG_KEY_SPECS[@]}"; do
    if [[ -z "${parsed_values[$key]+present}" ]]; then
      IFS='|' read -r value_type default_value _ <<< "${CONFIG_KEY_SPECS[$key]}"
      parsed_values["$key"]="$default_value"
    fi
  done

  CONFIG_VALUES=()
  for key in "${!parsed_values[@]}"; do
    CONFIG_VALUES["$key"]="${parsed_values[$key]}"
  done
}

# --- config: קבלת ערך ---
get_config() {
  # מחזירה ערך Configuration לפי מפתח - מחזירה את הערך או מחזירה 1 אם המפתח אינו קיים
  if [[ "$#" -ne 1 || -z "$1" ]]; then
    printf 'config-reader: ERROR: get_config requires one key\n' >&2
    return 1
  fi

  local key="$1"
  if [[ -n "${CONFIG_VALUES[$key]+present}" ]]; then
    printf '%s\n' "${CONFIG_VALUES[$key]}"
    return 0
  fi
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'config-reader.sh version %s\n' "$CONFIG_READER_VERSION"
  printf 'Usage: source this library and call load_config(path)\n'
fi
