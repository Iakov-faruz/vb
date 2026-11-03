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
calendar clock guards with focused unit tests. A read-only USBGuard adapter is
available for mocked CLI queries and daemon policy-source discovery, including
configurations with both `RuleFile` and `RuleFolder`; policy-changing
operations have not been implemented. The clock-sync provider remains disabled
by default until G-01 verifies a target-specific source, so time-dependent
operations fail closed.

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

The test target uses mocked USBGuard commands; it does not change policy or
verify G-01 against a live daemon. Override `BASH` or `PYTHON` if needed, for
example `make test PYTHON=python3.13`.

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
The latest non-invasive VM preflight is recorded in
[docs/g01-preflight-report.md](docs/g01-preflight-report.md); G-01 remains
`UNVERIFIED`.
