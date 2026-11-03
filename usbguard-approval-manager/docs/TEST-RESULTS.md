# USBGuard Approval Manager - Test Results

**Date:** 2026-11-03
**Environment:** WSL Ubuntu (via Windows host) and isolated Kali VM (10.161.199.60)
**Project:** `C:\Users\5722y\Downloads\USB\usbguard-approval-manager\`
**Code Version:** Phase 2; G-01 remains `UNVERIFIED`

---

## Summary

| Test Category | Location | Result |
|---------------|----------|--------|
| Shell syntax checks | WSL + VM | ✅ WSL: 16 files; VM: 15 files PASS |
| Shell unit tests | WSL + VM | ✅ WSL: 8 scripts; VM: 7 scripts PASS |
| Python unit tests | WSL + VM | ✅ All 21 tests OK |
| Read-only preflight | VM | ✅ Completed, G01_STATUS=UNVERIFIED |
| Isolated G-01 integration | VM | ✅ USB state/rule semantics and cleanup passed; G-01 remains UNVERIFIED |

---

## 1. Shell Syntax Checks (`bash -n`)

Ran on both WSL and VM. All pass:

| File | WSL | VM |
|------|-----|-----|
| `scripts/lib/config-reader.sh` | PASS | PASS |
| `scripts/lib/lock.sh` | PASS | PASS |
| `scripts/lib/logger.sh` | PASS | PASS |
| `scripts/lib/result.sh` | PASS | PASS |
| `scripts/lib/time-guards.sh` | PASS | PASS |
| `scripts/lib/usbguard-policy.sh` | PASS | PASS |
| `tests/unit/test_config_reader.sh` | PASS | PASS |
| `tests/unit/test_g01_preflight_readonly.sh` | PASS | PASS |
| `tests/unit/test_lock.sh` | PASS | PASS |
| `tests/unit/test_logger.sh` | PASS | PASS |
| `tests/unit/test_policy_read.sh` | PASS | PASS |
| `tests/unit/test_policy_write.sh` | PASS | PASS |
| `tests/unit/test_result.sh` | PASS | PASS |
| `tests/unit/test_time_guards.sh` | PASS | PASS |
| `tests/integration/collect_g01_readonly_preflight.sh` | PASS | PASS |
| `tests/integration/test_g01_adapter.sh` | PASS | PASS |

---

## 2. Shell Unit Tests — WSL Results

### test_config_reader.sh — 35 checks PASS
- Exported initialization marker cannot bypass setup
- Approved configuration example
- All config key reads and validation
- Command/backtick/parameter substitution rejection
- Control character and NUL byte rejection

### test_g01_preflight_readonly.sh — 2 checks PASS
- Expected-hostname gate prevents queries on unconfirmed host
- Preflight gathers read-only evidence and leaves G-01 unverified

### test_lock.sh — 8 checks PASS
- Lock acquisition, release, timeout, EXIT trap handling
- Symbolic-link lock path rejection

### test_logger.sh — 3 checks PASS
- Operational logging, audit argument validation, write failure handling

### test_policy_read.sh — 15 checks PASS
- Version query, read-only runner rejects write operations
- Blocked devices and active rules as structured records
- Policy source validation (RuleFile/RuleFolder)
- Daemon status and IPC connectivity checks

### test_policy_write.sh — 16 checks PASS (NEW in Phase 2)
- G-01 verification required for all write operations
- Global lock required for mutations
- `approve_device`, `add_temporary_rule`, `add_permanent_rule`
- `remove_rule_by_canonical_rule`, `block_device`
- Precedence conflict detection (block-before-allow)
- Duplicate rule rejection, TOCTOU protection
- Protected `00-system.rules` rejection

### test_result.sh — 30+ checks PASS
- Result model, JSON round-trip, batch items, cancellation

### test_time_guards.sh — 21 checks PASS
- Live NTP evidence parsing, fail-closed behavior, clock jump thresholds, and modeled reboot recovery

---

## 3. Shell Unit Tests — VM Results

All shell unit tests pass on the isolated Kali VM (hostname `vbox`, user `yf`):

| Script | Result |
|--------|--------|
| `tests/unit/test_config_reader.sh` | 35 checks PASS |
| `tests/unit/test_lock.sh` | 8 checks PASS |
| `tests/unit/test_logger.sh` | 3 checks PASS |
| `tests/unit/test_policy_read.sh` | 15 checks PASS |
| `tests/unit/test_policy_write.sh` | 16 checks PASS |
| `tests/unit/test_result.sh` | 30+ checks PASS |
| `tests/unit/test_time_guards.sh` | 21 checks PASS |

---

`tests/unit/test_g01_preflight_readonly.sh` also passed on WSL; that file was
not present in the earlier VM copy.

## 4. Python Unit Tests — 21 tests OK

| Test File | Tests | Result |
|-----------|-------|--------|
| `test_atomic_write.py` | 11 | OK |
| `test_audit_write.py` | 10 | OK |

All 21 Python tests passed on both WSL and VM.

---

## 5. Read-Only Preflight — VM Results

Ran the privileged read-only `collect_g01_readonly_preflight.sh` on the VM with `USBAM_G01_EXPECTED_HOSTNAME="vbox"` and saved its output to `/tmp/g01-evidence/g01-preflight-report.md`:

```
G01_PREFLIGHT_STARTED_UTC=2026-11-03T20:27:01Z
HOSTNAME=vbox
OS=Linux
KERNEL=7.0.12+kali-amd64
RuleFile=/etc/usbguard/rules.conf
RuleFolder=/etc/usbguard/rules.d/
DAEMON_STATUS=stopped
IPC_STATUS=unavailable
T01_RESULT=UNVERIFIED
G01_STATUS=UNVERIFIED
POLICY_CHANGING_TESTS=NOT_RUN
```

Exit status `9` is expected: the preflight collected read-only evidence but
could not query devices or rules while the daemon was stopped. A live clock
probe separately confirmed active `ntpsec`, `NTPSynchronized=yes`, and one
selected reachable stratum-2 peer. `MAX_CLOCK_JUMP_SECONDS=3600` remains an
unapproved example, and no actual reboot was performed.

---

## 6. Isolated G-01 Integration — VM Results

The clean VM clone at commit `c1d917b` passed `make test`, including shell
syntax checks, all shell unit tests, and all 21 Python tests. The bounded lab
integration was then run against the disposable USB `048d:1234` using a
temporary daemon configuration and policy. USB-state and rule behavior passed;
the script returned its expected exit status `9` because the clock/reboot
gates are intentionally not certified:

- `append-rule --temporary` did not authorize the already-connected device.
- `allow-device` authorized the device without changing persistent rules.
- Lab-only `block-device` blocked it again; a `block` rule preceding a new
  `allow` remained effective.
- A permanent temporary-test rule survived isolated daemon restart, was then
  removed, and the temporary policy was cleaned up.
- This run began with the USB at sysfs `authorized=0` and no USB disk node.
  Cleanup restored that exact initial state and verified that no USB disk
  remained or was mounted.
- The installed service remained inactive and disabled, no daemon remained,
  and `/etc/usbguard/rules.conf` retained its original empty-file SHA-256:
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
- Live clock observations found `ntpsec` active, `NTPSynchronized=yes`, and a
  selected stratum-2 peer with reach `377`. `ntpq -c rv` also reported the
  `no_sys_peer` event text; these observations do not constitute approval of
  the source or the example `MAX_CLOCK_JUMP_SECONDS=3600`.
- No reboot or powered-off TTL test was performed. G-01 remains
  `UNVERIFIED`.

The retained VM evidence is
`/var/tmp/usbguard-approval-manager-g01-c1d917b/g01-20261103T203827Z.p8GbPh`.

The detailed evidence and exact limits are in
[`g01-preflight-report.md`](./g01-preflight-report.md).

---

## 7. What Was NOT Tested

| Test | Reason |
|------|--------|
| Actual OS reboot with trusted clock and powered-off TTL | Not run |
| Reboot with unsynchronized/jumped clock | Not run; recovery behavior is covered by unit tests only |
| Approved time source and `MAX_CLOCK_JUMP_SECONDS` threshold | Not established; `3600` is an example, not an approved value |
| Independent VM recovery route / snapshot restore | Not tested |
| Phase 3 components (`validators.sh`, `stages.sh`, `cleanup-expired.sh`, `usb-revoke.sh`) | Not yet implemented |

---

## 8. Current Status

| Item | Status |
|------|--------|
| Phase 1 (read-only foundation) | ✅ Complete |
| Phase 2 (write operations + G-01 code) | ✅ Code merged, unit tests pass on WSL and VM |
| G-01 VM verification | ⏳ **UNVERIFIED** — real reboot recovery and threshold approval outstanding |
| Phase 3 (TTL Engine + Reaper) | ⏳ Not started |

**Next step:** Complete G-01 verification in isolated lab VM (see `docs/lab-checklist.md` and `docs/g01-preflight-report.md`), then proceed to Phase 3.
