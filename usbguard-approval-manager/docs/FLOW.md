# USBGuard Approval Manager - System Flow

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CALLER / HIGHER LAYER                            │
│  (stages.sh, validators.sh, usb-revoke.sh, cleanup-expired.sh - Phase 3) │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              scripts/lib/usbguard-policy.sh  (THE ONLY USBGuard layer)   │
│                                                                         │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐       │
│  │  READ-ONLY API  │   │   WRITE API     │   │   HELPERS       │       │
│  ├─────────────────┤   ├─────────────────┤   ├─────────────────┤       │
│  │ • get_          │   │ • approve       │   │ • canonicalize  │       │
│  │   _usbguard_    │   │   _device       │   │ • hash_rule     │       │
│  │   _version()    │   │ • add_temporary │   │ • parse_rule_   │       │
│  │ • list_         │   │   _rule()       │   │   _line()       │       │
│  │   _blocked_     │   │ • add_permanent │   │ • extract_id_   │       │
│  │   _devices()    │   │   _rule()       │   │   _pattern()    │       │
│  │ • list_         │   │ • remove_rule_  │   │ • validate_     │       │
│  │   _active_rules │   │   _by_canonical │   │   _device_id()  │       │
│  │ • get_active_   │   │   _rule()       │   │ • validate_rule() │       │
│  │   _rules()      │   │ • block_device()│   │ • check_precedence│       │
│  │ • get_persistent│   │                 │   │ • find_rule_id_ │       │
│  │   _policy_paths()│   │                 │   │   _by_canonical │       │
│  │ • check_daemon_ │   │                 │   │ • get_rule_by_id()│       │
│  │   _status()     │   │                 │   │ • is_g01_verified()│      │
│  └─────────────────┘   └─────────────────┘   └─────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    GATE CHECKS (in order, all must pass)                  │
│                                                                         │
│  1. Argument count validation                                           │
│  2. Device ID / Rule format validation                                  │
│  3. Lock held (usbguard_policy_require_lock)  [write ops only]         │
│  4. G-01 verified marker (is_g01_verified)   [write ops only]          │
│  5. Daemon running + IPC connected (check_daemon_status)               │
│  6. Precedence check (usbguard_check_precedence) [rule writes]          │
│  7. Duplicate rule check                                                │
│  8. TOCTOU re-fetch (remove_rule_by_canonical_rule)                    │
│  9. Execute USBGuard CLI command (_usbguard_run)                        │
│  10. Post-operation verification (re-fetch state)                       │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    USBGuard Daemon (usbguard-daemon)                    │
│  • /etc/usbguard/usbguard-daemon.conf                                   │
│  • RuleFile=/etc/usbguard/rules.conf                                    │
│  • RuleFolder=/etc/usbguard/rules.d/                                    │
│  • IPC socket for CLI communication                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

## Data Flow: Read-Only Operations

```
Caller → get_usbguard_version() / list_blocked_devices() / list_active_rules()
    → usbguard_policy_run_readonly()
        → _usbguard_run()
            → timeout + usbguard CLI
            → capture stdout/stderr
            → usbguard_policy_parse_records()
    → Return structured data to caller
```

## Data Flow: Write Operations

```
Caller → approve_device() / add_temporary_rule() / add_permanent_rule() /
         remove_rule_by_canonical_rule() / block_device()

    → usbguard_policy_require_lock()        [LOCK MUST BE HELD]
    → is_g01_verified()                     [G-01 MARKER REQUIRED]
    → check_daemon_status()                 [DAEMON + IPC]
    → usbguard_check_precedence()           [RULE WRITES ONLY]
    → Duplicate check                       [RULE WRITES ONLY]
    → usbguard_policy_run_write()
        → _usbguard_run()
            → timeout + usbguard CLI
            → capture stdout/stderr
    → Post-verification (re-fetch state)
    → Return success/error to caller
```

## Security Gates (SEC)

| Gate | Description | Enforced In |
|------|-------------|-------------|
| SEC-01 | No `eval` or `source` in policy adapter | usbguard-policy.sh |
| SEC-02 | Strict input validation | usbguard_validate_*() |
| SEC-03 | flock single, re-fetch after lock | remove_rule_by_canonical_rule() |
| SEC-05 | 00-system.rules protected | usbguard_validate_rule(), get_persistent_policy_paths() |
| SEC-18 | block-device only after G-01 verified | is_g01_verified() |
| SEC-19 | Explicit verification after block | block_device() post-check |

## G-01 Verification Flow

```
1. VM isolated lab environment prepared
2. USBGuard installed, test policy configured
3. Disposable USB device connected
4. Snapshot created and verified
5. Complete docs/lab-checklist.md, including the independent recovery route
6. Run tests/integration/test_g01_adapter.sh only in the isolated VM
   - USBAM_G01_CONFIRM=YES and the verified VM hostname are required
   - Supply the disposable USB's VID:PID, not a USBGuard device ID
   - The script uses temporary daemon/policy files and leaves installed policy untouched
   - It verifies device state, rule precedence, temporary vs persistent rules,
     daemon restart persistence, and USB recovery
7. Record clock-source evidence and separately exercise both reboot cases
8. Keep G-01 UNVERIFIED until every gate and the recovery route are reviewed
   - The integration script intentionally exits 9 and never creates the marker
   - Do not create the marker while clock/reboot behavior remains unverified
```

## File Layout

```
usbguard-approval-manager/
├── Makefile                          # Test runner: make test
├── README.md                         # Project overview & rules
├── conf/
│   └── approval-manager.conf.example # Config: TTL, timeouts, paths
├── docs/
│   ├── lab-checklist.md              # Pre-lab entry criteria
│   └── g01-preflight-report.md       # G-01 status & observations
├── scripts/
│   └── lib/
│       ├── atomic-write.py           # Atomic JSON writer
│       ├── audit_write.py            # Audit logging
│       ├── clock_state.py            # Clock guards
│       ├── config-reader.sh          # Configuration reader
│       ├── lock.sh                   # Process lock (flock)
│       ├── logger.sh                 # Operational/Audit logging
│       ├── result.sh                 # Shared result model
│       ├── time-guards.sh            # Calendar clock guards
│       └── usbguard-policy.sh        # USBGuard adapter (857 lines)
├── systemd/                          # Service unit files
└── tests/
    ├── integration/
    │   ├── collect_g01_readonly_preflight.sh
    │   └── test_g01_adapter.sh       # G-01 5-gate integration test
    └── unit/
        ├── test_atomic_write.py
        ├── test_audit_write.py
        ├── test_config_reader.sh
        ├── test_g01_preflight_readonly.sh
        ├── test_lock.sh
        ├── test_logger.sh
        ├── test_policy_read.sh
        ├── test_policy_write.sh      # Phase 2: 16 write tests
        ├── test_result.sh
        └── test_time_guards.sh
```

## Entry Points for Higher Layers (Phase 3)

When Phase 3 components are built, they call usbguard-policy.sh functions:

```
stages.sh        → approve_device(), add_temporary_rule(), add_permanent_rule()
validators.sh    → usbguard_validate_rule(), usbguard_validate_device_id()
usb-revoke.sh    → remove_rule_by_canonical_rule(), block_device()
cleanup-expired.sh → remove_rule_by_canonical_rule() (temp rules only)
```

All mutation operations require:
1. Lock held for entire operation
2. G-01 verified marker present
3. Daemon running + IPC connected