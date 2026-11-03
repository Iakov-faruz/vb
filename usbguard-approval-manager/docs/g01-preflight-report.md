# G-01 Lab Preflight Report

**Checked:** 2026-11-03
**Overall G-01 status:** `UNVERIFIED`  
**Scope:** Read-only VM inspection plus a temporary USBGuard daemon using
generated allow rules and test-only policy files. The installed daemon,
configuration, and persistent policy were not changed.

## Environment observations

| Check | Observation | Result |
|---|---|---|
| VM identity | Hostname `vbox`, user `yf`, Kali Linux x86_64, kernel `7.0.12+kali-amd64` | Recorded |
| USBGuard CLI | `/usr/bin/usbguard`, version `1.1.4` | Installed |
| USBGuard service | `inactive`; `systemctl is-enabled` reports `disabled`; rechecked after the temporary test | No installed service was started |
| Read-only IPC query | `usbguard list-devices` returned `IPC connect: service=usbguard: Connection refused`, exit status `1` | IPC unavailable |
| Daemon configuration | `/etc/usbguard/usbguard-daemon.conf` is `root:root`, mode `0600`; it was inspected read-only with `sudo`. | Read |
| Persistent policy settings | `RuleFile=/etc/usbguard/rules.conf` and `RuleFolder=/etc/usbguard/rules.d/` are both configured. USBGuard 1.1.4's local man page permits using both together. | Both sources identified |
| Rule file | `/etc/usbguard/rules.conf` is `root:root`, mode `0600`, and contains zero active rule lines. | Read-only observation |
| Rule folder | `/etc/usbguard/rules.d/` exists and contains no files. | Read-only observation |
| Service unit | Journal entries include warnings about unsupported `ConditionKernelCommandLine` and `ConditionPathExists` keys. Their impact on startup has not been determined. | Follow up; cause unverified |
| Attached USB storage | `048d:1234`, 29.3G, VFAT; `lsblk` showed no mount point. Contents were not accessed. | Observed unmounted |
| Clock status | `timedatectl` reported `NTPSynchronized=yes`, `NTP=yes`, `CanNTP=yes`; `systemd-timesyncd`, `chrony`, and `chronyd` were inactive. | Sync provider not identified |
| Recovery evidence | Snapshot identifier, restore test, and independent console recovery were not independently verified. | `UNVERIFIED` |

## Temporary isolated-daemon observations

On 2026-11-03, a transient systemd unit ran USBGuard 1.1.4 with a private
configuration under `/run`, a `RuleFile` and `RuleFolder` under that temporary
directory, and four rules produced by `usbguard generate-policy`. The config
used `PresentDevicePolicy=keep` and `IPCAllowedUsers=root`. The unit was stopped
and its temporary files removed after each test. A follow-up check found zero
USBGuard daemon processes, no remaining POC units, the installed service still
inactive/disabled, and `/etc/usbguard/rules.conf` still empty.

The VM's real USBGuard CLI was used directly; the application adapter was not
run in the VM. Results:

| Test | Observation | Result |
|---|---|---|
| Connected USB state | The flash drive appeared once as device `7`, `048d:1234`, and was `allow` under the generated test policy. | Recorded |
| `allow-device 7` | The already-allowed device remained allowed; the temporary `RuleFile` hash did not change. This did not test a blocked-to-allowed transition. | Partial |
| Temporary rule | `append-rule --temporary 'allow id ffff:ffff'` appeared in active rules; `remove-rule` removed it; the temporary `RuleFile` hash remained unchanged. | Pass for isolated CLI behavior |
| Persistent rule | `allow id ffff:fffe` was written to the temporary `RuleFile`, survived a restart of the transient daemon, and was removed; the file returned to its generated baseline hash. | Pass for isolated CLI behavior |
| Rule order | `block id ffff:fffd` followed by `append-rule --after <id> 'allow id ffff:fffd'` was listed in that order. Both synthetic rules were removed. | Order observed; effective decision unverified |
| `block-device` | Not run. | `UNVERIFIED` |
| Reboot / clock behavior | No reboot, clock change, or time-sync service change was performed. | `UNVERIFIED` |

These observations establish behavior only for the isolated daemon and its
temporary policy files. They do not prove the effective decision for a
conflicting rule on a connected device, blocked-device approval, behavior
across VM reboot, or application-adapter behavior.

The VM had previously been described as an isolated lab with a snapshot, but
that assertion does not verify its current USB passthrough, policy, or recovery
state. The configuration and policy locations were inspected read-only with
`sudo`; the daemon was not started. The service remains inactive, so the
configured persistent sources do not establish which rules are currently
loaded or how runtime policy changes behave.

## Project files and tests

The transferred project did not contain the new read-only USBGuard adapter or
its unit test. At the initial transfer, the following two files were copied
into the user-owned project directory, without overwriting existing files:

- `scripts/lib/usbguard-policy.sh`
- `tests/unit/test_policy_read.sh`

Their local and VM SHA-256 values matched:

| File | SHA-256 |
|---|---|
| `scripts/lib/usbguard-policy.sh` | `4b1d41b969b9f600135cd6f3a144b3877b450bcd7078029aaeac60106a2a7fcc` |
| `tests/unit/test_policy_read.sh` | `62c1c01c98491746d0a83bb3683bac7a3f6fbfe41f0f42a43e29fa87bd421d02` |

The adapter was subsequently corrected locally to accept both configured
policy sources. That revision has not been copied to the VM. The isolated test
used the installed USBGuard CLI directly, so it does not validate the current
adapter revision.

Results:

- VM: all transferred shell syntax checks passed.
- VM: config-reader (35 checks), result-model, lock, logger, time-guard, and
  Python unit tests (21 tests) passed.
- VM: mocked read-only adapter tests passed after the two files were copied.
  The adapter test puts its fake `usbguard` and `pgrep` commands first in
  `PATH`; it did not exercise the real daemon.
- Development environment (WSL): all unit test scripts and all 21 Python
  tests passed; `git diff --check` passed.

## Gate decision

G-01 remains `UNVERIFIED`, not `PASS`. The isolated CLI tests verified
temporary-rule behavior, temporary-file persistence across daemon restart, and
rule ordering, but did not prove the effective result of conflicting rules on
a connected device, the `block-device` transition, reboot/clock recovery, or
the application adapter. The snapshot identifier and independent recovery
route also remain unverified. No installed daemon, production policy, or
system time was changed.

Do not enable policy-changing adapter operations or proceed to dependent
phases until the remaining G-01 observations and recovery prerequisites are
verified and recorded.
