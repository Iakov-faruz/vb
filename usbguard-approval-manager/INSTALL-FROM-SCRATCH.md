# USBGuard Approval Manager — Installation from Scratch

This guide installs the USBGuard Approval Manager on a fresh Ubuntu/Debian
(or RHEL/Fedora) system. Two installation paths are supported:

- **Path A (recommended): `deploy.sh`** — transactional, idempotent, preserves
  existing state, does not enable systemd timers automatically.
- **Path B: `install-usbguard-approval-manager.sh`** — full installer for a
  fresh machine; prepares directories, permissions, state files, and systemd
  units, but does NOT enable timers automatically.

Both paths require USBGuard to be installed and running, and both leave the
TTL timer disabled until G-01 verification is approved (see §7).

---

## 1. System requirements

- Linux distribution with `systemd` (Ubuntu 22.04 LTS or newer recommended;
  RHEL 9 / Fedora 38+ also supported).
- Root or `sudo` access.
- USBGuard installed and running (`systemctl status usbguard`).
- USBGuard IPC available (`usbguard list-rules` must succeed).
- Network access for package installation.

## 2. Required packages

### Debian / Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y \
  bash python3 jq usbguard \
  coreutils util-linux systemd sudo logrotate whiptail diffutils
```

### RHEL / Fedora

```bash
sudo dnf install -y \
  bash python3 jq usbguard \
  coreutils util-linux systemd sudo logrotate newt diffutils
```

Notes:
- `whiptail` (from `newt` on RHEL) is used by the interactive TUI.
- `flock` (from `util-linux`) is required for locking.
- `logger` (from `bsdutils` on Debian) is used for syslog output.

## 3. Create the `usbadmins` group

The manager requires a `usbadmins` group for audit log access and sudoers rules.

```bash
sudo groupadd --system usbadmins
sudo usermod -aG usbadmins <your-admin-user>
```

Log out and back in (or run `newgrp usbadmins`) so group membership takes effect.

## 4. Get the code

```bash
git clone https://github.com/Iakov-faruz/vb.git
cd vb
```

Check out the branch or tag approved for deployment (e.g., `main`).

## 5. Installation

### Path A — `deploy.sh` (recommended)

`deploy.sh` is transactional: it preflights the host, shows a diff against
existing files, requires interactive confirmation, and rolls back on failure.
It does NOT enable systemd timers and does NOT change USBGuard policy.

```bash
cd usbguard-approval-manager

# Inspect help
bash deploy.sh --help

# Optional: staging test (no host changes)
stage="$(mktemp -d)"
bash deploy.sh --root "$stage"

# Live installation (requires root, USBGuard IPC, interactive confirmation)
sudo bash deploy.sh
```

`deploy.sh` installs:
- application scripts to `/usr/libexec/usbguard-approval-manager/`
- library files to `/usr/libexec/usbguard-approval-manager/lib/`
- systemd units to `/etc/systemd/system/`
- sudoers rules to `/etc/sudoers.d/`
- logrotate config to `/etc/logrotate.d/`
- primary config from `conf/approval-manager.conf.example` to
  `/etc/usbguard-approval-manager/approval-manager.conf`
- reference example from `config/usbguard-approval-manager.conf.example` to
  `/etc/usbguard-approval-manager/config/usbguard-approval-manager.conf.example`

`deploy.sh` preserves existing config, TTL state, audit log, and backups.

### Path B — `install-usbguard-approval-manager.sh` (fresh machine)

The root installer prepares directories, permissions, state files, and systemd
units from scratch. Unlike `deploy.sh`, it does not perform a preflight diff or
rollback, and it does not require USBGuard IPC during installation. It also
does NOT enable timers automatically.

```bash
cd /path/to/project
sudo bash install-usbguard-approval-manager.sh
```

The installer creates:
- `usbadmins` group if missing
- `/usr/libexec/usbguard-approval-manager/` (root:root, 0750) and `lib/`
- `/etc/usbguard-approval-manager/` (root:root, 0750) and `config/`
- `/var/lib/usbguard-approval-manager/` (root:root, 0700)
- `/var/backups/usbguard-approval-manager/` (root:root, 0700)
- `/var/log/usbguard-approval-manager/` (root:usbadmins, 0750)
- `/run/lock/usbguard-approval-manager.lock` (root:root, 0600)
- `ttl.json` (`{"schema_version":1,"records":[]}`, 0600)
- `audit.jsonl` (root:usbadmins, 0640)
- All application scripts, library files, systemd units, sudoers, logrotate,
  and config files from the package

After installation, enable timers manually once G-01 is approved (see §8).

## 6. Verification

Validate the installation (read-only):

```bash
# From the source tree
sudo bash usbguard-approval-manager/scripts/validate_all.sh --static

# Or if installed
sudo bash /usr/libexec/usbguard-approval-manager/validate_all.sh --static
```

Static validation checks file permissions, configuration syntax, systemd unit
fields, sudoers syntax, logrotate syntax, and TTL JSON schema. Runtime checks
(`validate_all.sh` without `--static`) additionally verify USBGuard IPC,
timer activation, and backup integrity.

## 7. G-01 verification marker

Policy-changing operations (approve, revoke, restore, import) require a
G-01 verification marker. The marker is checked by `is_g01_verified()` in
`scripts/lib/usbguard-policy.sh`.

The marker must be:
- Path: `/var/lib/usbguard-approval-manager/g01-verified`
- Owner: `root:root`
- Mode: `0600`
- Content (single line): `G01_STATUS=PASS`

**Do not create the marker until G-01 verification is completed in an isolated
lab VM with USB passthrough and a verified recovery route.** See
`DOCS/usbguard-approval-manager/lab-checklist.md` for the full procedure.

To create the marker after G-01 approval:

```bash
sudo install -o root -g root -m 0600 /dev/null /var/lib/usbguard-approval-manager/g01-verified
echo 'G01_STATUS=PASS' | sudo tee /var/lib/usbguard-approval-manager/g01-verified >/dev/null
```

## 8. Enable systemd timers (after G-01 approval only)

Both installation paths leave the TTL and Reaper timers disabled. Enable them
only after G-01 verification is approved:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now usbguard-approval-ttl.timer
sudo systemctl enable --now usbguard-approval-manager-reaper.timer
```

Verify:

```bash
systemctl status usbguard-approval-ttl.timer --no-pager
systemctl status usbguard-approval-manager-reaper.timer --no-pager
```

## 9. Initial check (read-only)

```bash
# Full status report (versioned JSON, schema_version: 1)
sudo /usr/libexec/usbguard-approval-manager/usbguard-status.sh --json

# List managed TTL rules
sudo /usr/libexec/usbguard-approval-manager/usb-list.sh
```

Both commands are read-only and do not modify USBGuard policy.

## 10. Uninstall

`deploy-uninstall.sh` removes application code, systemd units, sudoers, and
logrotate config, while preserving:
- `/etc/usbguard-approval-manager/` (config)
- `/var/lib/usbguard-approval-manager/` (TTL state, clock state, journal)
- `/var/log/usbguard-approval-manager/` (audit log)
- `/var/backups/usbguard-approval-manager/` (backups)
- `/run/lock/usbguard-approval-manager.lock`

```bash
cd usbguard-approval-manager
sudo bash deploy-uninstall.sh
```

## Troubleshooting

- **`usbadmins` missing** — run `sudo groupadd --system usbadmins` and re-run
  the installer.
- **USBGuard IPC unavailable** — check `systemctl status usbguard`; verify the
  daemon socket and permissions in `/etc/usbguard/usbguard-daemon.conf`.
- **`validate_all.sh --static` fails** — inspect the reported failures; common
  causes are wrong file ownership or stale systemd unit fields.
- **Timers fail repeatedly** — verify G-01 marker exists and is valid before
  enabling timers.
- **Windows host** — the scripts target Linux/systemd; use a Linux VM or WSL
  only for syntax checks, never for live policy operations.
