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
    "usbutils"
    "usbmuxd"
    "libusb-1.0-0-dev"
    "pkg-config"
    "usbguard"
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
        "$STATE_DIR"
        "$BACKUP_DIR"
        "$LOG_DIR"
        "$LOCK_DIR"
    )
    for d in "${dirs[@]}"; do
        mkdir -p "$d"
    done
    chmod 755 "$LIBEXEC_DIR" "$LIBEXEC_DIR/lib" "$CONFIG_ETC" "$STATE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$LOCK_DIR"
    chmod 700 "$STATE_DIR" "$BACKUP_DIR"
    chmod 750 "$LOCK_DIR"
}

install_scripts() {
    log_info "Installing application scripts..."
    local scripts=(
        "usb-approve.sh"
        "usb-revoke.sh"
        "usb-revoke-interactive.sh"
        "usb-list.sh"
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
        if [[ "$l" == *.sh ]]; then
            chmod 750 "$dst"
        else
            chmod 640 "$dst"
        fi
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
    local config_example_src="$PROJECT_ROOT/usbguard-approval-manager/config/usbguard-approval-manager.conf.example"
    local dst="$CONFIG_ETC/approval-manager.conf"
    [[ -f "$config_example_src" ]] || { log_warn "Config source not found"; return; }
    cp -f "$config_example_src" "$dst"
    chmod 600 "$dst"
    chown root:root "$dst"
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

    install_scripts
    install_lib_files
    install_systemd_units
    install_sudoers
    install_logrotate
    install_config

    # Verify usbguard is installed
    if ! command -v usbguard >/dev/null 2>&1; then
        log_warn "USBGuard not found; attempting installation..."
        apt-get install -y -qq usbguard 2>/dev/null || log_warn "Failed to install USBGuard"
    fi

    # Reload systemd
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload 2>/dev/null || log_warn "systemctl daemon-reload failed"

    # Enable timers
    log_info "Enabling TTL timer and Reaper timer..."
    systemctl enable --now usbguard-approval-ttl.timer 2>/dev/null || log_warn "Failed to enable TTL timer"
    systemctl enable --now usbguard-approval-manager-reaper.timer 2>/dev/null || log_warn "Failed to enable reaper timer"

    # Verify installation
    log_info "Verifying installation..."
    if bash "$PROJECT_ROOT/usbguard-approval-manager/scripts/validate_all.sh" --static; then
        log_info "Static validation PASSED"
    else
        log_warn "Static validation had issues (check output above)"
    fi

    log_info "Installation complete!"
    log_info "Summary:"
    log_info "  - Scripts installed to: $LIBEXEC_DIR"
    log_info "  - Config: $CONFIG_ETC/approval-manager.conf"
    log_info "  - State: $STATE_DIR"
    log_info "  - Logs: $LOG_DIR"
    log_info "  - Sudoers: $SUDOERS_D/usbguard-approval-manager"
    log_info "  - Logrotate: $LOGROTATE/usbguard-approval-manager"
    log_info "  - Systemd units enabled"
}

main "$@"