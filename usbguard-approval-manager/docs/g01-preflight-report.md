# G-01 Lab Preflight Report

**Checked:** 2026-11-03 19:46 UTC
**Overall G-01 status:** `UNVERIFIED`  
**Scope:** Isolated live testing with the unmounted disposable USB and
temporary policy files under `/run`. The installed USBGuard service and
`/etc/usbguard` policy were not changed; clock and reboot tests were not run.

## Latest live lab observation — 2026-11-03 19:46 UTC

The VM was confirmed in VirtualBox as the running `kali` machine. VirtualBox
reported current snapshot `20:39 3.11.26` (UUID
`d6b60282-f896-45ac-abfe-bba5911e2556`). Inside the VM the hostname is `vbox`;
USBGuard 1.1.4's installed service was inactive, no daemon or IPC socket was
present, and the sole USB disk (`048d:1234`) was unmounted.

The latest isolated integration run used a temporary daemon configuration and
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

## Environment observations

| Check | Observation | Result |
|---|---|---|
| VM identity | Hostname `vbox`, user `yf`, Kali Linux x86_64, kernel `7.0.12+kali-amd64` | Recorded |
| USBGuard CLI | `/usr/bin/usbguard`, version `1.1.4` | Installed |
| USBGuard service | `inactive`; `systemctl is-enabled` reports `disabled` | Not ready for IPC integration |
| Read-only IPC query | `usbguard list-devices` returned `IPC connect: service=usbguard: Connection refused`, exit status `1` | IPC unavailable |
| Daemon configuration | `/etc/usbguard/usbguard-daemon.conf` is `root:root`, mode `0600`; it was inspected read-only with `sudo`. | Read |
| Persistent policy settings | `RuleFile=/etc/usbguard/rules.conf` and `RuleFolder=/etc/usbguard/rules.d/` are both configured. USBGuard 1.1.4's local man page permits using both together. | Both sources identified |
| Rule file | `/etc/usbguard/rules.conf` is `root:root`, mode `0600`, and contains zero active rule lines. | Read-only observation |
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
