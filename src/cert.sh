#!/usr/bin/env bash
# ssl-certbot certificate operations
# Handles: issue, deploy, status, list, renew

# ── Issue certificate ───────────────────────────────────────────────
ssl_issue_cert() {
    local domain="$1"
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"

    ssl_log INFO "Requesting certificate for: $domain"
    ssl_log INFO "Method: Let's Encrypt HTTP-01 Standalone"

    # Create cert directory
    mkdir -p "$cert_dir"
    chmod 700 "$cert_dir"

    # Issue via acme.sh standalone mode
    local acme_exit
    set +e
    "$SSL_ACME_HOME/acme.sh" --issue \
        --standalone \
        -d "$domain" \
        --server letsencrypt \
        --keylength 2048 \
        --log "$_ssl_log_file" 2>&1
    acme_exit=$?
    set -e

    # acme.sh returns 0 on success, 2 if already valid and skipped
    if [[ "$acme_exit" -ne 0 ]] && [[ "$acme_exit" -ne 2 ]]; then
        ssl_log ERROR "acme.sh failed with exit code $acme_exit"
        return 1
    fi

    # Install (deploy) cert to our directory
    set +e
    "$SSL_ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --fullchain-file "$fullchain" \
        --key-file "$privkey" 2>&1
    local install_exit=$?
    set -e

    if [[ "$install_exit" -ne 0 ]]; then
        ssl_log ERROR "Failed to install certificate files."
        return 1
    fi

    # Verify files exist
    if [[ ! -f "$fullchain" ]] || [[ ! -f "$privkey" ]]; then
        ssl_log ERROR "Certificate files not found after installation."
        return 1
    fi

    # Set permissions
    chmod 644 "$fullchain"
    chmod 600 "$privkey"
    chmod 700 "$cert_dir"
    chmod 700 "$SSL_CERT_BASE"

    ssl_log INFO "Certificate issued and deployed successfully."
    ssl_log INFO "  Full chain: $fullchain"
    ssl_log INFO "  Private key: $privkey"

    # Log certificate details
    local expiry
    expiry=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2)
    ssl_log INFO "  Expires: ${expiry:-unknown}"

    return 0
}

# ── Renew certificate ──────────────────────────────────────────────
ssl_renew_cert() {
    local domain="$1"
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"

    ssl_log INFO "Renewing certificate for: $domain"

    if [[ ! -d "$SSL_ACME_HOME/${domain}" ]] && [[ ! -d "$SSL_ACME_HOME/${domain}_ecc" ]]; then
        ssl_log ERROR "No existing certificate record found for $domain in acme.sh."
        ssl_log ERROR "Please issue the certificate first with: w ssl $domain"
        return 1
    fi

    local acme_exit=0
    set +e
    "$SSL_ACME_HOME/acme.sh" --renew \
        -d "$domain" \
        --standalone \
        --server letsencrypt \
        --log "$_ssl_log_file" 2>&1
    acme_exit=$?
    set -e

    if [[ "$acme_exit" -ne 0 ]] && [[ "$acme_exit" -ne 2 ]]; then
        ssl_log ERROR "acme.sh renew failed with exit code $acme_exit"
        return 1
    fi

    # Re-install cert
    set +e
    "$SSL_ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --fullchain-file "$fullchain" \
        --key-file "$privkey" 2>&1
    local install_exit=$?
    set -e

    if [[ "$install_exit" -ne 0 ]]; then
        ssl_log ERROR "Failed to install renewed certificate."
        return 1
    fi

    # Set permissions
    chmod 644 "$fullchain"
    chmod 600 "$privkey"

    ssl_log INFO "Certificate renewed successfully for $domain"
    return 0
}

# Return 0 when the deployed certificate expires within the renewal window,
# 1 when it remains valid beyond the window, and 2 when it cannot be read.
ssl_cert_needs_renewal_file() {
    local fullchain="$1"
    local renew_window_seconds="${SSL_RENEW_WINDOW_SECONDS:-2592000}"

    if ! openssl x509 -in "$fullchain" -noout >/dev/null 2>&1; then
        ssl_log ERROR "Cannot read certificate: $fullchain"
        return 2
    fi

    if openssl x509 -in "$fullchain" -checkend "$renew_window_seconds" -noout >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# Renew managed certificates that are within the renewal window. The caller
# must hold the process lock before invoking this function.
ssl_renew_managed_certificates() {
    local -a domains=()
    local renewed=0
    local skipped=0
    local failed=0
    local cert_dir domain fullchain check_result

    if [[ ! -d "$SSL_CERT_BASE" ]]; then
        ssl_log INFO "No certificates directory found. Nothing to renew."
        return 0
    fi

    for cert_dir in "$SSL_CERT_BASE"/*/; do
        [[ ! -d "$cert_dir" ]] && continue
        domain=$(basename "$cert_dir")
        fullchain="${cert_dir}fullchain.pem"
        [[ ! -f "$fullchain" ]] && continue

        if ssl_cert_needs_renewal_file "$fullchain"; then
            domains+=("$domain")
            continue
        else
            check_result=$?
        fi
        if [[ "$check_result" -eq 1 ]]; then
            skipped=$((skipped + 1))
            ssl_log INFO "$domain: valid for more than 30 days, skipping."
        else
            failed=$((failed + 1))
            ssl_log ERROR "$domain: cannot determine certificate expiry; skipping."
        fi
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        ssl_log INFO "Renewal summary: renewed=0 skipped=$skipped failed=$failed"
        if [[ "$failed" -eq 0 ]]; then
            return 0
        fi
        return 1
    fi

    ssl_log INFO "Certificates requiring renewal: ${domains[*]}"
    if ! ssl_pause_port_services; then
        ssl_log ERROR "Cannot free ports for renewal."
        ssl_log ERROR "Renewal summary: renewed=0 skipped=$skipped failed=${#domains[@]}"
        return 1
    fi

    for domain in "${domains[@]}"; do
        if ssl_renew_cert "$domain"; then
            renewed=$((renewed + 1))
            ssl_log INFO "Renewed: $domain"
        else
            failed=$((failed + 1))
            ssl_log ERROR "Failed to renew: $domain"
        fi
    done

    if ! ssl_restore_services; then
        failed=$((failed + 1))
        ssl_log ERROR "One or more paused services could not be restored."
    fi

    ssl_log INFO "Renewal summary: renewed=$renewed skipped=$skipped failed=$failed"
    if [[ "$failed" -eq 0 ]]; then
        return 0
    fi
    return 1
}

# ── List certificates ──────────────────────────────────────────────
ssl_list_certs() {
    if [[ ! -d "$SSL_CERT_BASE" ]]; then
        echo "No certificates found."
        return 0
    fi

    local found=0
    echo ""
    echo "${C_BOLD}Managed SSL Certificates${C_RESET}"
    echo "────────────────────────────────────────"

    for cert_dir in "$SSL_CERT_BASE"/*/; do
        [[ ! -d "$cert_dir" ]] && continue
        local domain
        domain=$(basename "$cert_dir")
        local fullchain="${cert_dir}fullchain.pem"
        local privkey="${cert_dir}privkey.pem"

        if [[ ! -f "$fullchain" ]]; then
            continue
        fi

        found=1
        local expiry days_left issuer
        expiry=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2)
        issuer=$(openssl x509 -in "$fullchain" -noout -issuer 2>/dev/null | sed 's/issuer=//')

        # openssl -checkend is portable across GNU and BusyBox systems.
        local renewal_state=0
        if ssl_cert_needs_renewal_file "$fullchain"; then
            renewal_state=0
        else
            renewal_state=$?
        fi

        local status_color="$C_GREEN"
        case "$renewal_state" in
            0)
                days_left="within 30 days"
                status_color="$C_YELLOW"
                ;;
            1)
                days_left="more than 30 days"
                ;;
            *)
                days_left="unknown"
                status_color="$C_RED"
                ;;
        esac

        echo ""
        echo "  ${C_BOLD}$domain${C_RESET}"
        echo "    Certificate: $fullchain"
        echo "    Private key: $privkey"
        echo "    Expires:     ${expiry:-unknown}"
        echo "    Remaining:   ${status_color}${days_left}${C_RESET}"
        echo "    Issuer:      ${issuer:-unknown}"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "  No certificates found."
    fi
    echo ""
}

# ── Certificate status ──────────────────────────────────────────────
ssl_cert_status() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        # Show all
        ssl_list_certs

        ssl_cron_status
        return 0
    fi

    # Show specific domain
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    local fullchain="${cert_dir}/fullchain.pem"

    if [[ ! -f "$fullchain" ]]; then
        ssl_log ERROR "No certificate found for: $domain"
        return 1
    fi

    echo ""
    echo "${C_BOLD}Certificate Status: $domain${C_RESET}"
    echo "────────────────────────────────────────"
    openssl x509 -in "$fullchain" -noout -subject -issuer -dates -serial 2>/dev/null | \
        sed 's/^/  /'
    echo ""

    # Check permissions
    local privkey="${cert_dir}/privkey.pem"
    if [[ -f "$privkey" ]]; then
        local perm
        perm=$(stat -c '%a' "$privkey" 2>/dev/null || stat -f '%Lp' "$privkey" 2>/dev/null || echo "?")
        if [[ "$perm" == "600" ]]; then
            echo "  Private key permissions: ${C_GREEN}$perm (OK)${C_RESET}"
        else
            echo "  Private key permissions: ${C_RED}$perm (should be 600)${C_RESET}"
        fi
    fi
    echo ""
}
