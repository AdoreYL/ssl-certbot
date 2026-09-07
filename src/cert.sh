#!/usr/bin/env bash
# ssl-certbot certificate operations
# Handles: issue, deploy, status, list, renew

# ── Issue certificate ───────────────────────────────────────────────
ssl_issue_cert() {
    local domain="$1"
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"

    ssl_log INFO "正在申请证书：$domain"
    ssl_log INFO "方式：Let's Encrypt HTTP-01 独立模式"

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
        ssl_log ERROR "acme.sh 执行失败，退出码：$acme_exit"
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
        ssl_log ERROR "无法安装证书文件。"
        return 1
    fi

    # Verify files exist
    if [[ ! -f "$fullchain" ]] || [[ ! -f "$privkey" ]]; then
        ssl_log ERROR "安装后未找到证书文件。"
        return 1
    fi

    # Set permissions
    chmod 644 "$fullchain"
    chmod 600 "$privkey"
    chmod 700 "$cert_dir"
    chmod 700 "$SSL_CERT_BASE"

    ssl_log INFO "证书已签发并保存。"
    ssl_log INFO "证书链：$fullchain"
    ssl_log INFO "私钥：$privkey"

    # Log certificate details
    local expiry
    expiry=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2)
    ssl_log INFO "到期时间：${expiry:-未知}"

    return 0
}

# ── Renew certificate ──────────────────────────────────────────────
ssl_renew_cert() {
    local domain="$1"
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"

    ssl_log INFO "正在续期证书：$domain"

    if [[ ! -d "$SSL_ACME_HOME/${domain}" ]] && [[ ! -d "$SSL_ACME_HOME/${domain}_ecc" ]]; then
        ssl_log ERROR "acme.sh 中未找到 $domain 的证书记录。"
        ssl_log ERROR "请先执行：w ssl $domain"
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
        ssl_log ERROR "acme.sh 续期失败，退出码：$acme_exit"
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
        ssl_log ERROR "无法安装续期后的证书。"
        return 1
    fi

    # Set permissions
    chmod 644 "$fullchain"
    chmod 600 "$privkey"

    ssl_log INFO "$domain 的证书续期成功。"
    return 0
}

# Return 0 when the deployed certificate expires within the renewal window,
# 1 when it remains valid beyond the window, and 2 when it cannot be read.
ssl_cert_needs_renewal_file() {
    local fullchain="$1"
    local renew_window_seconds="${SSL_RENEW_WINDOW_SECONDS:-2592000}"

    if ! openssl x509 -in "$fullchain" -noout >/dev/null 2>&1; then
        ssl_log ERROR "无法读取证书：$fullchain"
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
        ssl_log INFO "未找到证书目录，无需续期。"
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
            ssl_log INFO "$domain：有效期超过 30 天，跳过。"
        else
            failed=$((failed + 1))
            ssl_log ERROR "$domain：无法确定到期时间，已跳过。"
        fi
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        ssl_log INFO "续期汇总：成功=0，跳过=$skipped，失败=$failed"
        if [[ "$failed" -eq 0 ]]; then
            return 0
        fi
        return 1
    fi

    ssl_log INFO "需要续期的证书：${domains[*]}"
    if ! ssl_pause_port_services; then
        ssl_log ERROR "无法安全释放续期所需端口。"
        ssl_log ERROR "续期汇总：成功=0，跳过=$skipped，失败=${#domains[@]}"
        return 1
    fi

    for domain in "${domains[@]}"; do
        if ssl_renew_cert "$domain"; then
            renewed=$((renewed + 1))
            ssl_log INFO "已续期：$domain"
        else
            failed=$((failed + 1))
            ssl_log ERROR "续期失败：$domain"
        fi
    done

    if ! ssl_restore_services; then
        failed=$((failed + 1))
        ssl_log ERROR "一个或多个已暂停服务未能恢复。"
    fi

    ssl_log INFO "续期汇总：成功=$renewed，跳过=$skipped，失败=$failed"
    if [[ "$failed" -eq 0 ]]; then
        return 0
    fi
    return 1
}

# ── List certificates ──────────────────────────────────────────────
ssl_list_certs() {
    if [[ ! -d "$SSL_CERT_BASE" ]]; then
        echo "未找到证书。"
        return 0
    fi

    local found=0
    echo ""
    echo "${C_BOLD}已管理的 SSL 证书${C_RESET}"
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
                days_left="30 天内到期"
                status_color="$C_YELLOW"
                ;;
            1)
                days_left="有效期超过 30 天"
                ;;
            *)
                days_left="未知"
                status_color="$C_RED"
                ;;
        esac

        echo ""
        echo "  ${C_BOLD}$domain${C_RESET}"
        echo "    证书链：$fullchain"
        echo "    私钥：$privkey"
        echo "    到期时间：${expiry:-未知}"
        echo "    剩余有效期：${status_color}${days_left}${C_RESET}"
        echo "    签发者：${issuer:-未知}"
    done

    if [[ "$found" -eq 0 ]]; then
        echo "  未找到证书。"
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
        ssl_log ERROR "未找到域名证书：$domain"
        return 1
    fi

    echo ""
    echo "${C_BOLD}证书状态：$domain${C_RESET}"
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
            echo "  私钥权限：${C_GREEN}$perm（正常）${C_RESET}"
        else
            echo "  私钥权限：${C_RED}$perm（应为 600）${C_RESET}"
        fi
    fi
    echo ""
}
