# Agent Working Documentation - USBGuard Approval Manager

## Purpose

This document tells an agent how to work correctly with the USBGuard Approval Manager codebase. It covers project structure, safety rules, development workflow, and how to run tests.

---

## 1. Project Location

| Item | Path |
|------|------|
| Project root | `C:\Users\5722y\Downloads\USB\usbguard-approval-manager\` |
| Main adapter | `scripts/lib/usbguard-policy.sh` |
| Tests | `tests/unit/` and `tests/integration/` |
| Config | `conf/approval-manager.conf.example` |
| Docs | `docs/` (FLOW.md, lab-checklist.md, g01-preflight-report.md) |
| Merged text dump | `C:\Users\5722y\Downloads\USB TXT\all-files-merged.txt` |
| Merge script | `C:\Users\5722y\Downloads\USB TXT\merge-to-one-text.ps1` |

---

## 2. Safety Rules (MANDATORY)

### Never do these on a development workstation:

1. **Do not run `usbguard allow-device`, `usbguard block-device`, or other device-state changes.**
2. **Do not run `usbguard append-rule`, `usbguard remove-rule`, or edit active/persistent USBGuard policy.**
3. **Do not restart/reload the daemon or reboot to test persistence.**
4. **Do not change `RuleFile`, `RuleFolder`, or protected system rules.**
5. **Do not install or enable USBGuard as an unplanned part of a test.**

### Only in an isolated lab VM for the dedicated G-01 test:

- The live G-01 test changes only the disposable USB's state and a temporary
  daemon policy. It requires a verified VM identity, unmounted USB disk,
  inactive installed service, and an independent recovery route.
- Do not use the test to exercise production adapter writes or installed policy.
- Production write operations remain disabled until G-01 evidence is complete
  and reviewed; callers must hold the process lock for the entire mutation.

### Read-only operations are safe everywhere:

- `get_usbguard_version()`, `list_blocked_devices()`, `list_active_rules()`, `get_active_rules()`, `get_persistent_policy_paths()`, `check_daemon_status()`

---

## 3. Development Workflow

### Step 1: Run syntax checks

```bash
cd /mnt/c/Users/5722y/Downloads/USB/usbguard-approval-manager  # WSL path
make check-shell
```

### Step 2: Run unit tests

```bash
make test
```

This runs:
- Shell syntax checks on all `.sh` files
- All unit test scripts in `tests/unit/`
- Python unit tests via `unittest discover`

### Step 3: Run integration tests (LAB VM ONLY)

```bash
# Use the actual VM hostname and disposable USB VID:PID.
sudo env \
  USBAM_G01_CONFIRM=YES \
  USBAM_G01_EXPECTED_HOSTNAME="vbox" \
  USBAM_TEST_USB_ID="048d:1234" \
  USBAM_G01_REPORT_DIR="/var/tmp/usbguard-approval-manager-g01" \
  bash tests/integration/test_g01_adapter.sh
```

The script uses a temporary daemon and policy, does not alter the installed
service or policy, and intentionally exits `9` with G-01 still `UNVERIFIED`
until clock trust and reboot recovery are separately verified. It does not
create the G-01 marker.

---

## 4. Key Functions in usbguard-policy.sh

### Read-Only API (safe everywhere)

| Function | Purpose |
|----------|---------|
| `get_usbguard_version()` | Returns USBGuard version string |
| `list_blocked_devices()` | Populates `USBAM_BLOCKED_DEVICES[]` |
| `list_active_rules()` | Populates `USBAM_ACTIVE_RULES[]` |
| `get_active_rules()` | Alias for `list_active_rules()` |
| `get_persistent_policy_paths()` | Validates RuleFile/RuleFolder from daemon config |
| `check_daemon_status()` | Sets `USBAM_DAEMON_STATUS`, `USBAM_IPC_STATUS` |

### Write API (requires lock + G-01)

| Function | Purpose | Security Gate |
|----------|---------|---------------|
| `approve_device(device_id)` | Allow a USB device via `allow-device` | Lock + G-01 + daemon |
| `add_temporary_rule(rule)` | Append temporary rule via `append-rule --temporary` | Lock + G-01 + precedence |
| `add_permanent_rule(rule)` | Append permanent rule via `append-rule` | Lock + G-01 + precedence + RuleFile/RuleFolder |
| `remove_rule_by_canonical_rule(rule)` | Remove rule via `remove-rule` | Lock + G-01 + TOCTOU re-fetch |
| `block_device(device_id)` | Block a USB device via `block-device` | Lock + G-01 (SEC-19) |

### Helper Functions

| Function | Purpose |
|----------|---------|
| `usbguard_validate_device_id(id)` | Numeric ID validation |
| `usbguard_validate_rule(rule)` | Rule format validation (allow/block/reject prefix, no control chars, no 00-system.rules) |
| `usbguard_check_precedence(rule)` | Block-before-allow conflict detection |
| `usbguard_find_rule_id_by_canonical(rule)` | Find unique rule ID by canonical text |
| `usbguard_canonicalize_rule(rule)` | Trim whitespace from rule |
| `usbguard_hash_rule(rule)` | SHA-256 hash of canonical rule |
| `is_g01_verified()` | Check G-01 marker file |

---

## 5. Error Codes

| Code | Meaning |
|------|---------|
| `invalid_arguments` | Wrong number of arguments |
| `invalid_device_id` | Device ID not numeric |
| `invalid_rule` | Rule format invalid |
| `protected_policy` | References 00-system.rules |
| `invalid_timeout` | IPC_TIMEOUT_SECONDS not positive integer |
| `timeout_unavailable` | `timeout` command missing |
| `usbguard_unavailable` | `usbguard` CLI missing |
| `temporary_storage_unavailable` | `mktemp -d` failed |
| `command_timeout` | USBGuard command timed out |
| `command_failed` | USBGuard command exited non-zero |
| `invalid_command_output` | Unrecognized USBGuard output format |
| `invalid_device_id` | Device ID not numeric |
| `invalid_rule` | Rule validation failed |
| `daemon_unavailable` | Daemon not running or IPC unavailable |
| `g01_not_verified` | G-01 marker missing or invalid |
| `lock_not_held` | Process lock not held by caller |
| `precedence_conflict` | Block rule precedes new allow rule |
| `duplicate_rule` | Rule already exists |
| `rule_not_found` | No matching active rule |
| `ambiguous_rule_match` | Multiple rules match |
| `verification_failed` | Post-operation state check failed |
| `device_not_found` | Device disappeared before verification |
| `device_still_blocked` | Device not allowed after allow-device |
| `device_not_blocked` | Device not blocked after block-device |
| `rule_disappeared` | TOCTOU: rule gone before removal |
| `rule_id_changed` | TOCTOU: rule ID changed between lookups |
| `rule_still_present` | Rule still present after removal |

---

## 6. G-01 Status

**Current: UNVERIFIED** (not PASS)

G-01 must be verified before any production write operations are allowed. See
`docs/lab-checklist.md` and `docs/g01-preflight-report.md`. Never create the
marker manually based only on the integration script: it does not verify
clock/reboot recovery and intentionally leaves G-01 `UNVERIFIED`.

---

## 7. Configuration

Edit `conf/approval-manager.conf.example` and copy to active config location:

| Key | Default | Purpose |
|-----|---------|---------|
| `TEMP_TTL_SECONDS` | 3600 | Temporary rule TTL in seconds |
| `MIN_REASONABLE_EPOCH` | 1577836800 | Minimum reasonable clock epoch |
| `MAX_CLOCK_JUMP_SECONDS` | 3600 | Max allowed clock jump |
| `BACKUP_KEEP` | 5 | Number of backups to keep |
| `IPC_TIMEOUT_SECONDS` | 5 | USBGuard IPC timeout |
| `LOG_LEVEL` | INFO | Logging level |

---

## 8. Merged Text File

A complete text dump of all project files is maintained at:

`C:\Users\5722y\Downloads\USB TXT\all-files-merged.txt`

To regenerate after code changes:

```powershell
pwsh -ExecutionPolicy Bypass -File "C:\Users\5722y\Downloads\USB TXT\merge-to-one-text.ps1"
```

Defaults:
- Source: `C:\Users\5722y\Downloads\USB\usbguard-approval-manager\`
- Output: `C:\Users\5722y\Downloads\USB TXT\all-files-merged.txt`

---

## 9. Git Workflow

```bash
# Check status
git status

# See what changed
git diff --stat

# Stage all changes
git add .

# Commit
git commit -m "Phase 2: write operations + G-01 verification"

# Push
git push origin main
```

**Do not commit secrets, keys, or the `.gitignore`-cached files (`__pycache__/`, `.pyc`).**

---

## 10. Common Mistakes to Avoid

| Mistake | Correction |
|---------|------------|
| Running write ops on dev host | Use isolated VM only |
| Forgetting lock before mutation | Call `usbguard_policy_require_lock` first |
| Forgetting G-01 check before writes | Call `is_g01_verified()` first |
| Not checking daemon status | Call `check_daemon_status()` before USBGuard CLI |
| Ignoring precedence conflicts | Call `usbguard_check_precedence()` before adding allow rules |
| Not verifying post-operation state | Re-fetch device/rule state after every mutation |
| Editing 00-system.rules | Protected - will be rejected |
| Committing `__pycache__/` or `.pyc` files | Already in `.gitignore` |

---

## 11. Phase 3 (Planned, Not Yet Implemented)

| Component | Purpose | Calls usbguard-policy.sh |
|-----------|---------|-------------------------|
| `validators.sh` | TTL JSON schema validation | `usbguard_validate_rule()` |
| `stages.sh` | pending → active state transitions | `approve_device()`, `add_temporary_rule()` |
| `cleanup-expired.sh` (Reaper) | Remove expired temp rules only | `remove_rule_by_canonical_rule()` |
| `usb-revoke.sh` | Explicit revoke with confirmation | `block_device()`, `remove_rule_by_canonical_rule()` |
