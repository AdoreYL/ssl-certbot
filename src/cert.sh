#!/usr/bin/env bash
# ssl-certbot certificate operations
# Handles: issue, deploy, status, list, renew

# ── Certificate display helpers ────────────────────────────────────
ssl_format_cert_expiry() {
    local expiry="$1"
    local formatted

    [[ -n "$expiry" ]] || {
        echo "未知"
        return 0
    }

    formatted=$(TZ=Asia/Shanghai date -d "$expiry" '+%Y年%m月%d日 %H:%M:%S（中国标准时间）' 2>/dev/null || true)
    if [[ -n "$formatted" ]]; then
        echo "$formatted"
    else
        echo "$expiry"
    fi
}

# Content fingerprint of a deployed certificate. Used to prove that a renewal
# actually replaced the certificate instead of re-installing identical bytes.
ssl_certificate_digest() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | cut -d' ' -f1 || true
    else
        openssl dgst -sha256 "$file" 2>/dev/null | sed 's/.*= //' || true
    fi
}

ssl_cert_expiry_from_file() {
    local fullchain="$1"
    local raw_expiry

    raw_expiry=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
    ssl_format_cert_expiry "$raw_expiry"
}

# ── Issue certificate ───────────────────────────────────────────────
ssl_acme_listener_args() {
    case "$1" in
        ipv4) printf '%s\n' --listen-v4 ;;
        ipv6) printf '%s\n' --listen-v6 ;;
        dual) return 0 ;;
        *)
            ssl_log ERROR "无效的网络模式：${1:-空}。"
            return 1
            ;;
    esac
}

ssl_issue_cert() {
    local domain="$1"
    local mode="$2"
    local cert_dir="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"
    local -a listener_args=()

    ssl_validate_network_mode "$mode" || return 1
    mapfile -t listener_args < <(ssl_acme_listener_args "$mode")

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
        "${listener_args[@]}" \
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

    if ! ssl_save_network_mode "$domain" "$mode"; then
        ssl_log ERROR "证书已安装，但无法保存 $domain 的网络模式。"
        return 1
    fi

    ssl_log INFO "证书已签发并保存。"
    ssl_log INFO "证书链：$fullchain"
    ssl_log INFO "私钥：$privkey"

    # Log certificate details
    local expiry
    expiry=$(ssl_cert_expiry_from_file "$fullchain")
    ssl_log INFO "到期时间：${expiry:-未知}"

    return 0
}

# Run acme.sh for one Cloudflare account. --home keeps the official install
# directory (so dnsapi/dns_cf resolves), while --config-home isolates the
# account key, CA state, issued certificate and account.conf per account.
ssl_dns_acme_call() {
    local id="$1" token home result log_file
    shift
    if [[ ! -x "$SSL_ACME_HOME/acme.sh" ]]; then
        ssl_log ERROR "未找到 acme.sh：$SSL_ACME_HOME/acme.sh。请先完成一次安装或使用 w ssl update。"
        return 1
    fi
    ssl_cf_prepare_acme "$id" || return 1
    token=$(ssl_cf_token "$id") || return 1
    home=$(ssl_cf_acme_home "$id")
    log_file="$home/acme.sh.log"
    # Reject unsafe existing files before redirecting any provider output.
    if [[ -e "$log_file" || -L "$log_file" ]]; then
        ssl_cf_private_file "$log_file" || { ssl_log ERROR 'acme.sh 日志权限不安全。'; return 1; }
    else
        (umask 077; set -o noclobber; : > "$log_file") || return 1
        chmod 600 "$log_file" || return 1
    fi
    # The environment Token always wins over any persisted value, and the
    # other Cloudflare credential shapes are cleared so an account cannot be
    # authenticated with another account's key. Upstream output is hidden and
    # only sent to the account-restricted 0600 log, because it can contain
    # provider responses.
    if ( export CF_Token="$token"; unset CF_Key CF_Email CF_Zone_ID CF_Account_ID;
         "$SSL_ACME_HOME/acme.sh" --home "$SSL_ACME_HOME" --config-home "$home" \
             --log "$log_file" --log-level 1 "$@" >>"$log_file" 2>&1 ); then
        return 0
    else
        result=$?
    fi
    chmod 600 "$log_file" 2>/dev/null || true
    [[ "$result" -eq 2 ]] && return 2
    ssl_log ERROR "Cloudflare DNS 验证失败（acme.sh 退出码：$result）。请查看 $log_file 并检查该账号的 Zone 权限。"
    return 1
}

ssl_deploy_dns_cert() {
    local domain="$1" id="$2" binding="${3:-}" action="$4"
    local dir backup file before after result=0 failed=0 restore_failed=0
    dir="$SSL_CERT_BASE/$(ssl_cert_slug "$domain")"
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    backup=$(mktemp -d "$dir/.deploy-backup.XXXXXXXX") || return 1
    chmod 700 "$backup" || return 1
    for file in fullchain.pem privkey.pem; do
        if [[ -L "$dir/$file" || ( -e "$dir/$file" && ! -f "$dir/$file" ) ]]; then
            rmdir "$backup"; return 1
        fi
        if [[ -f "$dir/$file" ]]; then
            cp -p "$dir/$file" "$backup/$file" || return 1
        fi
    done
    # --renew itself can deploy to saved Le_Real*Path destinations. Protect
    # the pair before invoking acme.sh, not just before --install-cert.
    before=$(ssl_certificate_digest "$dir/fullchain.pem")
    if [[ "$action" == issue ]]; then
        ssl_dns_acme_call "$id" --issue --dns dns_cf -d "$domain" --server letsencrypt --keylength 2048 || result=$?
        [[ "$result" == 0 || "$result" == 2 ]] || failed=1
    else
        ssl_dns_acme_call "$id" --renew -d "$domain" --server letsencrypt || result=$?
        [[ "$result" == 0 ]] || failed=1
        if [[ "$result" == 2 ]]; then
            ssl_log ERROR "$domain 未发生续期（acme.sh 返回跳过），按失败处理。"
        fi
    fi
    if [[ "$failed" == 0 ]]; then
        if ! ssl_dns_acme_call "$id" --install-cert -d "$domain" \
        --fullchain-file "$dir/fullchain.pem" --key-file "$dir/privkey.pem"; then
            failed=1
        elif [[ ! -s "$dir/fullchain.pem" || ! -s "$dir/privkey.pem" ]] || \
            ! chmod 644 "$dir/fullchain.pem" || ! chmod 600 "$dir/privkey.pem"; then
            failed=1
        fi
    fi
    if [[ "$failed" == 0 && "$action" == renew ]]; then
        after=$(ssl_certificate_digest "$dir/fullchain.pem")
        if [[ -z "$after" || "$before" == "$after" ]]; then
            ssl_log ERROR "$domain 未产生新证书（部署内容未变化或无法读取），按失败处理。"
            failed=1
        fi
    fi
    if [[ "$failed" == 0 && "$binding" != no-bind ]]; then
        ssl_cf_bind_domain "$domain" "$id" "$binding" || failed=1
    fi
    if [[ "$failed" == 1 ]]; then
        for file in fullchain.pem privkey.pem; do
            if [[ -f "$backup/$file" ]]; then
                mv -f "$backup/$file" "$dir/$file" || restore_failed=1
            else
                rm -f "$dir/$file" || restore_failed=1
            fi
        done
        if [[ "$restore_failed" == 1 ]]; then
            ssl_log ERROR "部署失败且旧证书恢复失败，请保留并检查备份：$backup"
            return 1
        fi
        ssl_log ERROR '证书可能已签发，但部署或绑定失败；已恢复原部署，未报告完整成功。'
    fi
    rm -f "$backup/fullchain.pem" "$backup/privkey.pem"
    rmdir "$backup"
    [[ "$failed" == 0 ]]
}

ssl_issue_dns_cert() {
    local domain="$1" id="$2" force="${3:-}"
    local dir="$SSL_CERT_BASE/$(ssl_cert_slug "$domain")"
    ssl_validate_dns_domain "$domain" && ssl_cf_account_ready "$id" || return 1
    ssl_cf_test_account "$id" "$domain" || return 1
    mkdir -p "$dir" && chmod 700 "$dir" 2>/dev/null || return 1
    ssl_deploy_dns_cert "$domain" "$id" "$force" issue || return 1
    ssl_log INFO "证书已保存：$dir/fullchain.pem；私钥：$dir/privkey.pem"
}

ssl_renew_dns_cert() {
    local domain="$1" id="$2"
    ssl_validate_dns_domain "$domain" && ssl_cf_account_ready "$id" || return 1
    [[ $(ssl_cf_account_for_domain "$domain") == "$id" ]] || return 1
    # acme.sh --renew takes only domain/ecc/server. The validation method
    # comes from Le_Webroot persisted in this account's own config-home during
    # --issue, so renewal cannot fall back to standalone HTTP-01.
    ssl_deploy_dns_cert "$domain" "$id" no-bind renew
}

# ── Renew certificate ──────────────────────────────────────────────
ssl_renew_cert() {
    local domain="$1"
    local mode
    local cert_dir="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")"
    local fullchain="${cert_dir}/fullchain.pem"
    local privkey="${cert_dir}/privkey.pem"
    local -a listener_args=()

    ssl_log INFO "正在续期证书：$domain"

    if [[ ! -d "$SSL_ACME_HOME/${domain}" ]] && [[ ! -d "$SSL_ACME_HOME/${domain}_ecc" ]]; then
        ssl_log ERROR "acme.sh 中未找到 $domain 的证书记录。"
        ssl_log ERROR "请先执行：w ssl $domain"
        return 1
    fi

    mode=$(ssl_load_network_mode "$domain")
    if [[ "$mode" == "dual" && ! -r "$(ssl_network_mode_file "$domain")" ]]; then
        ssl_log WARN "$domain 未保存网络模式，将按旧版双栈方式续期。"
    fi
    ssl_validate_network_mode "$mode" || return 1
    mapfile -t listener_args < <(ssl_acme_listener_args "$mode")

    local acme_exit=0
    set +e
    "$SSL_ACME_HOME/acme.sh" --renew \
        -d "$domain" \
        --standalone \
        --server letsencrypt \
        "${listener_args[@]}" \
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
    local -a domains=() http_domains=()
    local renewed=0
    local skipped=0
    local failed=0
    local cert_dir domain fullchain check_result method id

    if [[ ! -d "$SSL_CERT_BASE" ]]; then
        ssl_log INFO "未找到证书目录，无需续期。"
        return 0
    fi

    for cert_dir in "$SSL_CERT_BASE"/*/; do
        [[ ! -d "$cert_dir" ]] && continue
        domain=$(ssl_slug_to_domain "$(basename "$cert_dir")")
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
    for domain in "${domains[@]}"; do
        method=$(ssl_validation_method "$domain") || method=invalid
        if [[ "$method" == dns ]]; then
            id=$(ssl_cf_account_for_domain "$domain") || id=
            if [[ -n "$id" ]] && ssl_renew_dns_cert "$domain" "$id"; then
                renewed=$((renewed + 1))
            else
                failed=$((failed + 1))
                ssl_log ERROR "续期失败：$domain"
            fi
        elif [[ "$method" == http ]]; then
            http_domains+=("$domain")
        else
            failed=$((failed + 1))
            ssl_log ERROR "续期失败：$domain（验证方式配置无效）"
        fi
    done
    if [[ ${#http_domains[@]} -gt 0 ]]; then
        if ssl_pause_port_services; then
            for domain in "${http_domains[@]}"; do
                if ssl_renew_cert "$domain"; then
                    renewed=$((renewed + 1))
                else
                    failed=$((failed + 1))
                fi
            done
        else
            failed=$((failed + ${#http_domains[@]}))
            ssl_log ERROR "HTTP 端口预检失败，但 DNS 证书已独立处理。"
        fi
        if ! ssl_restore_services; then
            failed=$((failed + 1))
            ssl_log ERROR "一个或多个已暂停服务未能恢复。"
        fi
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
        domain=$(ssl_slug_to_domain "$(basename "$cert_dir")")
        local fullchain="${cert_dir}fullchain.pem"
        local privkey="${cert_dir}privkey.pem"

        if [[ ! -f "$fullchain" ]]; then
            continue
        fi

        found=1
        local expiry days_left issuer
        expiry=$(ssl_cert_expiry_from_file "$fullchain")
        issuer=$(openssl x509 -in "$fullchain" -noout -issuer 2>/dev/null | sed 's/issuer=//' || true)

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
        ssl_print_validation_mode "$domain"
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
    local cert_dir="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")"
    local fullchain="${cert_dir}/fullchain.pem"

    if [[ ! -f "$fullchain" ]]; then
        ssl_log ERROR "未找到域名证书：$domain"
        return 1
    fi

    echo ""
    echo "${C_BOLD}证书状态：$domain${C_RESET}"
    echo "────────────────────────────────────────"
    local subject issuer serial expiry
    subject=$(openssl x509 -in "$fullchain" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)
    issuer=$(openssl x509 -in "$fullchain" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)
    serial=$(openssl x509 -in "$fullchain" -noout -serial 2>/dev/null | sed 's/^serial=//' || true)
    expiry=$(ssl_cert_expiry_from_file "$fullchain")
    echo "  主题：${subject:-未知}"
    echo "  签发者：${issuer:-未知}"
    echo "  到期时间：${expiry:-未知}"
    ssl_print_validation_mode "$domain" '  '
    echo "  序列号：${serial:-未知}"
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

# Print the validation method for a domain. $2 selects the indent so the
# list page (four spaces) and the status page (two spaces) keep alignment.
# This is display-only: it must never return non-zero, otherwise a single
# malformed or hand-edited config file would abort the whole certificate list
# under `set -e`.
ssl_print_validation_mode() {
    local domain="$1" indent="${2-    }" method id name
    method=$(ssl_validation_method "$domain" 2>/dev/null) || method=invalid
    case "$method" in
        dns)
            id=$(ssl_cf_account_for_domain "$domain" 2>/dev/null) || id=""
            if [[ -z "$id" ]]; then
                echo "${indent}验证方式：Cloudflare DNS-01（账号绑定缺失或无效，请执行 w ssl cf-rebind 修复）"
            else
                name='未知账号'
                if ssl_cf_account_ready "$id"; then name=$(<"$(ssl_cf_account_dir "$id")/name"); fi
                echo "${indent}验证方式：Cloudflare DNS-01（账号 $id：$name）"
            fi
            ;;
        http)
            echo "${indent}验证方式：HTTP-01"
            echo "${indent}网络模式：$(ssl_load_network_mode "$domain")"
            ;;
        *)
            echo "${indent}验证方式：配置无效"
            ;;
    esac
    return 0
}

# ── Remove certificate ─────────────────────────────────────────────
ssl_remove_cert() {
    local domain="$1"
    local confirmed="${2:-}"
    local cert_dir="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")"
    local acme_bin="${SSL_ACME_BIN:-${SSL_ACME_HOME}/acme.sh}"

    if ! ssl_validate_dns_domain "$domain"; then
        return 1
    fi

    if [[ ! -d "$cert_dir" ]]; then
        ssl_log ERROR "未找到域名证书：$domain"
        return 1
    fi

    if [[ "$confirmed" != "yes" ]]; then
        ssl_log INFO "已取消删除证书：$domain"
        return 1
    fi

    local method id
    method=$(ssl_validation_method "$domain") || return 1
    # A failed acme.sh removal must not strand the deployed certificate files:
    # warn, keep the local cleanup moving, and let the admin retry --remove.
    if [[ "$method" == dns ]]; then
        id=$(ssl_cf_account_for_domain "$domain") || return 1
        if [[ -z "$id" ]]; then
            ssl_log ERROR "$domain 标记为 DNS-01 证书，但没有可用账号绑定；请先用 w ssl cf-rebind 指定账号。"
            return 1
        fi
        ssl_dns_acme_call "$id" --remove -d "$domain" || \
            ssl_log WARN "未能清除账号 $id 下 $domain 的 acme.sh 证书记录，将继续删除本地证书文件。"
    elif [[ -x "$acme_bin" ]]; then
        "$acme_bin" --remove -d "$domain" || \
            ssl_log WARN "未能清除 acme.sh 中的证书记录，将继续删除本地证书文件。"
    fi

    rm -rf "$cert_dir"
    ssl_remove_network_mode "$domain"
    ssl_log INFO "已删除 $domain 的本地证书文件。"
    ssl_log INFO "此操作不会向证书颁发机构撤销已签发的证书。"
}
