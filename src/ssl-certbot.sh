#!/usr/bin/env bash
# ssl-certbot - Lightweight SSL Certificate Manager
# Main entry point for `w ssl` command

set -euo pipefail
umask 077

# ── Resolve library path ───────────────────────────────────────────
LIB_DIR="/usr/local/lib/ssl-certbot"
if [[ ! -d "$LIB_DIR" ]]; then
    # Development mode: use script directory
    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Source modules
# shellcheck source=common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=port_service.sh
source "${LIB_DIR}/port_service.sh"
# shellcheck source=cert.sh
source "${LIB_DIR}/cert.sh"
# shellcheck source=cron.sh
source "${LIB_DIR}/cron.sh"

# ── Trap handler ────────────────────────────────────────────────────
_ssl_cleanup() {
    local exit_code=$?
    ssl_log INFO "Cleanup triggered (exit code: $exit_code)..."
    ssl_restore_services
    ssl_release_lock
    if [[ "$exit_code" -ne 0 ]]; then
        ssl_log WARN "Process exited with errors. Services have been restored."
    fi
}
trap _ssl_cleanup EXIT INT TERM HUP

# ── Interactive menu ────────────────────────────────────────────────
ssl_interactive_menu() {
    echo ""
    echo "${C_BOLD}${C_CYAN}SSL Certificate Manager${C_RESET}"
    echo "────────────────────────────────────────"
    echo ""
    echo "  1. Apply or renew certificate"
    echo "  2. List certificates"
    echo "  3. Show certificate status"
    echo "  4. View logs"
    echo "  5. Help"
    echo "  0. Exit"
    echo ""
    read -rp "  Select [0-5]: " choice

    case "$choice" in
        1)
            echo ""
            echo "${C_BOLD}Important:${C_RESET}"
            echo "  - Domain must resolve to this VPS's public IP"
            echo "  - TCP 80 must be reachable from the internet"
            echo "  - Services on ports 80/443 will be briefly stopped"
            echo "  - Services will be restored after completion"
            echo "  - This tool will NOT force-kill unknown processes"
            echo ""
            read -rp "  Enter domain (e.g. example.com): " domain
            if [[ -z "$domain" ]]; then
                ssl_log ERROR "No domain entered."
                return 1
            fi
            ssl_cmd_apply "$domain"
            ;;
        2) ssl_list_certs ;;
        3) ssl_cert_status ;;
        4) ssl_cmd_logs ;;
        5) ssl_cmd_help ;;
        0) exit 0 ;;
        *) ssl_log ERROR "Invalid selection." ;;
    esac
}

# ── Command: apply ──────────────────────────────────────────────────
ssl_cmd_apply() {
    local domain="$1"

    # Validate domain
    if ! ssl_validate_domain "$domain"; then
        return 1
    fi

    ssl_log INFO "Starting certificate process for: $domain"
    ssl_log INFO "OS: $SSL_OS $SSL_OS_VER | Init: $SSL_INIT"

    # Ensure acme.sh is available
    ssl_ensure_acme

    # Acquire lock
    ssl_acquire_lock

    # Check DNS (basic: resolve domain, compare with VPS IP)
    ssl_check_dns "$domain"

    # Pause services on 80/443
    echo ""
    echo "${C_BOLD}Checking ports 80 and 443...${C_RESET}"
    if ! ssl_pause_port_services; then
        ssl_log ERROR "Cannot proceed: unable to free required ports."
        return 1
    fi

    # Issue certificate
    echo ""
    echo "${C_BOLD}Requesting certificate...${C_RESET}"
    local issue_result=0
    ssl_issue_cert "$domain" || issue_result=$?

    # Restore services (always, regardless of result)
    echo ""
    echo "${C_BOLD}Restoring services...${C_RESET}"
    ssl_restore_services

    if [[ "$issue_result" -ne 0 ]]; then
        ssl_log ERROR "Certificate issuance failed for $domain"
        ssl_log ERROR "Services have been restored to their original state."
        return 1
    fi

    # Set up auto-renewal
    echo ""
    echo "${C_BOLD}Configuring auto-renewal...${C_RESET}"
    ssl_install_cron_job

    # Final summary
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    echo ""
    echo "${C_GREEN}${C_BOLD}Certificate successfully issued!${C_RESET}"
    echo "────────────────────────────────────────"
    echo "  Domain:      $domain"
    echo "  Certificate: ${cert_dir}/fullchain.pem"
    echo "  Private key: ${cert_dir}/privkey.pem"
    echo ""
    echo "  ${C_YELLOW}Note:${C_RESET} Services paused during issuance have been restored."
    echo "  Please verify that your service configurations point to the"
    echo "  new certificate paths shown above."
    echo ""

    ssl_log INFO "Certificate process completed for $domain"
}

# ── Command: renew ──────────────────────────────────────────────────
ssl_cmd_renew() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        # Renew all
        ssl_log INFO "Renewing all certificates..."
        ssl_acquire_lock

        if ! ssl_pause_port_services; then
            ssl_log ERROR "Cannot free ports for renewal."
            return 1
        fi

        local any_renewed=0
        for cert_dir in "$SSL_CERT_BASE"/*/; do
            [[ ! -d "$cert_dir" ]] && continue
            local d
            d=$(basename "$cert_dir")
            if ssl_renew_cert "$d"; then
                any_renewed=1
            fi
        done

        ssl_restore_services

        if [[ "$any_renewed" -eq 0 ]]; then
            echo "No certificates to renew."
        fi
        return 0
    fi

    # Renew specific domain
    if ! ssl_validate_domain "$domain"; then
        return 1
    fi

    ssl_acquire_lock

    if ! ssl_pause_port_services; then
        ssl_log ERROR "Cannot free ports for renewal."
        return 1
    fi

    local renew_result=0
    ssl_renew_cert "$domain" || renew_result=$?

    ssl_restore_services

    if [[ "$renew_result" -ne 0 ]]; then
        ssl_log ERROR "Renewal failed for $domain. Services restored."
        return 1
    fi

    echo ""
    echo "${C_GREEN}Certificate renewed for $domain${C_RESET}"
    echo "  Services have been restored to their original state."
    echo "  Please confirm that your services have loaded the new certificate."
    echo ""
}

# ── Command: logs ───────────────────────────────────────────────────
ssl_cmd_logs() {
    local log_file="$SSL_LOG_PRIMARY"
    if [[ ! -f "$log_file" ]]; then
        log_file="$SSL_LOG_FALLBACK"
    fi
    if [[ ! -f "$log_file" ]]; then
        echo "No log file found."
        return 0
    fi
    echo ""
    echo "${C_BOLD}Recent Logs${C_RESET} ($log_file)"
    echo "────────────────────────────────────────"
    tail -n 50 "$log_file"
    echo ""
}

# ── Command: help ───────────────────────────────────────────────────
ssl_cmd_help() {
    echo ""
    echo "${C_BOLD}${C_CYAN}SSL Certificate Manager - Help${C_RESET}"
    echo "────────────────────────────────────────"
    echo ""
    echo "  ${C_BOLD}Usage:${C_RESET}"
    echo "    w ssl                    Interactive menu"
    echo "    w ssl <domain>           Apply or renew certificate"
    echo "    w ssl list               List managed certificates"
    echo "    w ssl status [domain]    Show certificate status"
    echo "    w ssl renew [domain]     Manually renew certificate(s)"
    echo "    w ssl logs               View recent logs"
    echo "    w ssl help               Show this help"
    echo ""
    echo "  ${C_BOLD}How it works:${C_RESET}"
    echo "    1. Domain must resolve to this server's public IP"
    echo "    2. TCP 80 must be reachable (HTTP-01 validation)"
    echo "    3. Services on 80/443 are briefly paused during issuance"
    echo "    4. All paused services are restored afterward"
    echo "    5. Certificates auto-renew via cron"
    echo ""
    echo "  ${C_BOLD}Certificate paths:${C_RESET}"
    echo "    /root/cert/<domain>/fullchain.pem"
    echo "    /root/cert/<domain>/privkey.pem"
    echo ""
    echo "  ${C_BOLD}Supported systems:${C_RESET}"
    echo "    Debian 11/12/13, Ubuntu 20.04/22.04/24.04, Alpine 3.x"
    echo ""
    echo "  ${C_BOLD}Notes:${C_RESET}"
    echo "    - TCP 80 is required for HTTP-01 validation"
    echo "    - TCP 443 is in the pause/restore scope but not required for validation"
    echo "    - Unknown processes on 80/443 will NOT be killed"
    echo "    - No Docker, Certbot, or heavy runtimes required"
    echo "    - Powered by acme.sh + Let's Encrypt"
    echo ""
}

# ── DNS check (basic) ──────────────────────────────────────────────
ssl_check_dns() {
    local domain="$1"

    ssl_log INFO "Checking DNS resolution for $domain..."

    # Get VPS public IP
    local vps_ip=""
    vps_ip=$(curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
             curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
             curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
             echo "")

    if [[ -z "$vps_ip" ]]; then
        ssl_log WARN "Could not determine VPS public IP. Proceeding anyway..."
        return 0
    fi

    ssl_log INFO "VPS public IP: $vps_ip"

    # Resolve domain
    local domain_ip=""
    if command -v dig >/dev/null 2>&1; then
        domain_ip=$(dig +short A "$domain" 2>/dev/null | head -1)
    elif command -v nslookup >/dev/null 2>&1; then
        domain_ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address:/ && NR>2 {print $2}' | head -1)
    elif command -v host >/dev/null 2>&1; then
        domain_ip=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4}' | head -1)
    else
        # Use getent as last resort
        domain_ip=$(getent ahosts "$domain" 2>/dev/null | awk 'NR==1 {print $1}')
    fi

    if [[ -z "$domain_ip" ]]; then
        ssl_log ERROR "Cannot resolve domain: $domain"
        ssl_log ERROR "Please ensure DNS is configured and propagated."
        return 1
    fi

    ssl_log INFO "Domain $domain resolves to: $domain_ip"

    if [[ "$domain_ip" != "$vps_ip" ]]; then
        ssl_log WARN "Domain IP ($domain_ip) does not match VPS IP ($vps_ip)."
        ssl_log WARN "If this VPS uses a different public IP or IPv6, this may be expected."
        echo ""
        read -rp "  Continue anyway? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            ssl_log INFO "Aborted by user."
            return 1
        fi
    fi

    return 0
}

# ── Main dispatch ───────────────────────────────────────────────────
main() {
    ssl_require_root
    ssl_init_log
    ssl_detect_os
    ssl_ensure_deps

    # Parse subcommand (case-insensitive)
    local subcmd="${1:-}"
    subcmd=$(echo "$subcmd" | tr '[:upper:]' '[:lower:]')

    case "$subcmd" in
        ""|menu)
            ssl_interactive_menu
            ;;
        list)
            ssl_list_certs
            ;;
        status)
            ssl_cert_status "${2:-}"
            ;;
        renew)
            ssl_cmd_renew "${2:-}"
            ;;
        logs|log)
            ssl_cmd_logs
            ;;
        help|--help|-h)
            ssl_cmd_help
            ;;
        *)
            # Treat as domain name
            ssl_cmd_apply "$subcmd"
            ;;
    esac
}

main "$@"
