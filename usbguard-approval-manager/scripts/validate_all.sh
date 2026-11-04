#!/usr/bin/env bash
set -euo pipefail
# validate_all.sh - Comprehensive SUPER-FINAL v4.5 Validation Script
# Performs complete system validation before deployment
# USB.md / SRS v4.5 / SUPER-FINAL 7PHASES compliant

if [[ -z "${USBAM_VALIDATE_ALL+x}" ]]; then
  readonly USBAM_VALIDATE_ALL=1
  readonly USBAM_VALIDATE_VERSION="4.5.0"
fi

# Determine project root relative to this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Source sub-modules using relative paths from project root
source "$PROJECT_ROOT/scripts/lib/validators.sh"
source "$PROJECT_ROOT/scripts/lib/stages.sh"
source "$PROJECT_ROOT/scripts/lib/time-guards.sh"
source "$PROJECT_ROOT/scripts/lib/lock.sh"
source "$PROJECT_ROOT/scripts/lib/result.sh"




