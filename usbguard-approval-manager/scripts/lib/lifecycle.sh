#!/usr/bin/env bash
# Shared Phase 5 data handling. Persistent rules are read only from configured,
# non-system policy sources and are limited to validated allow rules.
#
# --- הסבר בעברית ---
# טיפול שלב 5 משותף בנתונים מתמשכים. כללי קבע נקראים אך ורק ממקורות
# מדיניות מוגדרים שאינם מערכתיים ומוגבלים לכללים מאומן של allow.
# ספרייה אחראית על איסוף, אימות וייצוא כללי קבע בתקינה SEC-16.

USBAM_LIFECYCLE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
USBAM_LIFECYCLE_HELPER="$USBAM_LIFECYCLE_LIB_DIR/lifecycle.py"

# --- lifecycle: הדפסת שגיאה ---
lifecycle_error() {
  printf 'lifecycle: ERROR: %s\n' "$*" >&2
}

# --- lifecycle: דרישת عدم journal ---
# אם restore journal קיים ⇒ mutations חסומות.
lifecycle_require_no_journal() {
  if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
    lifecycle_error "restore journal exists; run restore-rules.sh --recover first"
    return 1
  fi
}

# --- lifecycle: איסוף export JSON ---
# קורא policy sources + TTL, מאמת, מסדר, מדפיס JSON.
lifecycle_collect_export_json() {
  local work_dir policy_path policy_file candidate basename line canonical
  local ttl_records permanent_json normalized_output
  local -a source_files=()
  local -a permanent_rules=()

  if ! get_persistent_policy_paths; then
    lifecycle_error "persistent policy sources are unavailable"
    return 1
  fi
  if [[ -n "${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]:-}" ]]; then
    source_files+=("${USBAM_PERSISTENT_POLICY_PATHS[RuleFile]}")
  fi
  if [[ -n "${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]:-}" ]]; then
    policy_path="${USBAM_PERSISTENT_POLICY_PATHS[RuleFolder]}"
    if [[ "$(stat -c '%u' -- "$policy_path")" != "0" ]] ||
      (( (8#$(stat -c '%a' -- "$policy_path") & 0022) != 0 )); then
      lifecycle_error "RuleFolder ownership or permissions are unsafe"
      return 1
    fi
    work_dir="$(mktemp -d)" || {
      lifecycle_error "unable to create a private staging directory"
      return 1
    }
    chmod 700 "$work_dir" || {
      rmdir "$work_dir" 2>/dev/null || true
      lifecycle_error "unable to secure the staging directory"
      return 1
    }
    if ! find "$policy_path" -mindepth 1 -maxdepth 1 -print0 > "$work_dir/files"; then
      rm -rf -- "$work_dir"
      lifecycle_error "unable to enumerate RuleFolder"
      return 1
    fi
    while IFS= read -r -d '' candidate; do
      basename="${candidate##*/}"
      if [[ -L "$candidate" ]]; then
        rm -rf -- "$work_dir"
        lifecycle_error "RuleFolder contains a symbolic link"
        return 1
      fi
      if [[ "$basename" == "00-system.rules" ]]; then
        continue
      fi
      if [[ ! -f "$candidate" ]]; then
        rm -rf -- "$work_dir"
        lifecycle_error "RuleFolder contains an unexpected non-file entry"
        return 1
      fi
      source_files+=("$candidate")
    done < "$work_dir/files"
    rm -rf -- "$work_dir"
  fi

  for policy_file in "${source_files[@]}"; do
    if [[ -L "$policy_file" || ! -f "$policy_file" || ! -r "$policy_file" ]]; then
      lifecycle_error "persistent policy source is unsafe or unreadable"
      return 1
    fi
    if [[ "$(stat -c '%u' -- "$policy_file")" != "0" ]] ||
      (( (8#$(stat -c '%a' -- "$policy_file") & 0022) != 0 )); then
      lifecycle_error "persistent policy file ownership or permissions are unsafe"
      return 1
    fi
    basename="${policy_file##*/}"
    if [[ "$basename" == "00-system.rules" ]]; then
      continue
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ [[:cntrl:]] ]]; then
        lifecycle_error "persistent policy contains a control character"
        return 1
      fi
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      if ! usbguard_validate_rule "$line"; then
        lifecycle_error "persistent policy contains an invalid rule"
        return 1
      fi
      canonical="$(usbguard_canonicalize_rule "$line")"
      if [[ "$canonical" == allow\ * ]]; then
        permanent_rules+=("$canonical")
      fi
    done < "$policy_file"
  done

  work_dir="$(mktemp -d)" || {
    lifecycle_error "unable to create a private export staging directory"
    return 1
  }
  chmod 700 "$work_dir" || {
    rmdir "$work_dir" 2>/dev/null || true
    lifecycle_error "unable to secure the export staging directory"
    return 1
  }
  : > "$work_dir/permanent.rules"
  if (( ${#permanent_rules[@]} )); then
    printf '%s\n' "${permanent_rules[@]}" | LC_ALL=C sort -u > "$work_dir/permanent.rules" || {
      rm -rf -- "$work_dir"
      lifecycle_error "unable to stage permanent rules"
      return 1
    }
  fi
  if ! permanent_json="$(jq -Rsc 'split("\n") | map(select(length > 0))' \
    "$work_dir/permanent.rules")"; then
    rm -rf -- "$work_dir"
    lifecycle_error "unable to serialize permanent rules"
    return 1
  fi
  ttl_records='[]'
  if [[ -e "$TTL_FILE" || -L "$TTL_FILE" ]]; then
    if ! validate_ttl_json "$TTL_FILE"; then
      rm -rf -- "$work_dir"
      lifecycle_error "ttl.json is invalid"
      return 1
    fi
    if [[ -L "$TTL_FILE" || ! -f "$TTL_FILE" ]]; then
      rm -rf -- "$work_dir"
      lifecycle_error "ttl.json is not a regular file"
      return 1
    fi
    if ! ttl_records="$(jq -ce '
      [.records[] | select(.status == "active") | {rule: .rule, expires_at: .expires_at}]
    ' "$TTL_FILE")"; then
      rm -rf -- "$work_dir"
      lifecycle_error "unable to stage active TTL records"
      return 1
    fi
    while IFS=$'\t' read -r line _; do
      [[ -n "$line" ]] || continue
      if ! usbguard_validate_rule "$line" || [[ "$line" != allow\ * ]] ||
        [[ "$(usbguard_canonicalize_rule "$line")" != "$line" ]]; then
        rm -rf -- "$work_dir"
        lifecycle_error "active TTL contains an invalid or non-canonical rule"
        return 1
      fi
    done < <(jq -r '
      .records[] | select(.status == "active") | [.rule, .expires_at] | @tsv
    ' "$TTL_FILE")
  fi
  if ! jq -cn --argjson permanent "$permanent_json" --argjson ttl "$ttl_records" \
    '{schema_version:1,permanent_rules:$permanent,ttl_records:$ttl}' > "$work_dir/export.json"; then
    rm -rf -- "$work_dir"
    lifecycle_error "unable to serialize export"
    return 1
  fi
  if ! normalized_output="$("$PYTHON3" "$USBAM_LIFECYCLE_HELPER" \
    validate-export --file "$work_dir/export.json")"; then
    rm -rf -- "$work_dir"
    return 1
  fi
  rm -rf -- "$work_dir"
  printf '%s\n' "$normalized_output"
}
