# USBGuard Approval Manager

A command-line and text-interface manager for controlled temporary and
permanent USBGuard approvals.

## Requirements baseline

Implementation follows the approved SRS v4.5 baseline in [../USB.md](../USB.md).
The prior v4.4 specification is retained as historical reference.
G-01 and restore/deployment safety evidence remain mandatory gates before
implementing or enabling dependent policy-changing operations.

The application code, configuration, deployment units, and tests are kept in
this directory. The specification, implementation roadmap, and prompt catalog
remain at the repository root.

## Project status

The foundation includes a strict configuration reader, shared result model,
atomic JSON writer, process lock, separate operational/Audit logging, and
calendar clock guards with focused unit tests. The USBGuard adapter includes
read and policy-changing operations, but every mutation is fail-closed behind
a root-owned, mode-`0600` G-01 evidence marker and the shared process lock.
Callers must hold the lock for the entire mutation operation. No marker is
included in this project. The clock-sync provider remains disabled by default
until G-01 verifies a target-specific source, so time-dependent operations
fail closed.

## Development rules

- Keep components small, modular, and focused on one responsibility.
- Preserve the approved SRS baseline and stop on unresolved security behavior.
- Do not change USBGuard policy on the development host.
- Run policy-changing integration tests only in an isolated lab VM with
  USB passthrough and a verified recovery route.

## Local checks

From this directory in Linux/WSL, run the syntax checks and all unit tests with:

```bash
make test
```

The unit-test target uses mocked USBGuard commands; it does not change policy
or verify G-01 against a live daemon. The G-01 integration test uses a
temporary daemon configuration and policy but does change the selected
physical USB device state. Run it only in the isolated lab VM, with the
installed service inactive, the USB disk unmounted, and recovery available.
The live test uses the USBGuard CLI directly because the adapter must remain
gated until G-01 is approved; mocked unit tests cover the adapter methods.
It verifies kernel authorization and the USB disk node as well as USBGuard's
reported device state. After stopping its isolated daemon, it restores the
test USB's kernel authorization, waits up to 10 seconds for the disk to
re-enumerate, and verifies that the disk is unmounted.
Override `BASH` or `PYTHON` if needed, for example
`make test PYTHON=python3.13`.

Audit writes require the protected `/var/log/usbguard-approval-manager`
directory owned by `root:usbadmins` with mode `0750`; the Audit file is
`root:usbadmins` mode `0640`. The logger reports write failures to its caller,
which must preserve any already-applied policy result.

`time-guards.sh` does not set or adjust the system clock. Its unit tests use
simulated provider evidence and clock samples; they do not prove that a real
time-sync source is trustworthy. Implement and enable that provider only after
the G-01 evidence is documented for the target system.

Before any real G-01 tests, complete [docs/lab-checklist.md](docs/lab-checklist.md).
The checklist is planning guidance, not evidence that the VM is currently ready.
The integration test does not restart the installed service or create the
verification marker. Keep G-01 `UNVERIFIED` until the clock and reboot cases
are independently completed and reviewed.
The latest VM observations are recorded in
[docs/g01-preflight-report.md](docs/g01-preflight-report.md); G-01 remains
`UNVERIFIED`.
