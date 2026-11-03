# USBGuard Lab Checklist

Use this checklist before any G-01 test or USBGuard policy-changing operation.
An isolated live test on 2026-11-03 confirmed USBGuard 1.1.4 and the disposable
USB in the VM, but the recovery route and reboot/clock behavior remain
**UNVERIFIED**. Reconfirm current conditions before every test; prior evidence
does not establish that the VM is currently ready.

## Lab entry criteria

- [ ] This is the dedicated, isolated VM, not the development workstation or a
  shared host.
- [ ] The VM identity, operating system, and USBGuard version are recorded.
- [ ] USB passthrough is configured and only disposable test devices are
  connected. No production or human-critical USB device is attached.
- [ ] USBGuard is installed with a test-only policy. The daemon configuration,
  active policy source (`RuleFile`/`RuleFolder`), and protected rules are
  understood.
  Record both paths independently when both settings are configured; the
  installed USBGuard version may support using them together.
- [ ] A recent VM snapshot exists and its restore procedure has been checked.
- [ ] A recovery route is available without relying on the USB device being
  tested (for example, VM console access).
- [ ] G-01 test commands, expected observations, and stop conditions are
  prepared. Every state-changing command will be run individually with
  before/after evidence.

If any prerequisite is unknown, stop and mark the affected test `UNVERIFIED`.
Do not install packages, enable services, change daemon configuration, or
modify policy as an implicit part of verifying lab readiness.

## Read-only checks

Run read-only checks only after confirming the VM identity:

- Record OS and kernel information.
- Inspect the USBGuard package/version and daemon configuration.
- Inspect daemon/service status, IPC availability, connected devices, and
  active rules.
- Capture command, stdout, stderr, exit status, time, and the VM snapshot
  identifier in the G-01 evidence report.

The read-only adapter unit tests use mocked commands and do not require or
contact a real USBGuard installation.

## Forbidden outside an approved lab

Never run these operations on a development workstation, shared machine, or
unverified VM:

- `usbguard allow-device`, `usbguard block-device`, or other device-state
  changes.
- `usbguard append-rule`, `usbguard remove-rule`, or edits to active or
  persistent USBGuard policy.
- Restarting/reloading the daemon, rebooting to test persistence, or changing
  `RuleFile`, `RuleFolder`, or protected system rules.
- Installing or enabling USBGuard as an unplanned part of a test.

Even inside the lab, run a state-changing operation only when the relevant
G-01 test plan explicitly calls for it and the recovery route is available.

## Stop and recovery

Stop immediately if VM identity is uncertain, an unexpected device appears,
the observed policy differs from the recorded baseline, an operation has an
ambiguous result, or the recovery route is unavailable.

1. Do not retry an operation whose outcome is uncertain.
2. Record the last command, full output, exit status, and observed state.
3. Use the VM console or the pre-verified snapshot recovery procedure; do not
   rely on the affected USB device for access.
4. Re-check the VM identity, daemon status, connected devices, active policy,
   and persistent policy before resuming.
5. Mark the affected test `FAIL` if evidence proves a safety criterion was
   violated; otherwise mark it `UNVERIFIED` until the state is established.

No G-01 result is a PASS until its required observations and recovery evidence
are recorded.
