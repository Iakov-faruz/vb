#!/usr/bin/env bash
# Full installation script for USBGuard Approval Manager on fresh Ubuntu
set -euo pipefail
umask 077

###############################################################################
# Constants & Global State
###############################################################################
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Support running from parent directory
if [[ ! -d "$PROJECT_ROOT/usbguard-approval-manager" ]]; then
    PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
fi
DEBIAN_FRONTEND=noninteractive

# Target system paths
LIBEXEC_DIR="/usr/libexec/usbguard-approval-manager"
CONFIG_ETC="/etc/usbguard-approval-manager"
STATE_DIR="/var/lib/usbguard-approval-manager"
BACKUP_DIR="/var/backups/usbguard-approval-manager"
LOG_DIR="/var/log/usbguard-approval-manager"
LOCK_DIR="/run/lock"
SUDOERS_D="/etc/sudoers.d"
SYSTEMD="/etc/systemd/system"
LOGROTATE="/etc/logrotate.d"

REQUIRED_GROUPS=("usbadmins")
REQUIRED_PACKAGES=(
    "bash"
    "python3"
    "jq"
    "usbguard"
    "util-linux"
    "bsdutils"
    "whiptail"
    "logrotate"
    "sudo"
    "systemd"
    "coreutils"
    "diffutils"
)

###############################################################################
# Helper Functions
###############################################################################

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (or with sudo)."
    fi
}

apt_update() {
    log_info "Updating package lists..."
    apt-get update -qq 2>/dev/null || log_warn "apt-get update failed"
}

install_packages() {
    log_info "Installing required packages..."
    apt-get install -y -qq "${REQUIRED_PACKAGES[@]}" 2>/dev/null || {
        log_error "Failed to install required packages"
    }
}

ensure_groups() {
    log_info "Ensuring required groups exist..."
    for grp in "${REQUIRED_GROUPS[@]}"; do
        if ! getent group "$grp" >/dev/null; then
            groupadd "$grp" || log_warn "Failed to add group $grp"
        fi
    done
}

ensure_directories() {
    log_info "Creating required directories..."
    local dirs=(
        "$LIBEXEC_DIR"
        "$LIBEXEC_DIR/lib"
        "$CONFIG_ETC"
        "$CONFIG_ETC/config"
        "$STATE_DIR"
        "$BACKUP_DIR"
        "$LOG_DIR"
    )
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
    done
    # NOTE: /run/lock is a system directory owned by root:root.
    # Do NOT chmod/chown the directory itself. Only the lock file inside it
    # is managed (see ensure_state_files).
    chmod 750 "$LIBEXEC_DIR" "$LIBEXEC_DIR/lib" "$CONFIG_ETC" "$CONFIG_ETC/config"
    chmod 700 "$STATE_DIR" "$BACKUP_DIR"
    chmod 750 "$LOG_DIR"
    chown root:root "$LIBEXEC_DIR" "$LIBEXEC_DIR/lib" "$CONFIG_ETC" "$CONFIG_ETC/config"
    chown root:root "$STATE_DIR" "$BACKUP_DIR"
    chown root:usbadmins "$LOG_DIR"
}

ensure_state_files() {
    log_info "Ensuring required state files exist..."
    # Lock file: /run/lock/usbguard-approval-manager.lock (root:root, 0600)
    local lock_file="$LOCK_DIR/usbguard-approval-manager.lock"
    if [[ ! -f "$lock_file" ]]; then
        touch "$lock_file"
    fi
    chmod 600 "$lock_file"
    chown root:root "$lock_file"

    # ttl.json: root:root, 0600
    local ttl_file="$STATE_DIR/ttl.json"
    if [[ ! -f "$ttl_file" ]]; then
        printf '%s\n' '{"schema_version":1,"records":[]}' > "$ttl_file"
    fi
    chmod 600 "$ttl_file"
    chown root:root "$ttl_file"

    # audit.jsonl: root:usbadmins, 0640
    local audit_file="$LOG_DIR/audit.jsonl"
    if [[ ! -f "$audit_file" ]]; then
        : > "$audit_file"
    fi
    chmod 640 "$audit_file"
    chown root:usbadmins "$audit_file"

    # clock_state.json is created automatically by clock_state.py on first use.
}

install_scripts() {
    log_info "Installing application scripts..."
    local scripts=(
        "usb-approve.sh"
        "usb-revoke.sh"
        "usb-revoke-interactive.sh"
        "usb-list.sh"
        "usbguard-status.sh"
        "backup.sh"
        "restore.sh"
        "cleanup-expired.sh"
        "export-rules.sh"
        "import-rules.sh"
        "validate_all.sh"
        "backup-rules.sh"
        "restore-rules.sh"
    )
    for s in "${scripts[@]}"; do
        local src="$PROJECT_ROOT/usbguard-approval-manager/scripts/$s"
        local dst="$LIBEXEC_DIR/$s"
        [[ -f "$src" ]] || { log_warn "Source not found: $src"; continue; }
        cp -f "$src" "$dst"
        chmod 750 "$dst"
        chown root:root "$dst"
    done
}

install_lib_files() {
    log_info "Installing library files..."
    local libs=(
        "config-reader.sh"
        "validators.sh"
        "usbguard-policy.sh"
        "stages.sh"
        "lock.sh"
        "logger.sh"
        "result.sh"
        "journal.sh"
        "tui.sh"
        "time-guards.sh"
        "atomic-write.py"
        "audit_write.py"
        "clock_state.py"
        "lifecycle.py"
        "lifecycle.sh"
    )
    for l in "${libs[@]}"; do
        local src="$PROJECT_ROOT/usbguard-approval-manager/scripts/lib/$l"
        local dst="$LIBEXEC_DIR/lib/$l"
        [[ -f "$src" ]] || { log_warn "Source not found: $src"; continue; }
        cp -f "$src" "$dst"
        # All lib files are sourced or invoked as 'python3 file.py':
        # they must NOT be executable. Mode 0640 matches deploy.sh and
        # validate_all.sh expectations.
        chmod 640 "$dst"
        chown root:root "$dst"
    done
}

install_systemd_units() {
    log_info "Installing systemd unit files..."
    local units=(
        "usbguard-approval-ttl.service"
        "usbguard-approval-ttl.timer"
        "usbguard-approval-manager-reaper.service"
        "usbguard-approval-manager-reaper.timer"
    )
    for u in "${units[@]}"; do
        local src="$PROJECT_ROOT/usbguard-approval-manager/systemd/$u"
        local dst="$SYSTEMD/$u"
        [[ -f "$src" ]] || { log_warn "Source not found: $src"; continue; }
        cp -f "$src" "$dst"
        chmod 644 "$dst"
        chown root:root "$dst"
    done
}

install_sudoers() {
    log_info "Installing sudoers rules..."
    local sudoers_src="$PROJECT_ROOT/usbguard-approval-manager/sudoers/usbguard-approval-manager"
    local dst="$SUDOERS_D/usbguard-approval-manager"
    [[ -f "$sudoers_src" ]] || { log_warn "Source not found: $sudoers_src"; return; }
    cp -f "$sudoers_src" "$dst"
    chmod 440 "$dst"
    chown root:root "$dst"
}

install_logrotate() {
    log_info "Installing logrotate configuration..."
    local logrotate_src="$PROJECT_ROOT/usbguard-approval-manager/logrotate/usbguard-approval-manager"
    local dst="$LOGROTATE/usbguard-approval-manager"
    [[ -f "$logrotate_src" ]] || { log_warn "Source not found: $logrotate_src"; return; }
    cp -f "$logrotate_src" "$dst"
    chmod 644 "$dst"
    chown root:root "$dst"
}

install_config() {
    log_info "Installing configuration files..."
    # Primary config comes from conf/approval-manager.conf.example
    # (matches deploy.sh). This file contains only the 6 SRS keys that
    # config-reader.sh accepts.
    local primary_src="$PROJECT_ROOT/usbguard-approval-manager/conf/approval-manager.conf.example"
    local primary_dst="$CONFIG_ETC/approval-manager.conf"
    if [[ -f "$primary_src" ]]; then
        cp -f "$primary_src" "$primary_dst"
        chmod 600 "$primary_dst"
        chown root:root "$primary_dst"
    else
        log_warn "Primary config source not found: $primary_src"
    fi

    # Secondary reference example (matches deploy.sh CONFIG_CONF_REL).
    # Contains extra keys not accepted by config-reader.sh; must never be
    # used as the primary config.
    local example_src="$PROJECT_ROOT/usbguard-approval-manager/config/usbguard-approval-manager.conf.example"
    local example_dst="$CONFIG_ETC/config/usbguard-approval-manager.conf.example"
    if [[ -f "$example_src" ]]; then
        cp -f "$example_src" "$example_dst"
        chmod 600 "$example_dst"
        chown root:root "$example_dst"
    else
        log_warn "Secondary config example not found: $example_src"
    fi
}

###############################################################################
# Main Installation
###############################################################################

main() {
    require_root
    log_info "Starting USBGuard Approval Manager full installation"
    log_info "Project root: $PROJECT_ROOT"

    apt_update
    install_packages
    ensure_groups
    ensure_directories
    ensure_state_files

    install_scripts
    install_lib_files
    install_systemd_units
    install_sudoers
    install_logrotate
    install_config

    if ! command -v usbguard >/dev/null 2>&1; then
        log_warn "USBGuard not found; attempting installation..."
        apt-get install -y -qq usbguard 2>/dev/null || log_warn "Failed to install USBGuard"
    fi

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload 2>/dev/null || log_warn "systemctl daemon-reload failed"

    # IMPORTANT: Timers are NOT enabled automatically.
    # cleanup-expired.sh requires a G-01 verification marker before any
    # policy change. Enabling timers without G-01 causes repeated failures
    # and violates SRS.
    log_info "Timers installed but NOT enabled (G-01 verification required before enabling)."
    log_info "After G-01 approval, enable manually with:"
    log_info "  systemctl enable --now usbguard-approval-ttl.timer"
    log_info "  systemctl enable --now usbguard-approval-manager-reaper.timer"

    log_info "Verifying installation (static)..."
    if bash "$PROJECT_ROOT/usbguard-approval-manager/scripts/validate_all.sh" --static; then
        log_info "Static validation PASSED"
    else
        log_warn "Static validation had issues (check output above)"
    fi

    log_info "Installation complete!"
    log_info "Summary:"
    log_info "  - Scripts installed to: $LIBEXEC_DIR"
    log_info "  - Config: $CONFIG_ETC/approval-manager.conf"
    log_info "  - Config example: $CONFIG_ETC/config/usbguard-approval-manager.conf.example"
    log_info "  - State: $STATE_DIR"
    log_info "  - Logs: $LOG_DIR"
    log_info "  - Sudoers: $SUDOERS_D/usbguard-approval-manager"
    log_info "  - Logrotate: $LOGROTATE/usbguard-approval-manager"
    log_info "  - Systemd units installed (NOT enabled)"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Add admin users to the usbadmins group:"
    log_info "       usermod -aG usbadmins <user>"
    log_info "  2. Complete G-01 verification per DOCS (isolated lab VM, USB passthrough)."
    log_info "  3. After G-01 approval, create /var/lib/usbguard-approval-manager/g01-verified"
    log_info "       with content 'G01_STATUS=PASS', mode 0600, owner root:root."
    log_info "  4. Enable timers:"
    log_info "       systemctl enable --now usbguard-approval-ttl.timer"
    log_info "       systemctl enable --now usbguard-approval-manager-reaper.timer"
}

main "$@"