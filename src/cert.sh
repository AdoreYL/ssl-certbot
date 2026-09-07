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
        --force \
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
        --force \
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

        # Calculate days remaining
        if [[ -n "$expiry" ]]; then
            local exp_epoch now_epoch
            exp_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -D "%b %d %H:%M:%S %Y %Z" -d "$expiry" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            if [[ "$exp_epoch" -gt 0 ]]; then
                days_left=$(( (exp_epoch - now_epoch) / 86400 ))
            else
                days_left="?"
            fi
        else
            days_left="?"
        fi

        local status_color="$C_GREEN"
        if [[ "$days_left" != "?" ]] && [[ "$days_left" -lt 30 ]]; then
            status_color="$C_YELLOW"
        fi
        if [[ "$days_left" != "?" ]] && [[ "$days_left" -lt 7 ]]; then
            status_color="$C_RED"
        fi

        echo ""
        echo "  ${C_BOLD}$domain${C_RESET}"
        echo "    Certificate: $fullchain"
        echo "    Private key: $privkey"
        echo "    Expires:     ${expiry:-unknown}"
        echo "    Remaining:   ${status_color}${days_left} days${C_RESET}"
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

        # Show cron status
        echo "${C_BOLD}Auto-Renewal Status${C_RESET}"
        echo "────────────────────────────────────────"
        if crontab -l 2>/dev/null | grep -q "$SSL_CRON_MARKER"; then
            echo "  ${C_GREEN}Active${C_RESET} - cron job installed"
            crontab -l 2>/dev/null | grep "$SSL_CRON_MARKER" | sed 's/^/  /'
        else
            echo "  ${C_YELLOW}Not configured${C_RESET}"
        fi
        echo ""
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
