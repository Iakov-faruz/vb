#!/usr/bin/env bash
# Root-only, no-argument prompt used by the restricted sudoers entry.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (( $# != 0 )); then
  printf 'usb-revoke-interactive: ERROR: arguments are not accepted\n' >&2
  exit 7
fi
if [[ ! -t 0 ]]; then
  printf 'usb-revoke-interactive: ERROR: an interactive terminal is required\n' >&2
  exit 1
fi

printf '%s\n' \
  'Enter the managed UUID of an expired approval and a current USBGuard device ID.' \
  'The explicit revoke command validates both values and asks for final confirmation.'
if ! read -r -p 'Expired managed UUID: ' managed_id ||
  ! read -r -p 'Current USBGuard device ID: ' device_id; then
  printf 'usb-revoke-interactive: ERROR: input ended before selection was complete\n' >&2
  exit 130
fi

if [[ ! "$managed_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-4[[:xdigit:]]{3}-[89abAB][[:xdigit:]]{3}-[[:xdigit:]]{12}$ ]]; then
  printf 'usb-revoke-interactive: ERROR: managed UUID must be UUID v4\n' >&2
  exit 7
fi
if [[ ! "$device_id" =~ ^[0-9]+$ ]]; then
  printf 'usb-revoke-interactive: ERROR: device ID must be numeric\n' >&2
  exit 7
fi

exec "$SCRIPT_DIR/usb-revoke.sh" --managed-id "$managed_id" --device "$device_id"
