# USBGuard Approval Manager - Test Results

**Date:** 2026-11-03 19:46 UTC
**Environment:** WSL Ubuntu (via Windows host) and isolated Kali VM
**Project:** `C:\Users\5722y\Downloads\USB\usbguard-approval-manager\`
**Code Version:** Phase 2; G-01 remains `UNVERIFIED`

---

## Summary

| Test Category | Files | Result |
|---------------|-------|--------|
| Shell syntax checks | 16 files | ✅ All PASS |
| Shell unit tests | 8 scripts | ✅ All PASS |
| Python unit tests | 21 tests | ✅ All OK |
| Isolated G-01 integration | 1 VM run | USB behavior/recovery passed; expected exit `9`, G-01 still `UNVERIFIED` |

---

## 1. Shell Syntax Checks (`bash -n`)

All shell scripts pass syntax validation:

| File | Result |
|------|--------|
| `scripts/lib/config-reader.sh` | PASS |
| `scripts/lib/lock.sh` | PASS |
| `scripts/lib/logger.sh` | PASS |
| `scripts/lib/result.sh` | PASS |
| `scripts/lib/time-guards.sh` | PASS |
| `scripts/lib/usbguard-policy.sh` | PASS |
| `tests/unit/test_config_reader.sh` | PASS |
| `tests/unit/test_g01_preflight_readonly.sh` | PASS |
| `tests/unit/test_lock.sh` | PASS |
| `tests/unit/test_logger.sh` | PASS |
| `tests/unit/test_policy_read.sh` | PASS |
| `tests/unit/test_policy_write.sh` | PASS |
| `tests/unit/test_result.sh` | PASS |
| `tests/unit/test_time_guards.sh` | PASS |
| `tests/integration/collect_g01_readonly_preflight.sh` | PASS |
| `tests/integration/test_g01_adapter.sh` | PASS |

---

## 2. Shell Unit Tests

### test_config_reader.sh — 35 checks PASS
- Exported initialization marker cannot bypass setup
- Approved configuration example
- All config key reads (TEMP_TTL_SECONDS, MIN_REASONABLE_EPOCH, MAX_CLOCK_JUMP_SECONDS, BACKUP_KEEP, IPC_TIMEOUT_SECONDS, LOG_LEVEL)
- Valid configuration loading
- Custom value overrides
- LOG_LEVEL validation (DEBUG, INFO, WARNING, ERROR accepted)
- Duplicate key rejection
- Unknown key rejection
- Invalid log level rejection
- Out-of-range value rejection
- Backup retention bounds validation
- IPC timeout bounds validation
- Command substitution rejection (not executed)
- Parameter expansion rejection
- Backtick substitution rejection
- Malformed assignment rejection
- Control character rejection
- Failed load clears previous config
- NUL byte rejection

### test_g01_preflight_readonly.sh — 2 checks PASS
- Expected-hostname gate prevents queries on unconfirmed host
- Preflight gathers read-only evidence and leaves G-01 unverified

### test_lock.sh — 8 checks PASS
- Free lock acquisition and explicit release
- Competing process times out safely
- EXIT trap releases lock
- Existing EXIT trap preserved and acquisition fails closed
- Composed caller EXIT trap retains lock release
- Unsafe EXIT trap ordering rejected
- Invalid timeout rejected
- Symbolic-link lock path rejected

### test_logger.sh — 3 checks PASS
- Operational logging uses system logger and rejects control characters
- Invalid Audit argument count rejected
- Audit write failure is explicit

### test_policy_read.sh — 15 checks PASS
- Version query returns captured version
- Read-only runner rejects all non-query USBGuard operations
- Blocked devices returned as structured records
- Empty blocked-device list is valid
- Malformed device output fails closed
- Non-zero USBGuard exit is explicit, stderr retained
- USBGuard queries bounded by configured timeout
- Active rules returned as structured records
- Empty active-rule list is valid
- Configured RuleFile and RuleFolder sources both returned
- Missing, duplicate, traversing, and symlinked policy sources fail closed
- Daemon and IPC success reported separately
- Running daemon with unavailable IPC is degraded
- Stopped daemon reported as unavailable
- Adapter rejects unexpected arguments

### test_policy_write.sh — 16 checks PASS (NEW in Phase 2)
- G-01 environment overrides are ignored
- Canonicalize trims whitespace
- Hash is deterministic SHA-256
- All write operations require G-01 verification and global lock
- Write operations reject missing arguments safely
- `approve_device` verifies selected device is allowed
- `approve_device` fails when USBGuard does not change device state
- `approve_device` rejects invalid IDs
- Temporary rule append succeeds
- Duplicate temporary rules rejected
- Block-before-allow conflict rejected
- Generic earlier blocks conservatively reject later allows
- Protected `00-system.rules` rejected
- Permanent rule append succeeds
- Canonical rule lookup finds unique match
- Canonical rule lookup rejects ambiguous matches
- Canonical rule removal is verified
- Missing rules cannot be removed
- `block_device` verifies selected device is blocked
- Read-only runner rejects write operations

### test_result.sh — 30+ checks PASS
- Result model validation, partial states, JSON round-trip, batch items, cancellation

### test_time_guards.sh — 16 checks PASS
- Epoch validation, clock jump thresholds, sync provider, reboot recovery, corrupted state handling

---

## 3. Python Unit Tests — 21 tests OK

| Test File | Tests | Result |
|-----------|-------|--------|
| `test_atomic_write.py` | 11 | OK |
| `test_audit_write.py` | 10 | OK |

All 21 Python tests passed in 0.232s.

---

## 4. What Was NOT Tested

| Test | Reason |
|------|--------|
| `tests/integration/test_g01_adapter.sh` | Ran in the isolated VM on 2026-11-03. USB state, rule precedence, persistence across isolated-daemon restart, and final disk recovery passed. Expected exit status `9`; G-01 remains `UNVERIFIED`. |
| Live USBGuard daemon integration | Verified using a temporary daemon and policy; the installed service and `/etc/usbguard` policy were untouched. |
| G-01 verification | Status remains `UNVERIFIED`. Clock trust/threshold approval, reboot recovery, and independent recovery-route verification remain outstanding. |
| Phase 3 components (`validators.sh`, `stages.sh`, `cleanup-expired.sh`, `usb-revoke.sh`) | Not yet implemented. |

---

## 5. Current Status

| Item | Status |
|------|--------|
| Phase 1 (read-only foundation) | ✅ Complete |
| Phase 2 (write operations + G-01) | ✅ Code and unit tests pass; isolated USB behavior verified |
| G-01 VM verification | ⏳ **UNVERIFIED** — clock/reboot and recovery gates remain |
| Phase 3 (TTL Engine + Reaper) | ⏳ Not started |

**Next step:** Complete G-01 verification in isolated lab VM (see `docs/lab-checklist.md` and `docs/g01-preflight-report.md`), then proceed to Phase 3.
