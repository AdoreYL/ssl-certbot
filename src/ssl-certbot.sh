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
source "${LIB_DIR}/cloudflare.sh"
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
    echo "  9. Cloudflare 账号管理"
    echo "  0. 退出"
    echo ""
    read -rp "  请选择 [0-9]: " choice

    case "$choice" in
        1)
            echo ""
            echo "${C_BOLD}重要提示：${C_RESET}"
            echo "  - HTTP-01 需要域名 DNS 记录与所选网络模式的本机地址匹配，且公网 TCP 80 可访问"
            echo "  - Cloudflare DNS-01 不需要开放 80 端口，也不暂停任何服务，可用于未备案主机和通配符域名"
            echo "  - IPv4 校验 A 记录，IPv6 校验 AAAA 记录，双栈模式两者都校验"
            echo "  - 通配符证书（*.example.com）只能使用 Cloudflare DNS-01"
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
        9) ssl_cf_menu ;;
        0) exit 0 ;;
        *) ssl_log ERROR "无效的选项。" ;;
    esac
}

# ── Cloudflare account management ───────────────────────────────────
# The Token is never accepted as a command-line argument: argv is visible to
# every process on the host and is copied into shell history.
ssl_cf_read_token() {
    local prompt="${1:-请输入 Cloudflare API Token：}" token
    if [[ ! -t 0 ]]; then
        ssl_log ERROR "请在交互式终端输入 Token，本工具不接受命令行参数中的 Token。"
        return 1
    fi
    read -rs -rp "  ${prompt}" token
    echo "" >&2
    if [[ -z "$token" ]]; then
        ssl_log ERROR "Token 不能为空。"
        return 1
    fi
    if ! ssl_cf_valid_token "$token"; then
        ssl_log ERROR "Token 格式无效：只允许字母、数字与 . _ - ~ / + 等非空白字符，长度不超过 2048。"
        return 1
    fi
    printf '%s\n' "$token"
}

ssl_cf_cmd_add() {
    local name="${1:-}" token
    if [[ -z "$name" ]]; then
        read -rp "  请输入账号名称（仅用于本机辨识）：" name
    fi
    if ! ssl_cf_valid_name "$name"; then
        ssl_log ERROR "账号名称无效：不能包含换行、制表符、斜杠，且长度不超过 64 个字符。"
        return 1
    fi
    token=$(ssl_cf_read_token) || return 1
    if ssl_cf_add_account "$name" "$token"; then
        echo "  ${C_YELLOW}提示：${C_RESET} Token 仅保存在本机受限文件中（权限 600），不会写入日志或命令历史。"
        return 0
    fi
    return 1
}

ssl_cf_cmd_list() {
    echo ""
    echo "${C_BOLD}Cloudflare 账号${C_RESET}"
    echo "────────────────────────────────────────"
    local accounts
    accounts=$(ssl_cf_list_accounts) || { ssl_log ERROR "账号目录权限不安全，请检查 $SSL_CERTBOT_CONFIG_DIR。"; return 1; }
    if [[ -z "$accounts" ]]; then
        echo "  尚未保存任何账号。"
        echo "  添加账号：w ssl cf-add <名称>"
        echo ""
        return 0
    fi
    local id name bound domains
    while IFS=$'\t' read -r id name; do
        [[ -z "$id" ]] && continue
        bound=$(ssl_cf_bound_domains_for_account "$id") || return 1
        domains="${bound:-无}"
        echo "  编号 $id：$name（绑定域名：$domains）"
    done <<< "$accounts"
    echo ""
}

ssl_cf_cmd_test() {
    local id="${1:-}" domain="${2:-}"
    if [[ -z "$id" ]]; then
        read -rp "  请输入要测试的账号编号：" id
    fi
    if ssl_cf_test_account "$id" "$domain"; then
        if [[ -n "$domain" ]]; then
            ssl_log INFO "账号 $id 可用于 $domain 的 DNS-01 验证。"
        else
            ssl_log INFO "账号 $id 的 Token 有效。"
        fi
        return 0
    fi
    return 1
}

ssl_cf_cmd_update() {
    local id="${1:-}" token
    if [[ -z "$id" ]]; then
        read -rp "  请输入要更换 Token 的账号编号：" id
    fi
    ssl_cf_account_ready "$id" || { ssl_log ERROR "Cloudflare 账号 $id 不存在或权限不安全。"; return 1; }
    token=$(ssl_cf_read_token "请输入账号 $id 的新 Token：") || return 1
    if ssl_cf_update_account "$id" "$token"; then
        ssl_log INFO "账号 $id 的 Token 已更新，旧的持久化凭据会被清除。"
        return 0
    fi
    return 1
}

ssl_cf_cmd_remove() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        read -rp "  请输入要删除的账号编号：" id
    fi
    ssl_cf_account_ready "$id" || { ssl_log ERROR "Cloudflare 账号 $id 不存在或权限不安全。"; return 1; }
    read -rp "  删除账号 $id 会同时删除其本机 Token，输入 yes 确认：" confirm
    if [[ "$confirm" != "yes" ]]; then
        ssl_log INFO "已取消删除账号 $id。"
        return 1
    fi
    if ssl_cf_remove_account "$id"; then
        ssl_log INFO "已删除 Cloudflare 账号 $id。该编号不会被复用。"
        return 0
    fi
    return 1
}

ssl_cf_cmd_rebind() {
    local domain="${1:-}" id="${2:-}"
    ssl_acquire_lock || return 1
    if [[ -z "$domain" ]]; then
        read -rp "  请输入要改绑的域名（可为 *.example.com）：" domain
    fi
    if [[ -z "$id" ]]; then
        ssl_cf_list_accounts
        read -rp "  请输入新的 Cloudflare 账号编号：" id
    fi
    if ssl_cf_rebind_domain "$domain" "$id"; then
        ssl_log INFO "$domain 已改绑到账号 $id。"
        return 0
    fi
    ssl_log ERROR "改绑失败：$domain 保持原绑定不变。请确认该域名已使用 DNS-01、目标账号存在且拥有该域名所属 Zone。"
    return 1
}

ssl_cf_menu() {
    while true; do
        echo ""
        echo "${C_BOLD}${C_CYAN}Cloudflare 账号管理${C_RESET}"
        echo "────────────────────────────────────────"
        echo ""
        echo "  1. 添加账号"
        echo "  2. 查看账号列表"
        echo "  3. 测试账号权限"
        echo "  4. 更换 Token"
        echo "  5. 删除账号"
        echo "  6. 改绑域名到指定账号"
        echo "  0. 返回上级菜单"
        echo ""
        read -rp "  请选择 [0-6]: " choice
        case "$choice" in
            1) ssl_cf_cmd_add ;;
            2) ssl_cf_cmd_list ;;
            3) ssl_cf_cmd_test ;;
            4) ssl_cf_cmd_update ;;
            5) ssl_cf_cmd_remove ;;
            6) ssl_cf_cmd_rebind ;;
            0) return 0 ;;
            *) ssl_log ERROR "无效的选项。" ;;
        esac
    done
}

# ── Command: remove ────────────────────────────────────────────────
ssl_cmd_remove() {
    local domain="${1:-}"
    local confirm

    if [[ -z "$domain" ]]; then
        read -rp "  请输入要删除证书的域名：" domain
    fi
    if ! ssl_validate_dns_domain "$domain"; then
        return 1
    fi

    echo ""
    echo "${C_YELLOW}${C_BOLD}警告：${C_RESET} 将删除以下本地证书文件："
    echo "  ${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")/"
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
    local requested_mode="${2:-}"
    local account_id="${3:-}" mode method existing bound

    # Validate domain
    if ! ssl_validate_dns_domain "$domain"; then
        return 1
    fi

    ssl_log INFO "开始处理证书：$domain"
    ssl_log INFO "系统：$SSL_OS $SSL_OS_VER，初始化系统：$SSL_INIT"

    existing=$(ssl_validation_method "$domain") || return 1
    if [[ -z "$requested_mode" && "$existing" == dns ]]; then
        requested_mode=dns
        account_id=$(ssl_cf_account_for_domain "$domain") || return 1
    fi
    if [[ -z "$requested_mode" && -t 0 && "$existing" != dns ]]; then
        read -rp "  验证方式 [1 HTTP-01 / 2 Cloudflare DNS-01，默认 1]：" method
        [[ "$method" == 2 ]] && requested_mode=dns
    fi
    if [[ "$existing" == dns && "$requested_mode" != dns ]]; then
        ssl_log ERROR '已有 DNS 证书，不能静默切换验证方式。'
        return 1
    fi
    if [[ "$requested_mode" == dns ]]; then
        [[ "$existing" != http || ! -f "$(ssl_network_mode_file "$domain")" ]] || { ssl_log ERROR '已有 HTTP 证书，不允许静默切换方式。'; return 1; }
        if [[ -z "$account_id" && -t 0 ]]; then
            ssl_cf_list_accounts
            read -rp '  请输入 Cloudflare 账号编号：' account_id
        fi
        ssl_cf_account_ready "$account_id" || { ssl_log ERROR '请选择有效的 Cloudflare 账号编号。'; return 1; }
        bound=$(ssl_cf_account_for_domain "$domain") || return 1
        [[ -z "$bound" || "$bound" == "$account_id" ]] || { ssl_log ERROR '账号已绑定，需使用显式改绑命令。'; return 1; }
        # DNS-01 needs the official acme.sh installation (and its dnsapi
        # plugins), but it must never touch the A/AAAA preflight or the
        # 80/443 listeners.
        ssl_ensure_acme
        ssl_acquire_lock
        ssl_issue_dns_cert "$domain" "$account_id" || return 1

        local dns_cron_result=0
        ssl_install_cron_job || dns_cron_result=$?
        local dns_dir="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")"
        echo ""
        if [[ "$dns_cron_result" -ne 0 ]]; then
            echo "${C_YELLOW}${C_BOLD}证书已签发，但自动续期配置失败。${C_RESET}"
        else
            echo "${C_GREEN}${C_BOLD}证书申请成功！${C_RESET}"
        fi
        echo "────────────────────────────────────────"
        echo "  域名：$domain"
        echo "  验证方式：Cloudflare DNS-01（账号 $account_id）"
        echo "  证书链：${dns_dir}/fullchain.pem"
        echo "  私钥：${dns_dir}/privkey.pem"
        echo ""
        echo "  ${C_YELLOW}提示：${C_RESET} 本次流程没有暂停或恢复任何端口服务。"
        echo "  工具不会自动重载或重启服务，请自行配置服务使用上述路径并完成重载。"
        if [[ "$domain" == \*.* ]]; then
            echo "  通配符证书只覆盖同层子域名，例如 a.example.com；不包含 example.com 与 a.b.example.com。"
        fi
        if [[ "$dns_cron_result" -ne 0 ]]; then
            echo ""
            echo "  ${C_RED}警告：${C_RESET} 无法配置自动续期。"
            echo "  请在证书到期前手动执行 'w ssl renew $domain'，或检查 cron 状态后重新配置。"
        fi
        echo ""
        if [[ "$dns_cron_result" -ne 0 ]]; then
            ssl_log WARN "$domain 的证书已签发，但 cron 配置失败。"
            return 1
        fi
        ssl_log INFO "$domain 的 DNS-01 证书流程已完成；没有暂停端口服务。"
        return 0
    fi
    [[ "$domain" != \*.* && "$existing" == http ]] || { ssl_log ERROR '通配符只能使用 DNS-01；已有 DNS 证书不能切回 HTTP。'; return 1; }
    mode=$(ssl_select_network_mode "$requested_mode") || return 1
    ssl_log INFO "验证网络模式：$mode"

    # Ensure acme.sh is available
    ssl_ensure_acme

    # Acquire lock
    ssl_acquire_lock

    # DNS preflight must finish before any service can be paused.
    if ! ssl_check_dns "$domain" "$mode"; then
        ssl_log ERROR "无法继续：DNS 预检未通过。"
        return 1
    fi

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
    ssl_issue_cert "$domain" "$mode" || issue_result=$?

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
    local cert_dir="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")"
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
    if ! ssl_validate_dns_domain "$domain"; then
        return 1
    fi

    ssl_acquire_lock

    local fullchain="${SSL_CERT_BASE}/$(ssl_cert_slug "$domain")/fullchain.pem"
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

    local method id
    method=$(ssl_validation_method "$domain") || return 1
    if [[ "$method" == dns ]]; then
        id=$(ssl_cf_account_for_domain "$domain") || return 1
        if [[ -z "$id" ]]; then
            ssl_log ERROR "$domain 没有可用的 Cloudflare 账号绑定，请先执行 w ssl cf-rebind $domain <编号>。"
            return 1
        fi
        if ! ssl_renew_dns_cert "$domain" "$id"; then
            ssl_log ERROR "$domain 的 DNS-01 续期失败。"
            return 1
        fi
        echo ""
        echo "${C_GREEN}$domain 的证书已续期${C_RESET}"
        echo "  验证方式：Cloudflare DNS-01（账号 $id）。"
        echo "  本次流程没有暂停或恢复任何端口服务。"
        echo "  服务不会自动重载，请自行重载以使用新证书。"
        echo ""
        return 0
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
    echo "    w ssl <域名> [ipv4|ipv6|dual] 申请或续期证书（HTTP-01）"
    echo "    w ssl <域名> dns <编号>      使用 Cloudflare DNS-01 申请或续期"
    echo "    w ssl list               列出已管理的证书"
    echo "    w ssl status [域名]      查看证书状态"
    echo "    w ssl renew [域名]       手动续期证书"
    echo "    w ssl remove <域名>      删除本地证书与 acme.sh 记录"
    echo "    w ssl cf-menu            打开 Cloudflare 账号管理菜单"
    echo "    w ssl cf-add <名称>       添加 Cloudflare 账号（Token 隐藏输入）"
    echo "    w ssl cf-list              查看 Cloudflare 账号编号与名称"
    echo "    w ssl cf-test <编号> [域名] 测试 Token 与 Zone 权限"
    echo "    w ssl cf-update <编号>     更换账号 Token"
    echo "    w ssl cf-remove <编号>     删除未绑定域名的账号"
    echo "    w ssl cf-rebind <域名> <编号> 显式更换绑定账号"
    echo "    w ssl update              更新 ssl-certbot 脚本"
    echo "    w ssl uninstall          卸载 ssl-certbot（保留证书与 acme.sh）"
    echo "    w ssl logs               查看最近日志"
    echo "    w ssl help               查看帮助"
    echo ""
    echo "  ${C_BOLD}工作方式：${C_RESET}"
    echo "    1. IPv4 校验 A 记录，IPv6 校验 AAAA 记录，双栈模式两者都校验"
    echo "    1b. Cloudflare DNS-01 只需 Zone 权限：无需开放 80 端口，不暂停服务，支持通配符"
    echo "    2. TCP 80 必须可访问，用于 HTTP-01 验证"
    echo "    3. 仅暂停可确认管理方式且实际占用 80/443 的服务"
    echo "    4. 完成后恢复本次暂停的服务"
    echo "    5. 通过 cron 自动续期"
    echo ""
    echo "  ${C_BOLD}证书路径：${C_RESET}"
    echo "    /etc/letsencrypt/live/<domain>/fullchain.pem"
    echo "    /etc/letsencrypt/live/<domain>/privkey.pem"
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
    echo "    - Cloudflare Token 只保存在本机受限文件中，为明文存储（权限 600，仅 root 可读）"
    echo "    - 通配符证书只覆盖同层子域名，根域名需要单独申请"
    echo "    - 不需要 Docker、Certbot 或大型运行时"
    echo "    - 基于 acme.sh 与 Let's Encrypt"
    echo ""
}

# ── DNS and network-mode selection ─────────────────────────────────
ssl_select_network_mode() {
    local mode="${1:-}"

    if [[ -n "$mode" ]]; then
        ssl_validate_network_mode "$mode" || return 1
        printf '%s\n' "$mode"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        ssl_log INFO "非交互式执行未指定网络模式，将使用双栈模式。"
        printf '%s\n' dual
        return 0
    fi

    # This function returns the selected mode through stdout for command
    # substitution, so interactive text must use stderr.
    echo "" >&2
    echo "  请选择证书验证网络模式：" >&2
    echo "  1. IPv4（仅要求 A 记录与本机 IPv4 匹配）" >&2
    echo "  2. IPv6（仅要求 AAAA 记录与本机 IPv6 匹配）" >&2
    echo "  3. 双栈（要求 A 与 AAAA 记录都与本机匹配）" >&2
    read -rp "  请选择 [1-3，默认 3]：" mode
    case "${mode:-3}" in
        1|ipv4) printf '%s\n' ipv4 ;;
        2|ipv6) printf '%s\n' ipv6 ;;
        3|dual) printf '%s\n' dual ;;
        *)
            ssl_log ERROR "无效的网络模式选项。"
            return 1
            ;;
    esac
}

ssl_resolve_dns_records() {
    local domain="$1"
    local record_type="$2"

    if command -v dig >/dev/null 2>&1; then
        dig +short "$record_type" "$domain" 2>/dev/null | sed '/^$/d'
    elif command -v host >/dev/null 2>&1; then
        case "$record_type" in
            A) host -t A "$domain" 2>/dev/null | awk '/has address/ { print $4 }' ;;
            AAAA) host -t AAAA "$domain" 2>/dev/null | awk '/has IPv6 address/ { print $5 }' ;;
        esac
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup -type="$record_type" "$domain" 2>/dev/null | awk -v type="$record_type" '
            type == "A" && /^Address: / && $2 ~ /^[0-9.]+$/ { print $2 }
            type == "AAAA" && /^Address: / && $2 ~ /:/ { print $2 }
        '
    elif [[ "$record_type" == "A" ]]; then
        getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u
    else
        getent ahostsv6 "$domain" 2>/dev/null | awk '{ print $1 }' | sort -u
    fi
}

ssl_local_ip_addresses() {
    local family="$1"

    if command -v ip >/dev/null 2>&1; then
        case "$family" in
            ipv4) ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' ;;
            ipv6) ip -o -6 addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); if (tolower(a[1]) !~ /^(fc|fd)/) print a[1] }' ;;
        esac
    elif command -v ifconfig >/dev/null 2>&1; then
        case "$family" in
            ipv4) ifconfig 2>/dev/null | awk '/inet (addr:)?/ { sub("addr:", "", $2); if ($2 !~ /^127\./) print $2 }' ;;
            ipv6) ifconfig 2>/dev/null | awk '/inet6/ { value=$3; sub("addr:", "", value); sub("%.*", "", value); if (tolower(value) !~ /^(fe80:|fc|fd)/) print value }' ;;
        esac
    fi
}

ssl_public_ipv4_address() {
    local endpoint address

    # A cloud instance can have only a private NIC address while its public
    # IPv4 is provided through 1:1 NAT. Query IPv4-only endpoints as a
    # fallback for that case. IPv6 validation never calls this function.
    for endpoint in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.me/ip"; do
        address="$(curl -4 --connect-timeout 3 --max-time 8 -fsSL "$endpoint" 2>/dev/null || true)"
        address="${address//$'\r'/}"
        address="${address//$'\n'/}"
        if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "$address"
            return 0
        fi
    done

    return 1
}

ssl_public_ipv6_address() {
    local endpoint address normalized

    # A provider can publish an IPv6 address through a translation or tunnel
    # while the guest only sees a non-public address. Never use IPv4 here: an
    # IPv6 validation must be tied to the IPv6 path that Let's Encrypt uses.
    for endpoint in \
        "https://api64.ipify.org" \
        "https://ipv6.icanhazip.com" \
        "https://ifconfig.co/ip"; do
        address="$(curl -6 --connect-timeout 3 --max-time 8 -fsSL "$endpoint" 2>/dev/null || true)"
        address="${address//$'\r'/}"
        address="${address//$'\n'/}"
        normalized="${address,,}"
        if [[ "$address" == *:* && "$normalized" != ::1 && "$normalized" != :: && "$normalized" != fe80:* && "$normalized" != fc* && "$normalized" != fd* ]]; then
            printf '%s\n' "$address"
            return 0
        fi
    done

    return 1
}

ssl_dns_records_match_local_addresses() {
    local record_type="$1"
    local family="$2"
    local records local_addresses record

    records=$(ssl_resolve_dns_records "$3" "$record_type")
    local_addresses=$(ssl_local_ip_addresses "$family")
    if [[ -z "$records" ]]; then
        ssl_log ERROR "域名 $3 未找到 $record_type 记录。"
        return 1
    fi
    if [[ -z "$local_addresses" ]]; then
        ssl_log WARN "本机未找到可用的 $family 全局地址，将尝试查询公网出口地址。"
    else
        ssl_log INFO "本机可用 $family 地址：$(printf '%s' "$local_addresses" | paste -sd ',' -)"
    fi

    ssl_log INFO "域名 $3 的 $record_type 记录：$(printf '%s' "$records" | paste -sd ',' -)"
    while read -r record; do
        [[ -z "$record" ]] && continue
        if grep -Fxq "$record" <<< "$local_addresses"; then
            ssl_log INFO "已确认 $record_type 记录与本机 $family 地址匹配：$record"
            return 0
        fi
    done <<< "$records"

    if [[ "$family" == "ipv4" ]]; then
        local public_ipv4
        public_ipv4="$(ssl_public_ipv4_address || true)"
        if [[ -n "$public_ipv4" ]]; then
            ssl_log INFO "本机 IPv4 公网出口地址：$public_ipv4"
            while read -r record; do
                [[ -z "$record" ]] && continue
                if [[ "$record" == "$public_ipv4" ]]; then
                    ssl_log INFO "已确认 $record_type 记录与本机 IPv4 公网出口地址匹配：$record"
                    return 0
                fi
            done <<< "$records"
        else
            ssl_log WARN "未能查询本机 IPv4 公网出口地址。"
        fi
    elif [[ "$family" == "ipv6" ]]; then
        local public_ipv6
        public_ipv6="$(ssl_public_ipv6_address || true)"
        if [[ -n "$public_ipv6" ]]; then
            ssl_log INFO "本机 IPv6 公网出口地址：$public_ipv6"
            while read -r record; do
                [[ -z "$record" ]] && continue
                if [[ "${record,,}" == "${public_ipv6,,}" ]]; then
                    ssl_log INFO "已确认 $record_type 记录与本机 IPv6 公网出口地址匹配：$record"
                    return 0
                fi
            done <<< "$records"
        else
            ssl_log WARN "未能查询本机 IPv6 公网出口地址。"
        fi
    fi

    ssl_log ERROR "域名 $3 的 $record_type 记录与本机 $family 地址不匹配。"
    return 1
}

ssl_check_dns() {
    local domain="$1"
    local mode="$2"

    ssl_log INFO "正在检查 $domain 的 DNS 解析..."
    ssl_validate_network_mode "$mode" || return 1

    case "$mode" in
        ipv4) ssl_dns_records_match_local_addresses A ipv4 "$domain" ;;
        ipv6) ssl_dns_records_match_local_addresses AAAA ipv6 "$domain" ;;
        dual)
            ssl_dns_records_match_local_addresses A ipv4 "$domain" && \
                ssl_dns_records_match_local_addresses AAAA ipv6 "$domain"
            ;;
    esac
}

# ── Main dispatch ───────────────────────────────────────────────────
main() {
    ssl_require_root
    ssl_init_log
    ssl_detect_os
    ssl_ensure_deps
    ssl_migrate_legacy_certificates

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
        cloudflare|cf-menu)
            ssl_cf_menu
            ;;
        cf-add)
            ssl_cf_cmd_add "${2:-}"
            ;;
        cf-list)
            ssl_cf_cmd_list
            ;;
        cf-test)
            ssl_cf_cmd_test "${2:-}" "${3:-}"
            ;;
        cf-update)
            ssl_cf_cmd_update "${2:-}"
            ;;
        cf-remove)
            ssl_cf_cmd_remove "${2:-}"
            ;;
        cf-rebind)
            ssl_cf_cmd_rebind "${2:-}" "${3:-}"
            ;;
        help|--help|-h)
            ssl_cmd_help
            ;;
        *)
            # Treat as domain name
            ssl_cmd_apply "$subcmd" "${2:-}" "${3:-}"
            ;;
    esac
}

if [[ "${SSL_CERTBOT_NO_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
