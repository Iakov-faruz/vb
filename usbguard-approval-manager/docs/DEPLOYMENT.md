# Deployment and health checks

## Install

Run on the intended Linux target after USBGuard is configured and IPC is
available:

```bash
sudo bash deploy.sh
```

The installer checks dependencies, the configured policy sources and IPC,
shows their paths and hashes, then asks for confirmation. It does not write
USBGuard rules, alter `00-system.rules`, enable/start the timer, or overwrite
existing configuration, TTL state, Audit data, or backups. New application
files and units are installed transactionally; a failed check restores the
previous managed files.

The timer remains in its prior activation state. Do not enable it until G-01
and the required target-specific release gates have been completed. The
`usbadmins` group must already exist.

For packaging and local testing, pass an existing temporary directory:

```bash
stage="$(mktemp -d)"
bash deploy.sh --root "$stage"
USBAM_ROOT="$stage" bash validate_all.sh --static
bash deploy-uninstall.sh --root "$stage"
```

A staging root must be absolute, existing, and not a symlink; `/` is not
accepted as a staging root. Staging mode never invokes `systemctl` or changes
USBGuard policy.

## Health validation

`validate_all.sh` is read-only. It checks configuration and TTL schema,
ownership/modes, service and timer fields, sudoers/logrotate syntax, and
runtime service/IPC/backup/log/lock health. It does not create files, acquire
the lock, rotate logs, or change state.

```bash
sudo bash validate_all.sh
bash validate_all.sh --static
```

`--static` validates installed files only and explicitly reports runtime
checks as unverified. Full validation returns non-zero if any required runtime
condition fails or if no retained backup is available.

## Remove

```bash
sudo bash deploy-uninstall.sh
```

The uninstaller asks for confirmation, stops the timer and waits for an active
one-shot service to finish before removing code, units, sudoers, and logrotate
configuration. It always preserves `/etc/usbguard-approval-manager`,
`/var/lib/usbguard-approval-manager` (including `ttl.json`), Audit logs,
backups, and the lock file.

## Installed paths

| Purpose | Path |
|---|---|
| Application scripts and libraries | `/usr/libexec/usbguard-approval-manager/` |
| Configuration | `/etc/usbguard-approval-manager/approval-manager.conf` |
| State and TTL | `/var/lib/usbguard-approval-manager/` |
| Backups | `/var/backups/usbguard-approval-manager/` |
| Audit log | `/var/log/usbguard-approval-manager/audit.jsonl` |
| Shared lock | `/run/lock/usbguard-approval-manager.lock` |
| TTL service/timer | `usbguard-approval-ttl.service` / `usbguard-approval-ttl.timer` |

The service runs as `root:root` with `ProtectSystem=strict` and write access
only to state, logs, and the exact lock file. The `usbadmins` sudoers entries
accept no command-line arguments and invoke only interactive approval/revoke
entry points.
