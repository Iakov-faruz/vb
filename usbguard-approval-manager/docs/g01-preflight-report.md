# G-01 Lab Preflight Report

**Checked:** 2026-11-03 20:44 UTC
**Overall G-01 status:** `UNVERIFIED`  
**Scope:** Isolated live testing with the unmounted disposable USB and
temporary policy files under `/run`; a later bounded test also started the
installed service and temporarily changed then restored its RuleFile. Clock
and reboot tests were not run.

## Latest clean-clone verification — 2026-11-03 20:44 UTC

The VM was updated from the pushed repository and its clean clone is at commit
`769adf3`. `make test` passed, including quick-script syntax checks, all shell
unit tests, and all 21 Python tests. The USB status quick check passed 4/4 and
the clock quick check passed 6/6. The G-01 status check returned `1`, as
expected with the installed service inactive and the evidence marker absent.
The integration wrapper refused to run without the explicit confirmation
value; none changed the service, USB authorization, or installed policy.

The explicit-confirmation integration wrapper then used USB `048d:1234`, a
temporary daemon configuration, and a temporary policy under `/run`. Its
initial kernel authorization was `0`, so no USB disk node was present. The
test verified:

- `append-rule --temporary` did not authorize the connected device; the
  explicit `allow-device` operation did.
- `block-device` blocked/deauthorized the device, and a later temporary
  allow did not override the earlier block rule.
- A permanent test rule survived restart of the isolated daemon and was then
  removed from the temporary policy.
- Cleanup restored the initial kernel authorization (`0`) and verified that
  no USB disk was present or mounted.
- The installed service stayed inactive and disabled; no daemon remained.
  `/etc/usbguard/rules.conf` retained its original empty-file SHA-256:
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

The script returned its expected exit status `9`; this means the verified USB
observations did not certify the outstanding clock/reboot gates. Evidence is
retained at
`/var/tmp/usbguard-approval-manager-g01-769adf3/g01-20261103T204430Z.50x7hP`.
The installed service and persistent policy were not changed by this run.

Clock observations were `ntpsec` active, `NTPSynchronized=yes`, and one
selected stratum-2 peer with reach `377`. `ntpq -c rv` also contained the
`no_sys_peer` event text. This is current-state evidence only; it does not
approve the provider or the example `MAX_CLOCK_JUMP_SECONDS=3600`. No OS
reboot, unsynchronized-clock recovery, or powered-off TTL-expiry test was run.
G-01 remains `UNVERIFIED`.

## Earlier live lab observation — 2026-11-03 19:46 UTC

The VM was confirmed in VirtualBox as the running `kali` machine. VirtualBox
reported current snapshot `20:39 3.11.26` (UUID
`d6b60282-f896-45ac-abfe-bba5911e2556`). Inside the VM the hostname is `vbox`;
USBGuard 1.1.4's installed service was inactive, no daemon or IPC socket was
present, and the sole USB disk (`048d:1234`) was unmounted.

That isolated integration run used a temporary daemon configuration and
policy under `/run`; the installed service and `/etc/usbguard` policy were not
started or changed. Its results:

- `append-rule --temporary` did not change the connected USB's blocked state
  or the temporary RuleFile.
- `allow-device` changed that device to `allow` without changing the rule list
  or persistent RuleFile, and the physical device was reauthorized and
  re-enumerated as an unmounted disk.
- In the lab-only test, `block-device` changed the connected USB to `block`
  and deauthorized it in the kernel; `allow-device` restored it without
  changing the policy.
- An earlier `block` rule remained effective ahead of a later temporary
  `allow`.
- A permanent rule was written to the temporary RuleFile, survived restart of
  the isolated daemon, and was removed successfully afterward.
- The script returned its expected status `9`: USB behavior and cleanup passed,
  while clock/reboot gates intentionally remain unverified. G-01 is **not**
  `PASS`.

An intermediate run exposed that USB mass-storage re-enumeration can take
longer than one second after authorization: the test saw no disk and failed,
although a subsequent read-only check showed the disk had returned. The
integration test now waits up to 10 seconds after `allow-device` and daemon
shutdown, then verifies that exactly one unmounted USB disk is present. The
latest run passed these checks, including final cleanup.

The VM reported `ntpsec` and `ntp` active, `chrony` and
`systemd-timesyncd` inactive, and `timedatectl` synchronized. `ntpq -pn`
showed a selected peer (`*`, stratum 2, reach 377, offset about -60 ms);
`ntpq -c rv` reported `sync_ntp` and also the event text `no_sys_peer`.
`/etc/ntpsec/ntp.conf` uses Debian pool sources. These observations identify
the current synchronization service but do not approve it as a trusted time
source for TTL decisions. The project example sets
`MAX_CLOCK_JUMP_SECONDS=3600`; that is a configured example, not an approved
target threshold.

The OS was not rebooted and the clock was not changed. The `recovery_required`
behavior after an untrusted reboot has not been exercised, and remains a
blocker before TTL/Reaper work or production writes. The live integration
output is retained on the VM at
`/var/tmp/usbguard-approval-manager-g01/g01-20261103T194600Z.PMTQLY`.

## Read-only clock and preflight check — 2026-11-03 20:27 UTC

The VM's live clock check found `ntpsec` active, `timedatectl` reporting
`NTPSynchronized=yes`, and exactly one selected NTP peer with stratum 2 and
non-zero reach. The updated `clock_sync_evidence` returned
`clock_sync_verified`. A separate `detect_clock_jump` probe initialized a
baseline only in a temporary `/tmp` file, which was removed after the check.
This verifies current synchronization evidence, not reboot recovery or an
approved `MAX_CLOCK_JUMP_SECONDS`; the configured example value `3600` remains
unapproved.

The privileged read-only preflight was saved on the VM at
`/tmp/g01-evidence/g01-preflight-report.md`. It exited with its expected
fail-closed status `9`: the host and USBGuard version were identified, and
`RuleFile=/etc/usbguard/rules.conf` plus
`RuleFolder=/etc/usbguard/rules.d/` were read, but the service was stopped and
IPC unavailable. Consequently device/rule queries were unavailable,
policy-changing tests were not run, and G-01 remains `UNVERIFIED`.

No daemon, USB authorization, or policy state was changed in this check. There
was no `restore_journal.json` in the project, app-state, or evidence paths.
No actual reboot or powered-off TTL-expiry test was performed.

## Installed service live test — 2026-11-03

The deployed project copy of `usbguard-policy.sh` was updated to match the
verified local version. With `CONFIG_VALUES` empty and
`IPC_TIMEOUT_SECONDS` unset, `usbguard_policy_timeout` returned the default
`5`. USBGuard 1.1.4's installed service was started without enabling it;
the real adapter reported the daemon running and IPC connected, and
successfully queried devices, blocked devices, rules, and both configured
persistent policy sources.

On the installed daemon, `append-rule --temporary` left
`/etc/usbguard/rules.conf` unchanged and its rule was removed. A non-matching
permanent test rule was appended to that file, survived an actual service
restart, and was removed. The RuleFile returned to its original empty SHA-256
(`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`); the
daemon config and RuleFolder were unchanged.

The lab USB (`048d:1234`) began with sysfs `authorized=0`. `allow-device`
changed it to `allow` and `authorized=1`; `block-device` changed it back to
`block` and `authorized=0`. It was never mounted. The service was stopped
afterward and remained disabled; final checks confirmed the service inactive,
no daemon process, the USB back at `authorized=0`, and no USB disk present.

The adapter copy on the VM now matches the tested local SHA-256
`13fccaee457fac82137474c4ff865346836ac14448ccc1a81dc810ae1c28d6f5`.
During the live check, no socket file was found under `/run`, although
`usbguard list-devices` and the adapter's IPC query succeeded. Use a successful
USBGuard IPC query as the readiness check rather than requiring a socket file
at a hard-coded path. The unit also logs that its `ConditionKernelCommandLine`
and `ConditionPathExists` keys are ignored; startup and IPC nevertheless
succeeded, and the installed unit was not modified.
G-01 remains `UNVERIFIED` until the clock trust and reboot/recovery cases are
verified.

## Environment observations

| Check | Observation | Result |
|---|---|---|
| VM identity | Hostname `vbox`, user `yf`, Kali Linux x86_64, kernel `7.0.12+kali-amd64` | Recorded |
| USBGuard CLI | `/usr/bin/usbguard`, version `1.1.4` | Installed |
| USBGuard service | `inactive` after the test; `systemctl is-enabled` remains `disabled`. It started successfully for the live test. | Restored |
| Read-only IPC query | Failed while the service was inactive; succeeded through both the CLI and adapter while the installed service was running. | Verified live |
| Daemon configuration | `/etc/usbguard/usbguard-daemon.conf` is `root:root`, mode `0600`; it was inspected read-only with `sudo`. | Read |
| Persistent policy settings | `RuleFile=/etc/usbguard/rules.conf` and `RuleFolder=/etc/usbguard/rules.d/` are both configured. USBGuard 1.1.4's local man page permits using both together. | Both sources identified |
| Rule file | `/etc/usbguard/rules.conf` is `root:root`, mode `0600`, and was empty before and after the live test; a permanent test rule survived restart and was removed. | Restored and verified |
| Rule folder | `/etc/usbguard/rules.d/` exists and contains no files. | Read-only observation |
| Service unit | Journal entries include warnings about unsupported `ConditionKernelCommandLine` and `ConditionPathExists` keys. Their impact on startup has not been determined. | Follow up; cause unverified |
| Recovery evidence | Snapshot UUID is recorded above and USB passthrough was exercised; snapshot restore and independent console recovery were not tested | `UNVERIFIED` |

The observations below include the earlier 2026-10-28 read-only baseline. The
2026-11-03 live observation above supersedes its statements about USB behavior
and confirms the test's bounded, temporary policy changes. It still does not
verify reboot recovery.

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
policy sources. The live observation above verifies USBGuard behavior using a
temporary test policy; it does not mark the adapter's production write gate
verified.

Results:

- VM: all transferred shell syntax checks passed.
- VM: config-reader (35 checks), result-model, lock, logger, time-guard, and
  Python unit tests (21 tests) passed.
- VM: mocked read-only adapter tests passed after the two files were copied.
  The adapter test puts its fake `usbguard` and `pgrep` commands first in
  `PATH`; it did not exercise the real daemon.
- Development environment (WSL): all unit test scripts and all 21 Python
  tests passed after the latest hardening changes.

## Gate decision

G-01 remains `UNVERIFIED`, not `PASS`: the isolated USB behavior and daemon
restart persistence were verified, but no OS reboot or clock-jump recovery
test was run. No production service was enabled or started, and no installed
policy file was changed.

Do not enable production writes or begin TTL/Reaper work until the clock source
and threshold are approved, reboot recovery is exercised, and the independent
recovery route is verified. Further live policy tests must remain limited to
the documented isolated procedure with a temporary daemon and policy.
