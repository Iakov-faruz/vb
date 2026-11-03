#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/validators.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
pass() {
  printf 'PASS: %s\n' "$1"
}

# Helper to create ttl.json
create_valid_ttl() {
  local file="$1"
  local managed_id="11111111-1111-4111-8111-111111111111"
  local corr_id="22222222-2222-4222-8222-222222222222"
  local rule="allow id 1234:5678 serial \"TEST\""
  local hash
  hash="$(validators_hash_rule "$rule")"
  jq -n \
    --arg managed_id "$managed_id" \
    --arg correlation_id "$corr_id" \
    --arg rule "$rule" \
    --arg rule_sha256 "$hash" \
    '{
      schema_version: 1,
      records: [{
        managed_id: $managed_id,
        rule: $rule,
        rule_sha256: $rule_sha256,
        expires_at: 9999999999,
        status: "active",
        correlation_id: $correlation_id
      }]
    }' > "$file"
}

# Test 1: valid file
TTL="$TEST_DIR/ttl.json"
create_valid_ttl "$TTL"
validate_ttl_json "$TTL" || fail "valid ttl should pass"
pass "valid ttl.json passes"

# Test 2: invalid schema_version
jq '.schema_version = 2' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "invalid schema_version accepted"
fi
pass "invalid schema_version rejected"
create_valid_ttl "$TTL"

# Test 3: extra field
jq '.records[0].extra = "oops"' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "extra field accepted"
fi
pass "extra field rejected"
create_valid_ttl "$TTL"

# Test 4: JSON types are strict
jq '.schema_version = "1"' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "string schema_version accepted"
fi
pass "string schema_version rejected"
create_valid_ttl "$TTL"
jq '.records[0].expires_at = "9999999999"' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "string expires_at accepted"
fi
pass "string expires_at rejected"
create_valid_ttl "$TTL"

# Test 4: invalid UUID
jq '.records[0].managed_id = "not-uuid"' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "invalid UUID accepted"
fi
pass "invalid UUID rejected"
create_valid_ttl "$TTL"

# Test 5: hash mismatch
jq '.records[0].rule_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "hash mismatch accepted"
fi
pass "hash mismatch rejected"
create_valid_ttl "$TTL"

# Test 6: duplicate managed_id
cat > "$TTL" <<EOF
{
  "schema_version": 1,
  "records": [
    {
      "managed_id": "11111111-1111-4111-8111-111111111111",
      "rule": "allow id 1234:5678",
      "rule_sha256": "$(validators_hash_rule 'allow id 1234:5678')",
      "expires_at": 9999999999,
      "status": "active",
      "correlation_id": "22222222-2222-4222-8222-222222222222"
    },
    {
      "managed_id": "11111111-1111-4111-8111-111111111111",
      "rule": "allow id 1234:5678",
      "rule_sha256": "$(validators_hash_rule 'allow id 1234:5678')",
      "expires_at": 9999999999,
      "status": "active",
      "correlation_id": "33333333-3333-4333-8333-333333333333"
    }
  ]
}
EOF
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "duplicate managed_id accepted"
fi
pass "duplicate managed_id rejected"

# Test duplicate JSON object keys
printf '{"schema_version":1,"schema_version":1,"records":[]}\n' > "$TTL"
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "duplicate JSON key accepted"
fi
pass "duplicate JSON keys rejected"

# Test 7: transition validation
validate_ttl_record_transition pending active || fail "pending->active should be allowed"
pass "pending->active allowed"
if validate_ttl_record_transition active pending 2>/dev/null; then
  fail "active->pending should be rejected"
fi
pass "active->pending rejected"
validate_ttl_record_transition active expired || fail "active->expired should be allowed"
pass "active->expired allowed"
if validate_ttl_record_transition expired active 2>/dev/null; then
  fail "expired->active should be rejected"
fi
pass "expired->active rejected (final state)"

# Test 8: has_non_expired_records
create_valid_ttl "$TTL"
result="$(has_non_expired_records "$TTL")"
[[ "$result" == "yes" ]] || fail "has_non_expired_records should be yes"
pass "has_non_expired_records detects active"
jq '.records[0].status = "expired"' "$TTL" > "$TTL.tmp" && mv "$TTL.tmp" "$TTL"
result="$(has_non_expired_records "$TTL")"
[[ "$result" == "no" ]] || fail "has_non_expired_records should be no after expired"
pass "has_non_expired_records detects expired"

# Test 9: UUID v4 generation
uuid="$(generate_uuid_v4)"
validators_is_uuid_v4 "$uuid" || fail "generated UUID not valid v4: $uuid"
pass "UUID v4 generation"

# Test 10: control chars in rule
cat > "$TTL" <<EOF
{
  "schema_version": 1,
  "records": [
    {
      "managed_id": "11111111-1111-4111-8111-111111111111",
      "rule": "allow id 1234:5678\n",
      "rule_sha256": "$(validators_hash_rule 'allow id 1234:5678')",
      "expires_at": 9999999999,
      "status": "active",
      "correlation_id": "22222222-2222-4222-8222-222222222222"
    }
  ]
}
EOF
if validate_ttl_json "$TTL" 2>/dev/null; then
  fail "control char in rule accepted"
fi
pass "control char in rule rejected"

printf 'All validators checks passed\n'
