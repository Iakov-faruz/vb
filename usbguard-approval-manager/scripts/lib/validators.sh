#!/usr/bin/env bash
# validators.sh - TTL JSON schema validation (SRS v4.5 Section 13, UT-06)
# Validates ttl.json and clock_state.json handling

if [[ -z "${USBAM_VALIDATORS_LOADED+x}" ]]; then
  readonly USBAM_VALIDATORS_VERSION="1.0.0"
  readonly USBAM_VALIDATORS_JSON_HELPER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/atomic-write.py"
  declare -g VALIDATORS_ERROR=""
  declare -g VALIDATORS_ERROR_CODE=""
  declare -gr USBAM_VALIDATORS_LOADED=1
fi

validators_error() {
  VALIDATORS_ERROR="$1"
  VALIDATORS_ERROR_CODE="${2:-validation_failed}"
  printf 'validators: ERROR: %s\n' "$1" >&2
}

validators_is_uuid_v4() {
  local uuid="$1"
  # UUID v4 pattern: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx where y is 8,9,a,b
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validators_is_sha256() {
  local hash="$1"
  [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]]
}

# Compute SHA256 of rule - must match usbguard-policy implementation
validators_hash_rule() {
  local rule="$1"
  local canonical
  # Trim like usbguard_canonicalize_rule
  canonical="${rule#"${rule%%[![:space:]]*}"}"
  canonical="${canonical%"${canonical##*[![:space:]]}"}"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$canonical" | sha256sum | awk '{print $1}'
  else
    python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest())" "$canonical"
  fi
}

validate_ttl_json() {
  local file_path="$1"
  VALIDATORS_ERROR=""
  VALIDATORS_ERROR_CODE=""

  if (( $# != 1 )); then
    validators_error "validate_ttl_json requires exactly one file path" "invalid_arguments"
    return 1
  fi

  if [[ ! -f "$file_path" ]]; then
    # Missing file is treated as empty valid state if no records? But per spec, missing with live records -> recovery_required
    # For validation, missing file is considered valid empty if caller handles it
    # We return 0 with empty, but log
    if [[ ! -e "$file_path" ]]; then
      return 0
    fi
    validators_error "ttl.json is not a regular file" "not_regular_file"
    return 1
  fi

  if [[ -L "$file_path" ]]; then
    validators_error "ttl.json is a symlink - refusing" "symlink_not_allowed"
    return 1
  fi

  local json_error
  if ! json_error="$(python3 "$USBAM_VALIDATORS_JSON_HELPER" \
    --file "$file_path" --validate-only 2>&1)"; then
    validators_error "ttl.json is not valid JSON: $json_error" "invalid_json"
    return 1
  fi

  if ! jq -e '
    if (.schema_version | type) == "number" then
      .schema_version == 1 and .schema_version == (.schema_version | floor)
    else
      false
    end
  ' "$file_path" >/dev/null 2>&1; then
    validators_error "schema_version must be the integer 1" "invalid_schema_version"
    return 1
  fi

  # Check records is array
  if ! jq -e '.records | type == "array"' "$file_path" >/dev/null 2>&1; then
    validators_error "records must be an array" "invalid_records_type"
    return 1
  fi

  # Check for duplicate keys (jq doesn't catch by default, but we can use python helper if needed)
  # Use atomic-write.py validation which already rejects duplicate keys via python

  local record_count
  record_count="$(jq '.records | length' "$file_path")"
  if [[ ! "$record_count" =~ ^[0-9]+$ ]]; then
    validators_error "unable to determine records count" "invalid_records"
    return 1
  fi

  # Validate each record
  local i
  for ((i=0; i<record_count; i++)); do
    if ! jq -e --argjson i "$i" '
      .records[$i] |
      if type != "object" then
        false
      else
        (.managed_id | type) == "string" and
        (.rule | type) == "string" and
        (.rule | explode | all(. >= 32 and . != 127)) and
        (.rule_sha256 | type) == "string" and
        (.status | type) == "string" and
        (.correlation_id | type) == "string" and
        (if (.expires_at | type) == "number" then
          .expires_at == (.expires_at | floor) and
          .expires_at > 0 and
          .expires_at <= 253402300799
        else
          false
        end)
      end
    ' "$file_path" >/dev/null 2>&1; then
      validators_error "record $i has an invalid JSON type or expiration range" "invalid_field_type"
      return 1
    fi

    # Check required fields - exactly 6 fields per spec
    local field_count
    field_count="$(jq -r ".records[$i] | keys | length" "$file_path")"
    if (( field_count != 6 )); then
      validators_error "record $i must have exactly 6 fields, got $field_count" "invalid_field_count"
      return 1
    fi

    # Check no extra fields beyond allowed set
    local has_extra
    has_extra="$(jq -r ".records[$i] | keys | map(select(. != \"managed_id\" and . != \"rule\" and . != \"rule_sha256\" and . != \"expires_at\" and . != \"status\" and . != \"correlation_id\")) | length" "$file_path")"
    if [[ "$has_extra" != "0" ]]; then
      validators_error "record $i contains extra fields not in schema" "extra_fields"
      return 1
    fi

    # managed_id must be UUID v4
    local managed_id
    managed_id="$(jq -r ".records[$i].managed_id // empty" "$file_path")"
    if ! validators_is_uuid_v4 "$managed_id"; then
      validators_error "record $i managed_id is not valid UUID v4: $managed_id" "invalid_managed_id"
      return 1
    fi

    # correlation_id UUID v4
    local correlation_id
    correlation_id="$(jq -r ".records[$i].correlation_id // empty" "$file_path")"
    if ! validators_is_uuid_v4 "$correlation_id"; then
      validators_error "record $i correlation_id is not valid UUID v4: $correlation_id" "invalid_correlation_id"
      return 1
    fi

    # rule must be non-empty string, no control chars, must start with allow/block/reject
    local rule
    rule="$(jq -r ".records[$i].rule // empty" "$file_path")"
    if [[ -z "$rule" ]]; then
      validators_error "record $i rule is empty" "invalid_rule"
      return 1
    fi
    if printf "%s" "$rule" | LC_ALL=C grep -q "[[:cntrl:]]"; then
      validators_error "record $i rule contains control characters" "invalid_rule"
      return 1
    fi
    if [[ ! "$rule" =~ ^(allow|block|reject)[[:space:]] ]]; then
      validators_error "record $i rule must start with allow, block or reject" "invalid_rule"
      return 1
    fi
    if [[ "$rule" == *"00-system.rules"* ]]; then
      validators_error "record $i rule references protected 00-system.rules" "protected_policy"
      return 1
    fi

    # rule_sha256 must be 64 hex and match hash of rule
    local rule_sha256 expected_hash
    rule_sha256="$(jq -r ".records[$i].rule_sha256 // empty" "$file_path")"
    if ! validators_is_sha256 "$rule_sha256"; then
      validators_error "record $i rule_sha256 is not valid SHA256: $rule_sha256" "invalid_hash"
      return 1
    fi
    expected_hash="$(validators_hash_rule "$rule")"
    # Compare case-insensitive
    if [[ "${rule_sha256,,}" != "${expected_hash,,}" ]]; then
      validators_error "record $i rule_sha256 mismatch: expected $expected_hash, got $rule_sha256" "hash_mismatch"
      return 1
    fi

    # expires_at must be a positive, representable integer
    local expires_at
    expires_at="$(jq -r ".records[$i].expires_at // empty" "$file_path")"
    if [[ ! "$expires_at" =~ ^[0-9]+$ ]] ||
      (( expires_at <= 0 || expires_at > 253402300799 )); then
      validators_error "record $i expires_at must be positive integer, got $expires_at" "invalid_expires_at"
      return 1
    fi

    # status must be one of allowed
    local status
    status="$(jq -r ".records[$i].status // empty" "$file_path")"
    case "$status" in
      pending|active|inconsistent|recovery_required|expired)
        ;;
      *)
        validators_error "record $i status invalid: $status" "invalid_status"
        return 1
        ;;
    esac
  done

  # Check duplicate managed_id
  local duplicate_ids
  duplicate_ids="$(jq -r '.records | map(.managed_id) | group_by(.) | map(select(length>1)) | length' "$file_path")"
  if [[ "$duplicate_ids" != "0" ]]; then
    validators_error "duplicate managed_id found" "duplicate_managed_id"
    return 1
  fi

  # Check duplicate correlation_id? Not required to be unique per spec, but check if needed
  # For now allow duplicates but log? Spec says each record has correlation_id uuid, should be unique per operation
  # We won't enforce uniqueness for correlation_id as it may be reused in retries? But per spec new IDs on import, so we enforce uniqueness as safety
  local duplicate_corr
  duplicate_corr="$(jq -r '.records | map(.correlation_id) | group_by(.) | map(select(length>1)) | length' "$file_path")"
  if [[ "$duplicate_corr" != "0" ]]; then
    # Not fatal per spec, but warn - for strictness we fail
    validators_error "duplicate correlation_id found" "duplicate_correlation_id"
    return 1
  fi

  return 0
}

validate_ttl_record_transition() {
  local from_status="$1"
  local to_status="$2"

  if (( $# != 2 )); then
    validators_error "validate_ttl_record_transition requires from and to status" "invalid_arguments"
    return 1
  fi

  case "$from_status:$to_status" in
    pending:active|pending:inconsistent|pending:recovery_required)
      return 0
      ;;
    active:expired|active:inconsistent|active:recovery_required)
      return 0
      ;;
    inconsistent:recovery_required|inconsistent:active|inconsistent:expired)
      # inconsistent -> active/expired only after verified recovery
      return 0
      ;;
    recovery_required:active|recovery_required:expired|recovery_required:inconsistent)
      # Only after explicit documented admin action
      return 0
      ;;
    expired:expired)
      # expired is final, but self-transition allowed for idempotency check
      return 0
      ;;
    *)
      validators_error "transition $from_status -> $to_status not allowed" "invalid_transition"
      return 1
      ;;
  esac
}

has_non_expired_records() {
  local file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    printf 'no\n'
    return 0
  fi
  if ! validate_ttl_json "$file_path" 2>/dev/null; then
    printf 'yes\n'  # Corrupt file with potential records -> treat as having records for safety
    return 0
  fi
  local count
  count="$(jq '[.records[] | select(.status != "expired")] | length' "$file_path" 2>/dev/null || echo 1)"
  if (( count > 0 )); then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# Helper to generate UUID v4
generate_uuid_v4() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

# Helper to get current epoch
validators_get_epoch() {
  date +%s
}
