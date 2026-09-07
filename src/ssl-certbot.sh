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
    ssl_log INFO "正在清理（退出码：$exit_code）..."
    ssl_restore_services
    ssl_release_lock
    if [[ "$exit_code" -ne 0 ]]; then
        ssl_log WARN "流程异常退出，已尝试恢复本次暂停的服务。"
    fi
}
trap _ssl_cleanup EXIT INT TERM HUP

# ── Interactive menu ────────────────────────────────────────────────
ssl_interactive_menu() {
    echo ""
    echo "${C_BOLD}${C_CYAN}SSL 证书管理${C_RESET}"
    echo "────────────────────────────────────────"
    echo ""
    echo "  1. 申请或续期证书"
    echo "  2. 查看证书列表"
    echo "  3. 查看证书状态"
    echo "  4. 查看运行日志"
    echo "  5. 查看帮助"
    echo "  6. 删除证书"
    echo "  7. 更新脚本"
    echo "  8. 卸载 ssl-certbot"
    echo "  0. 退出"
    echo ""
    read -rp "  请选择 [0-8]: " choice

    case "$choice" in
        1)
            echo ""
            echo "${C_BOLD}重要提示：${C_RESET}"
            echo "  - 域名必须已解析到本机公网 IP"
            echo "  - 公网 TCP 80 必须可访问"
            echo "  - 工具只会暂停实际占用 80 或 443 端口、且能够确认管理方式的服务"
            echo "  - 无法确认来源的进程不会被强制停止"
            echo "  - 证书申请完成后，工具会恢复本次暂停的服务"
            echo "  - 工具只申请、续期和保存证书，不自动重载 Nginx、Caddy、x-ui 或 3x-ui"
            echo ""
            read -rp "  请输入域名（例如 example.com）：" domain
            if [[ -z "$domain" ]]; then
                ssl_log ERROR "未输入域名。"
                return 1
            fi
            ssl_cmd_apply "$domain"
            ;;
        2) ssl_list_certs ;;
        3) ssl_cert_status ;;
        4) ssl_cmd_logs ;;
        5) ssl_cmd_help ;;
        6) ssl_cmd_remove ;;
        7) ssl_cmd_update ;;
        8) ssl_cmd_uninstall ;;
        0) exit 0 ;;
        *) ssl_log ERROR "无效的选项。" ;;
    esac
}

# ── Command: remove ────────────────────────────────────────────────
ssl_cmd_remove() {
    local domain="${1:-}"
    local confirm

    if [[ -z "$domain" ]]; then
        read -rp "  请输入要删除证书的域名：" domain
    fi
    if ! ssl_validate_domain "$domain"; then
        return 1
    fi

    echo ""
    echo "${C_YELLOW}${C_BOLD}警告：${C_RESET} 将删除以下本地证书文件："
    echo "  /root/cert/${domain}/"
    echo "  同时清除 acme.sh 的本地证书记录。"
    echo "  此操作不会向证书颁发机构撤销已签发的证书。"
    read -rp "  输入 yes 确认删除：" confirm
    ssl_remove_cert "$domain" "$confirm"
}

# ── Command: uninstall ─────────────────────────────────────────────
ssl_cmd_uninstall() {
    local uninstall_script="${LIB_DIR}/uninstall.sh"

    if [[ ! -x "$uninstall_script" ]]; then
        ssl_log ERROR "未找到已安装的卸载脚本：$uninstall_script"
        return 1
    fi

    exec "$uninstall_script"
}

# ── Command: update ────────────────────────────────────────────────
ssl_cmd_update() {
    local installer_url="https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh"

    echo ""
    echo "${C_BOLD}正在更新 ssl-certbot...${C_RESET}"
    echo "  更新会保留已有证书、acme.sh、日志和自动续期任务。"

    if ! curl -fsSL "$installer_url" | bash; then
        ssl_log ERROR "脚本更新失败。"
        return 1
    fi
}

# ── Command: apply ──────────────────────────────────────────────────
ssl_cmd_apply() {
    local domain="$1"

    # Validate domain
    if ! ssl_validate_domain "$domain"; then
        return 1
    fi

    ssl_log INFO "开始处理证书：$domain"
    ssl_log INFO "系统：$SSL_OS $SSL_OS_VER，初始化系统：$SSL_INIT"

    # Ensure acme.sh is available
    ssl_ensure_acme

    # Acquire lock
    ssl_acquire_lock

    # Check DNS (basic: resolve domain, compare with VPS IP)
    ssl_check_dns "$domain"

    # Pause services on 80/443
    echo ""
    echo "${C_BOLD}正在检查 80 和 443 端口...${C_RESET}"
    if ! ssl_pause_port_services; then
        ssl_log ERROR "无法继续：未能安全释放所需端口。"
        return 1
    fi

    # Issue certificate
    echo ""
    echo "${C_BOLD}正在申请证书...${C_RESET}"
    local issue_result=0
    ssl_issue_cert "$domain" || issue_result=$?

    # Restore services (always, regardless of result)
    echo ""
    echo "${C_BOLD}正在恢复服务...${C_RESET}"
    local restore_result=0
    ssl_restore_services || restore_result=$?

    if [[ "$issue_result" -ne 0 ]]; then
        ssl_log ERROR "$domain 的证书申请失败。"
        ssl_log ERROR "已尝试恢复本次暂停的服务。"
        return 1
    fi

    if [[ "$restore_result" -ne 0 ]]; then
        ssl_log ERROR "证书已签发，但一个或多个服务未能恢复。"
        return 1
    fi

    # Set up auto-renewal
    echo ""
    echo "${C_BOLD}正在配置自动续期...${C_RESET}"
    local cron_result=0
    ssl_install_cron_job || cron_result=$?

    # Final summary
    local cert_dir="${SSL_CERT_BASE}/${domain}"
    echo ""
    if [[ "$cron_result" -ne 0 ]]; then
        echo "${C_YELLOW}${C_BOLD}证书已签发，但自动续期配置失败。${C_RESET}"
    else
        echo "${C_GREEN}${C_BOLD}证书申请成功！${C_RESET}"
    fi
    echo "────────────────────────────────────────"
    echo "  域名：$domain"
    echo "  证书链：${cert_dir}/fullchain.pem"
    echo "  私钥：${cert_dir}/privkey.pem"
    echo ""
    echo "  ${C_YELLOW}提示：${C_RESET} 已恢复本次暂停的服务。"
    echo "  工具不会自动重载或重启服务，请自行配置服务使用上述路径并完成重载。"
    if [[ "$cron_result" -ne 0 ]]; then
        echo ""
        echo "  ${C_RED}警告：${C_RESET} 无法配置自动续期。"
        echo "  请在证书到期前手动执行 '${0##*/} ssl renew'，"
        echo "  或检查 cron 状态后重新配置。"
    fi
    echo ""

    if [[ "$cron_result" -ne 0 ]]; then
        ssl_log WARN "$domain 的证书已签发，但 cron 配置失败。"
        return 1
    fi
    ssl_log INFO "$domain 的证书流程已完成。"
}

# ── Command: renew ──────────────────────────────────────────────────
ssl_cmd_renew() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        ssl_log INFO "正在续期全部证书..."
        ssl_acquire_lock
        if ssl_renew_managed_certificates; then
            return 0
        fi
        return 1
    fi

    # Renew specific domain
    if ! ssl_validate_domain "$domain"; then
        return 1
    fi

    ssl_acquire_lock

    local fullchain="${SSL_CERT_BASE}/${domain}/fullchain.pem"
    if [[ ! -f "$fullchain" ]]; then
        ssl_log ERROR "未找到域名证书：$domain"
        return 1
    fi

    local renewal_state=0
    if ssl_cert_needs_renewal_file "$fullchain"; then
        renewal_state=0
    else
        renewal_state=$?
    fi

    if [[ "$renewal_state" -eq 1 ]]; then
        ssl_log INFO "$domain：有效期超过 30 天，跳过续期。"
        return 0
    elif [[ "$renewal_state" -ne 0 ]]; then
        ssl_log ERROR "$domain：无法确定证书到期时间，已跳过续期。"
        return 1
    fi

    if ! ssl_pause_port_services; then
        ssl_log ERROR "无法安全释放续期所需端口。"
        return 1
    fi

    local renew_result=0
    ssl_renew_cert "$domain" || renew_result=$?

    local restore_result=0
    ssl_restore_services || restore_result=$?

    if [[ "$renew_result" -ne 0 ]]; then
        ssl_log ERROR "$domain 续期失败，已尝试恢复服务。"
        return 1
    fi

    if [[ "$restore_result" -ne 0 ]]; then
        ssl_log ERROR "证书已续期，但一个或多个服务未能恢复。"
        return 1
    fi

    echo ""
    echo "${C_GREEN}$domain 的证书已续期${C_RESET}"
    echo "  已恢复本次暂停的服务。"
    echo "  服务不会自动重载，请自行重载以使用新证书。"
    echo ""
}

# ── Command: logs ───────────────────────────────────────────────────
ssl_cmd_logs() {
    local log_file="$SSL_LOG_PRIMARY"
    if [[ ! -f "$log_file" ]]; then
        log_file="$SSL_LOG_FALLBACK"
    fi
    if [[ ! -f "$log_file" ]]; then
        echo "未找到日志文件。"
        return 0
    fi
    echo ""
    echo "${C_BOLD}最近日志${C_RESET} ($log_file)"
    echo "────────────────────────────────────────"
    tail -n 50 "$log_file"
    echo ""
}

# ── Command: help ───────────────────────────────────────────────────
ssl_cmd_help() {
    echo ""
    echo "${C_BOLD}${C_CYAN}SSL 证书管理 - 帮助${C_RESET}"
    echo "────────────────────────────────────────"
    echo ""
    echo "  ${C_BOLD}用法：${C_RESET}"
    echo "    w ssl                    打开交互式菜单"
    echo "    w ssl <域名>             申请或续期证书"
    echo "    w ssl list               列出已管理的证书"
    echo "    w ssl status [域名]      查看证书状态"
    echo "    w ssl renew [域名]       手动续期证书"
    echo "    w ssl remove <域名>      删除本地证书与 acme.sh 记录"
    echo "    w ssl update              更新 ssl-certbot 脚本"
    echo "    w ssl uninstall          卸载 ssl-certbot（保留证书与 acme.sh）"
    echo "    w ssl logs               查看最近日志"
    echo "    w ssl help               查看帮助"
    echo ""
    echo "  ${C_BOLD}工作方式：${C_RESET}"
    echo "    1. 域名必须解析到本机公网 IP"
    echo "    2. TCP 80 必须可访问，用于 HTTP-01 验证"
    echo "    3. 仅暂停可确认管理方式且实际占用 80/443 的服务"
    echo "    4. 完成后恢复本次暂停的服务"
    echo "    5. 通过 cron 自动续期"
    echo ""
    echo "  ${C_BOLD}证书路径：${C_RESET}"
    echo "    /root/cert/<domain>/fullchain.pem"
    echo "    /root/cert/<domain>/privkey.pem"
    echo ""
    echo "  ${C_BOLD}支持系统：${C_RESET}"
    echo "    Debian 11/12/13, Ubuntu 20.04/22.04/24.04, Alpine 3.x"
    echo ""
    echo "  ${C_BOLD}说明：${C_RESET}"
    echo "    - HTTP-01 验证必须使用 TCP 80"
    echo "    - TCP 443 属于暂停/恢复范围，但验证本身不需要它"
    echo "    - 无法确认来源的进程不会被强制停止"
    echo "    - 证书变更后不会自动重载服务"
    echo "    - 删除证书不会向证书颁发机构撤销已签发的证书"
    echo "    - 不需要 Docker、Certbot 或大型运行时"
    echo "    - 基于 acme.sh 与 Let's Encrypt"
    echo ""
}

# ── DNS check (basic) ──────────────────────────────────────────────
ssl_check_dns() {
    local domain="$1"

    ssl_log INFO "正在检查 $domain 的 DNS 解析..."

    # Get VPS public IP
    local vps_ip=""
    vps_ip=$(curl -s -4 --max-time 10 https://ifconfig.me 2>/dev/null || \
             curl -s -4 --max-time 10 https://api.ipify.org 2>/dev/null || \
             curl -s -4 --max-time 10 https://icanhazip.com 2>/dev/null || \
             echo "")

    if [[ -z "$vps_ip" ]]; then
        ssl_log WARN "无法确定 VPS 公网 IP，将继续执行。"
        return 0
    fi

    ssl_log INFO "VPS 公网 IP：$vps_ip"

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
        ssl_log ERROR "无法解析域名：$domain"
        ssl_log ERROR "请确认 DNS 已配置并完成传播。"
        return 1
    fi

    ssl_log INFO "域名 $domain 解析到：$domain_ip"

    if [[ "$domain_ip" != "$vps_ip" ]]; then
        ssl_log WARN "域名 IP（$domain_ip）与 VPS IP（$vps_ip）不一致。"
        ssl_log WARN "若 VPS 使用其他公网 IP 或 IPv6，这可能符合预期。"
        echo ""
        read -rp "  仍要继续吗？[y/N]：" confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            ssl_log INFO "用户已取消。"
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
        remove|delete|rm)
            ssl_cmd_remove "${2:-}"
            ;;
        uninstall)
            ssl_cmd_uninstall
            ;;
        update)
            ssl_cmd_update
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
