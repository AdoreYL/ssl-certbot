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

    local cert_base="/root/cert"
    if [[ ! -d "$cert_base" ]]; then
        ssl_log INFO "No certificates directory found. Nothing to renew."
        exit 0
    fi

    # Collect domains to renew
    local -a domains=()
    for cert_dir in "$cert_base"/*/; do
        [[ ! -d "$cert_dir" ]] && continue
        local domain
        domain=$(basename "$cert_dir")
        local fullchain="${cert_dir}fullchain.pem"
        if [[ -f "$fullchain" ]]; then
            # Check if certificate needs renewal (< 30 days remaining)
            local exp_epoch now_epoch days_left
            exp_epoch=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | \
                cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            if [[ "$exp_epoch" -gt 0 ]]; then
                days_left=$(( (exp_epoch - now_epoch) / 86400 ))
                if [[ "$days_left" -gt 30 ]]; then
                    ssl_log INFO "$domain: ${days_left} days remaining, skipping."
                    continue
                fi
            fi
            domains+=("$domain")
        fi
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        ssl_log INFO "No certificates need renewal."
        exit 0
    fi

    ssl_log INFO "Certificates to renew: ${domains[*]}"

    # Pause services occupying 80/443
    if ! ssl_pause_port_services; then
        ssl_log ERROR "Cannot free ports for renewal. Aborting."
        exit 1
    fi

    # Renew each domain
    local any_failed=0
    for domain in "${domains[@]}"; do
        if ssl_renew_cert "$domain"; then
            ssl_log INFO "Renewed: $domain"
        else
            ssl_log ERROR "Failed to renew: $domain"
            any_failed=1
        fi
    done

    # Restore services (also handled by trap, but do it explicitly)
    ssl_restore_services

    # Verify permissions
    for domain in "${domains[@]}"; do
        local privkey="${cert_base}/${domain}/privkey.pem"
        if [[ -f "$privkey" ]]; then
            chmod 600 "$privkey"
        fi
    done

    ssl_log INFO "=== Auto-renewal finished ==="

    if [[ "$any_failed" -eq 1 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
