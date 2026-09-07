#!/usr/bin/env bash
# ssl-certbot automatic renewal script
# Called by cron to renew all managed certificates
# Uses the same port-handling logic as initial issuance

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/ssl-certbot"

# Source all modules
# shellcheck source=common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=port_service.sh
source "${LIB_DIR}/port_service.sh"
# shellcheck source=cert.sh
source "${LIB_DIR}/cert.sh"

# ── Trap for cleanup ───────────────────────────────────────────────
_renew_cleanup() {
    ssl_log INFO "Renewal cleanup triggered..."
    ssl_restore_services
    ssl_release_lock
}
trap _renew_cleanup EXIT INT TERM HUP

# ── Main ────────────────────────────────────────────────────────────
main() {
    ssl_init_log
    ssl_log INFO "=== Auto-renewal started ==="
    ssl_detect_os

    # Acquire lock
    ssl_acquire_lock

    if ssl_renew_managed_certificates; then
        ssl_log INFO "=== Auto-renewal finished successfully ==="
        exit 0
    fi

    ssl_log ERROR "=== Auto-renewal finished with failures ==="
    exit 1
}

main "$@"
