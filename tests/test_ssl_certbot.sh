#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

pass_count=0
fail_count=0

pass() {
    printf 'PASS: %s\n' "$1"
    pass_count=$((pass_count + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    fail_count=$((fail_count + 1))
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message"
    fi
}

test_network_mode_persistence_and_legacy_certificate_migration() {
    local case_dir="$TEST_TMP/network-state"
    local cert_base="$case_dir/etc/letsencrypt/live"
    local legacy_base="$case_dir/root/cert"
    local config_dir="$case_dir/etc/letsencrypt/ssl-certbot"
    local domain="ipv6.example.com"

    mkdir -p "$legacy_base/$domain"
    printf '%s\n' legacy-fullchain > "$legacy_base/$domain/fullchain.pem"
    printf '%s\n' legacy-privkey > "$legacy_base/$domain/privkey.pem"

    if (
        SSL_CERT_BASE="$cert_base"
        SSL_LEGACY_CERT_BASE="$legacy_base"
        SSL_CERTBOT_CONFIG_DIR="$config_dir"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        ssl_save_network_mode "$domain" ipv6
        [[ "$(ssl_load_network_mode "$domain")" == "ipv6" ]]
        ssl_migrate_legacy_certificates
    ); then
        if [[ -f "$cert_base/$domain/fullchain.pem" ]] && \
           [[ -f "$cert_base/$domain/privkey.pem" ]] && \
           [[ ! -d "$legacy_base/$domain" ]]; then
            pass "保存网络模式并迁移旧证书到 letsencrypt live 目录"
        else
            fail "保存网络模式并迁移旧证书到 letsencrypt live 目录"
        fi
    else
        fail "保存网络模式并迁移旧证书到 letsencrypt live 目录"
    fi
}

test_network_mode_rejects_invalid_values() {
    if (
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        ssl_validate_network_mode invalid
    ); then
        fail "网络模式拒绝无效值"
    else
        pass "网络模式拒绝无效值"
    fi
}

test_interactive_network_mode_menu_writes_to_terminal() {
    local ssl_script selector
    ssl_script=$(<"$PROJECT_ROOT/src/ssl-certbot.sh")
    selector=$(printf '%s\n' "$ssl_script" | awk '
        /^ssl_select_network_mode\(\)/ { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ')

    assert_contains "$selector" 'echo "  1. IPv4（仅要求 A 记录与本机 IPv4 匹配）" >&2' "网络模式菜单的 IPv4 选项显示在终端"
    assert_contains "$selector" 'echo "  2. IPv6（仅要求 AAAA 记录与本机 IPv6 匹配）" >&2' "网络模式菜单的 IPv6 选项显示在终端"
    assert_contains "$selector" 'echo "  3. 双栈（要求 A 与 AAAA 记录都与本机匹配）" >&2' "网络模式菜单的双栈选项显示在终端"
}

test_renewal_retry_schedule_is_documented_and_persistent() {
    local cron_script renew_script common readme
    cron_script=$(<"$PROJECT_ROOT/src/cron.sh")
    renew_script=$(<"$PROJECT_ROOT/src/renew-all.sh")
    common=$(<"$PROJECT_ROOT/src/common.sh")
    readme=$(<"$PROJECT_ROOT/README.md")

    assert_contains "$cron_script" '30 2 * * * ${renew_script} baseline ${SSL_CRON_MARKER}' "自动续期保留每天 02:30 基准任务"
    assert_contains "$cron_script" '30 10 * * * ${renew_script} retry ${SSL_CRON_MARKER}' "自动续期配置 10:30 重试任务"
    assert_contains "$cron_script" '30 18 * * * ${renew_script} retry ${SSL_CRON_MARKER}' "自动续期配置 18:30 重试任务"
    assert_contains "$renew_script" 'readonly RENEW_MAX_RETRIES=6' "自动续期最多重试 6 轮"
    assert_contains "$renew_script" 'renew_save_retry_count "$retry_count"' "自动续期持久化失败重试次数"
    assert_contains "$renew_script" 'renew_clear_retry_state' "自动续期成功或达到上限后清除重试状态"
    assert_contains "$common" 'SSL_RENEW_RETRY_STATE' "重试状态保存到持久化配置目录"
    assert_contains "$readme" '最多连续重试 6 轮' "README 说明 6 轮重试策略"
}

test_ipv6_dns_validation_uses_local_addresses_without_ipv4_egress_lookup() {
    local case_dir="$TEST_TMP/ipv6-dns"
    local calls="$case_dir/calls"
    mkdir -p "$case_dir"

    if (
        SSL_CERTBOT_NO_MAIN=1
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/ssl-certbot.sh"
        ssl_resolve_dns_records() {
            [[ "$2" == "AAAA" ]] && printf '%s\n' '2406:da00:abcd::1'
        }
        ssl_local_ip_addresses() {
            printf '%s\n' '2406:da00:abcd::1'
        }
        curl() { printf '%s\n' "$*" >> "$calls"; return 1; }
        ssl_check_dns ipv6.example.com ipv6
    ); then
        assert_not_contains "$(cat "$calls" 2>/dev/null || true)" "-4" "IPv6 DNS 校验不查询 IPv4 出口地址"
    else
        fail "IPv6 DNS 校验不查询 IPv4 出口地址"
    fi
}

test_ipv4_dns_validation_accepts_public_nat_address() {
    local case_dir="$TEST_TMP/ipv4-nat"
    local calls="$case_dir/calls"
    mkdir -p "$case_dir"

    if (
        SSL_CERTBOT_NO_MAIN=1
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/ssl-certbot.sh"
        ssl_resolve_dns_records() {
            [[ "$2" == "A" ]] && printf '%s\n' '47.243.100.165'
        }
        ssl_local_ip_addresses() {
            [[ "$1" == "ipv4" ]] && printf '%s\n' '172.21.234.168'
        }
        curl() {
            printf '%s\n' "$*" >> "$calls"
            printf '%s\n' '47.243.100.165'
        }
        ssl_check_dns nat.example.com ipv4
    ); then
        assert_contains "$(cat "$calls")" "-4" "IPv4 NAT 校验使用 IPv4 公网出口查询"
    else
        fail "IPv4 NAT 校验接受与公网出口匹配的 A 记录"
    fi
}

test_dual_stack_dns_requires_matching_a_and_aaaa_records() {
    if (
        SSL_CERTBOT_NO_MAIN=1
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/ssl-certbot.sh"
        ssl_resolve_dns_records() {
            [[ "$2" == "A" ]] && printf '%s\n' '198.51.100.20'
        }
        ssl_local_ip_addresses() {
            case "$1" in
                ipv4) printf '%s\n' '198.51.100.20' ;;
                ipv6) printf '%s\n' '2001:db8::20' ;;
            esac
        }
        ssl_check_dns dual.example.com dual
    ); then
        fail "双栈 DNS 校验要求同时存在匹配的 A 和 AAAA 记录"
    else
        pass "双栈 DNS 校验要求同时存在匹配的 A 和 AAAA 记录"
    fi
}

test_issue_and_renew_reuse_saved_ipv6_listener_mode() {
    local case_dir="$TEST_TMP/ipv6-acme"
    local acme_home="$case_dir/acme"
    local cert_base="$case_dir/live"
    local config_dir="$case_dir/config"
    local args_file="$case_dir/acme.args"
    local domain="ipv6.example.com"
    mkdir -p "$acme_home/$domain" "$case_dir"

    cat > "$acme_home/acme.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ACME_ARGS_FILE"
if [[ " $* " == *" --install-cert "* ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fullchain-file) fullchain="$2"; shift 2 ;;
            --key-file) privkey="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf 'fullchain\n' > "$fullchain"
    printf 'privkey\n' > "$privkey"
fi
EOF
    chmod +x "$acme_home/acme.sh"

    if (
        SSL_ACME_HOME="$acme_home"
        SSL_CERT_BASE="$cert_base"
        SSL_CERTBOT_CONFIG_DIR="$config_dir"
        SSL_LEGACY_CERT_BASE="$case_dir/legacy"
        export ACME_ARGS_FILE="$args_file"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_issue_cert "$domain" ipv6
        ssl_renew_cert "$domain"
    ); then
        local acme_args
        acme_args=$(<"$args_file")
        assert_contains "$acme_args" "--issue --standalone -d $domain --server letsencrypt --keylength 2048 --listen-v6" "IPv6 申请使用仅 IPv6 监听"
        assert_contains "$acme_args" "--renew -d $domain --standalone --server letsencrypt --listen-v6" "续期复用已保存的 IPv6 监听模式"
    else
        fail "IPv6 申请与续期使用已保存监听模式"
    fi
}

test_renew_does_not_force_reissue() {
    local case_dir="$TEST_TMP/renew"
    local acme_home="$case_dir/acme"
    local cert_base="$case_dir/certs"
    local args_file="$case_dir/acme.args"
    local domain="example.com"

    mkdir -p "$acme_home/$domain" "$cert_base/$domain" "$case_dir/bin"
    cat > "$acme_home/acme.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ACME_ARGS_FILE"
if [[ " $* " == *" --install-cert "* ]]; then
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fullchain-file) fullchain="$2"; shift 2 ;;
            --key-file) privkey="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    printf 'fullchain\n' > "$fullchain"
    printf 'privkey\n' > "$privkey"
fi
EOF
    chmod +x "$acme_home/acme.sh"

    if ! (
        SSL_ACME_HOME="$acme_home"
        SSL_CERT_BASE="$cert_base"
        SSL_CERTBOT_CONFIG_DIR="$case_dir/config"
        _ssl_log_file="$case_dir/ssl-certbot.log"
        export ACME_ARGS_FILE="$args_file"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_renew_cert "$domain"
    ); then
        fail "普通续期调用 acme.sh --renew"
        fail "普通续期不强制重新签发"
        return
    fi

    local renew_args
    renew_args=$(head -n 1 "$args_file")
    assert_contains "$renew_args" "--renew" "普通续期调用 acme.sh --renew"
    assert_not_contains "$renew_args" "--force" "普通续期不强制重新签发"
}

test_certificate_expiry_uses_china_standard_time_format() {
    local case_dir="$TEST_TMP/expiry"
    mkdir -p "$case_dir/bin"
    cat > "$case_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"Dec  6 09:30:50 2026 GMT"* ]]; then
    printf '%s\n' '2026年12月06日 17:30:50（中国标准时间）'
fi
EOF
    chmod +x "$case_dir/bin/date"

    PATH="$case_dir/bin:$PATH"
    source "$PROJECT_ROOT/src/cert.sh"

    local result
    result=$(ssl_format_cert_expiry 'Dec  6 09:30:50 2026 GMT')
    if [[ "$result" == "2026年12月06日 17:30:50（中国标准时间）" ]]; then
        pass "证书到期时间显示为中国标准时间"
    else
        fail "证书到期时间显示为中国标准时间"
    fi
}

test_remove_certificate_removes_local_files_and_acme_record() {
    local case_dir="$TEST_TMP/remove"
    local cert_base="$case_dir/certs"
    local acme_home="$case_dir/acme"
    local acme_args="$case_dir/acme.args"
    local config_dir="$case_dir/config"
    local domain="example.com"
    mkdir -p "$cert_base/$domain" "$acme_home/$domain"
    printf '%s\n' certificate > "$cert_base/$domain/fullchain.pem"
    printf '%s\n' private-key > "$cert_base/$domain/privkey.pem"
    cat > "$case_dir/acme.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ACME_ARGS_FILE"
EOF
    chmod +x "$case_dir/acme.sh"

    if (
        SSL_CERT_BASE="$cert_base"
        SSL_ACME_HOME="$acme_home"
        SSL_ACME_BIN="$case_dir/acme.sh"
        SSL_CERTBOT_CONFIG_DIR="$config_dir"
        export ACME_ARGS_FILE="$acme_args"
        ssl_log() { :; }
        ssl_validate_domain() { return 0; }
        mkdir -p "$config_dir"
        printf '%s\n' 'SSL_CERTBOT_NETWORK_MODE=ipv6' > "$config_dir/$domain.conf"
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_remove_cert "$domain" yes
    ); then
        if [[ ! -d "$cert_base/$domain" ]] && [[ ! -e "$config_dir/$domain.conf" ]] && \
           grep -q -- '--remove -d example.com' "$acme_args"; then
            pass "删除证书会移除本地文件、网络模式和 acme.sh 记录"
        else
            fail "删除证书会移除本地文件、网络模式和 acme.sh 记录"
        fi
    else
        fail "删除证书会移除本地文件、网络模式和 acme.sh 记录"
    fi
}

test_dns_failure_does_not_pause_services() {
    local case_dir="$TEST_TMP/dns-preflight"
    local pause_marker="$case_dir/pause.called"
    mkdir -p "$case_dir"

    if (
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh"
        ssl_validate_domain() { return 0; }
        ssl_select_network_mode() { printf '%s\n' ipv6; }
        ssl_ensure_acme() { :; }
        ssl_acquire_lock() { :; }
        ssl_check_dns() { return 1; }
        ssl_pause_port_services() { : > "$pause_marker"; }
        ssl_cmd_apply example.com ipv6
    ); then
        fail "DNS 预检失败时不会暂停服务"
    elif [[ ! -e "$pause_marker" ]]; then
        pass "DNS 预检失败时不会暂停服务"
    else
        fail "DNS 预检失败时不会暂停服务"
    fi
}

test_remove_certificate_requires_confirmation() {
    local case_dir="$TEST_TMP/remove-confirm"
    local cert_base="$case_dir/certs"
    local domain="example.com"
    mkdir -p "$cert_base/$domain"
    printf '%s\n' certificate > "$cert_base/$domain/fullchain.pem"

    if (
        SSL_CERT_BASE="$cert_base"
        SSL_ACME_HOME="$case_dir/acme"
        ssl_log() { :; }
        ssl_validate_domain() { return 0; }
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_remove_cert "$domain" no
    ); then
        fail "删除证书需要明确确认"
    elif [[ -d "$cert_base/$domain" ]]; then
        pass "删除证书需要明确确认"
    else
        fail "删除证书需要明确确认"
    fi
}

test_docker_inspect_finds_non_wildcard_bindings() {
    local case_dir="$TEST_TMP/docker"
    mkdir -p "$case_dir/bin"
    cat > "$case_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    info) exit 0 ;;
    ps)
        printf '%s\n' 'container-a api'
        ;;
    inspect)
        if [[ "${!#}" == "container-a" ]]; then
            printf '%s\n' '127.0.0.1 80'
            printf '%s\n' '203.0.113.10 443'
        fi
        ;;
esac
EOF
    chmod +x "$case_dir/bin/docker"

    PATH="$case_dir/bin:$PATH"
    source "$PROJECT_ROOT/src/port_service.sh"

    local result
    result=$(ssl_detect_docker_containers)
    assert_contains "$result" "container-a api 80" "识别绑定到 127.0.0.1:80 的 Docker 容器"
    assert_contains "$result" "container-a api 443" "识别绑定到具体 IPv4 地址:443 的 Docker 容器"
}

test_docker_container_name_requires_a_running_container() {
    local case_dir="$TEST_TMP/docker-name"
    mkdir -p "$case_dir/bin"
    cat > "$case_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    inspect)
        if [[ "${!#}" == "running-container" ]]; then
            printf '%s\n' '/web-nginx'
        fi
        ;;
esac
EOF
    chmod +x "$case_dir/bin/docker"

    PATH="$case_dir/bin:$PATH"
    source "$PROJECT_ROOT/src/port_service.sh"

    local running_name missing_name
    running_name=$(ssl_get_docker_container_name running-container || true)
    missing_name=$(ssl_get_docker_container_name missing-container || true)
    if [[ "$running_name" == "web-nginx" && -z "$missing_name" ]]; then
        pass "仅将可确认正在运行的 Docker 容器纳入暂停计划"
    else
        fail "仅将可确认正在运行的 Docker 容器纳入暂停计划"
    fi
}

test_supported_listener_uses_its_actual_systemd_unit() {
    local case_dir="$TEST_TMP/systemd-unit"
    local pid="4321"
    mkdir -p "$case_dir/proc/$pid"
    printf '%s\n' '0::/system.slice/custom-web.service' > "$case_dir/proc/$pid/cgroup"

    local result
    result=$( (
        SSL_INIT="systemd"
        SSL_PROC_ROOT="$case_dir/proc"
        SSL_SUPPORTED_LISTENER_PROCESSES=("nginx")
        source "$PROJECT_ROOT/src/port_service.sh"
        ssl_identify_service "$pid" "nginx"
    ) )
    if [[ "$result" == "systemd:custom-web.service" ]]; then
        pass "受支持 Web 进程使用 cgroup 中的实际 systemd 单元"
    else
        fail "受支持 Web 进程使用 cgroup 中的实际 systemd 单元"
    fi
}

test_unsupported_listener_is_not_matched_to_a_systemd_unit() {
    local case_dir="$TEST_TMP/unsupported-unit"
    local pid="8765"
    mkdir -p "$case_dir/proc/$pid"
    printf '%s\n' '0::/system.slice/custom-web.service' > "$case_dir/proc/$pid/cgroup"

    local result
    result=$( (
        SSL_INIT="systemd"
        SSL_PROC_ROOT="$case_dir/proc"
        SSL_SUPPORTED_LISTENER_PROCESSES=("nginx")
        source "$PROJECT_ROOT/src/port_service.sh"
        ssl_identify_service "$pid" "unknown-server"
    ) )
    if [[ -z "$result" ]]; then
        pass "不支持的监听进程不会仅凭 systemd 单元自动管理"
    else
        fail "不支持的监听进程不会仅凭 systemd 单元自动管理"
    fi
}

test_process_name_without_verified_unit_is_unmanaged() {
    local result
    if ! result=$( (
        SSL_INIT="systemd"
        source "$PROJECT_ROOT/src/port_service.sh"
        ssl_identify_service "$$" "nginx"
    ) ); then
        fail "未归属白名单服务单元的 nginx 进程不会被自动管理"
        return
    fi

    if [[ -z "$result" ]]; then
        pass "未归属白名单服务单元的 nginx 进程不会被自动管理"
    else
        fail "未归属白名单服务单元的 nginx 进程不会被自动管理"
    fi
}

test_preflight_does_not_stop_when_any_listener_is_unmanaged() {
    local case_dir="$TEST_TMP/preflight"
    local stopped_marker="$case_dir/stopped"
    mkdir -p "$case_dir/state"

    if (
        SSL_STATE_DIR="$case_dir/state"
        SSL_INIT="systemd"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/port_service.sh"
        ssl_detect_port_listeners() {
            case "$1" in
                80) printf '%s\n' '101 nginx 80 tcp' ;;
                443) printf '%s\n' '202 unknown 443 tcp' ;;
            esac
        }
        ssl_identify_service() {
            [[ "$1" == "101" ]] && printf '%s\n' 'systemd:nginx.service'
        }
        ssl_stop_service() { : > "$stopped_marker"; }
        ssl_pause_port_services
    ); then
        fail "存在未知监听进程时预检不停止任何服务"
    elif [[ ! -e "$stopped_marker" ]]; then
        pass "存在未知监听进程时预检不停止任何服务"
    else
        fail "存在未知监听进程时预检不停止任何服务"
    fi
}

test_renew_skip_does_not_pause_services() {
    local case_dir="$TEST_TMP/skip"
    local pause_marker="$case_dir/pause.called"

    mkdir -p "$case_dir/certs/example.com"
    : > "$case_dir/certs/example.com/fullchain.pem"

    if (
        SSL_CERT_BASE="$case_dir/certs"
        SSL_CERTBOT_CONFIG_DIR="$case_dir/config"
        _ssl_log_file="$case_dir/ssl-certbot.log"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_cert_needs_renewal_file() { return 1; }
        ssl_pause_port_services() { : > "$pause_marker"; }
        ssl_restore_services() { :; }
        ssl_renew_managed_certificates
    ); then
        if [[ ! -e "$pause_marker" ]]; then
            pass "无需续期时不暂停端口服务"
        else
            fail "无需续期时不暂停端口服务"
        fi
    else
        fail "无需续期时批量续期返回成功"
    fi
}

test_renew_failure_returns_nonzero() {
    local case_dir="$TEST_TMP/failure"

    mkdir -p "$case_dir/certs/example.com"
    : > "$case_dir/certs/example.com/fullchain.pem"

    if (
        SSL_CERT_BASE="$case_dir/certs"
        SSL_CERTBOT_CONFIG_DIR="$case_dir/config"
        _ssl_log_file="$case_dir/ssl-certbot.log"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_cert_needs_renewal_file() { return 0; }
        ssl_pause_port_services() { :; }
        ssl_renew_cert() { return 1; }
        ssl_restore_services() { :; }
        ssl_renew_managed_certificates
    ); then
        fail "单个证书续期失败时批量续期返回非零"
    else
        pass "单个证书续期失败时批量续期返回非零"
    fi
}

test_remote_installer_is_independent_bootstrap() {
    local installer
    if [[ ! -f "$PROJECT_ROOT/install.sh" ]]; then
        fail "仓库根目录存在远程安装器"
        return
    fi
    installer=$(<"$PROJECT_ROOT/install.sh")

    assert_contains "$installer" "mktemp -d" "远程安装器使用临时目录"
    assert_contains "$installer" "install/install.sh" "远程安装器委托仓库内安装器"
    assert_contains "$installer" '[[ ! -f "$project_dir/install/install.sh" ]]' "远程安装器不要求内部安装脚本带执行权限"
    assert_not_contains "$installer" '[[ ! -x "$project_dir/install/install.sh" ]]' "远程安装器不误判 Git 文件权限"
    assert_not_contains "$installer" 'exec bash "$project_dir/install/install.sh"' "远程安装器保留清理临时目录的退出陷阱"
    assert_not_contains "$installer" 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")"' "远程安装器不依赖进程替换脚本所在目录"
}

test_installer_deploys_uninstaller() {
    local installer
    installer=$(<"$PROJECT_ROOT/install/install.sh")

    assert_contains "$installer" "uninstall.sh" "安装器会部署卸载脚本"
}

test_entry_help_uses_installed_command_name() {
    local case_dir="$TEST_TMP/entry"
    mkdir -p "$case_dir"
    cp "$PROJECT_ROOT/src/w-entry.sh" "$case_dir/sslcert"
    chmod +x "$case_dir/sslcert"

    local help_output
    help_output=$("$case_dir/sslcert" help)
    assert_contains "$help_output" "sslcert ssl" "备用命令帮助显示实际安装命令名"
    assert_not_contains "$help_output" "    w ssl" "备用命令帮助不硬编码默认命令名"
}

test_entry_supports_uninstall_command() {
    local entry ssl_script
    entry=$(<"$PROJECT_ROOT/src/w-entry.sh")
    ssl_script=$(<"$PROJECT_ROOT/src/ssl-certbot.sh")

    assert_contains "$entry" "uninstall" "快捷命令支持卸载子命令"
    assert_contains "$ssl_script" '"${LIB_DIR}/uninstall.sh"' "卸载命令调用已安装的卸载脚本"
}

test_acme_installer_does_not_use_removed_install_online_option() {
    local common
    common=$(<"$PROJECT_ROOT/src/common.sh")

    assert_not_contains "$common" "--install-online" "acme.sh 安装不使用已废弃的 install-online 参数"
}

test_acme_bootstrap_does_not_receive_account_options() {
    local common
    common=$(<"$PROJECT_ROOT/src/common.sh")

    assert_contains "$common" "curl -fsSL https://get.acme.sh | sh -s --" "acme.sh 使用官方无参数引导器"
    assert_not_contains "$common" 'sh -s -- "email=' "acme.sh 引导器不接收邮箱参数"
    assert_not_contains "$common" "--home \"\$SSL_ACME_HOME\"" "acme.sh 引导器不接收内部安装参数"
    assert_contains "$common" '"$SSL_ACME_HOME/acme.sh" --uninstall-cronjob' "安装后移除 acme.sh 自己的 cron 任务"
}

test_acme_setup_does_not_require_an_email_address() {
    local common
    common=$(<"$PROJECT_ROOT/src/common.sh")

    assert_not_contains "$common" "请输入用于证书到期通知的邮箱" "首次申请不要求证书通知邮箱"
    assert_not_contains "$common" "ssl_validate_acme_email" "脚本不校验证书通知邮箱"
    assert_contains "$common" '"$SSL_ACME_HOME/acme.sh" --register-account --server letsencrypt' "申请前会注册无邮箱的 Let’s Encrypt 账户"
    assert_contains "$common" "ssl_clear_acme_account_email" "会清除遗留的无效账户邮箱"
    assert_not_contains "$common" "register-account -m" "注册命令不再使用邮箱"
}

test_acme_email_cleanup_covers_account_and_ca_configs() {
    local common
    common=$(<"$PROJECT_ROOT/src/common.sh")

    assert_contains "$common" 'find "$SSL_ACME_HOME" -type f -name "*.conf"' "会扫描 acme.sh 的所有账户与 CA 配置文件"
    assert_contains "$common" "ACCOUNT_EMAIL" "会清除遗留账户邮箱"
    assert_contains "$common" "CA_EMAIL" "会清除遗留 CA 邮箱"
}

test_ssl_menu_includes_update_and_uninstall_actions() {
    local ssl_script
    ssl_script=$(<"$PROJECT_ROOT/src/ssl-certbot.sh")

    assert_contains "$ssl_script" "7. 更新脚本" "交互菜单提供更新脚本选项"
    assert_contains "$ssl_script" "8. 卸载 ssl-certbot" "交互菜单提供卸载选项"
    assert_contains "$ssl_script" "update)" "命令行支持更新脚本子命令"
}

test_readme_uses_pipe_installation_for_alpine() {
    local readme alpine_section
    readme=$(<"$PROJECT_ROOT/README.md")
    alpine_section=$(printf '%s\n' "$readme" | awk '
        /# Alpine Linux 首次安装/ { in_section = 1 }
        in_section { print }
        in_section && /^```$/ {
            fences++
            if (fences == 2) {
                exit
            }
        }
    ')

    assert_contains "$alpine_section" "curl -fsSL https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh | bash" "Alpine 安装使用不依赖 /dev/fd 的管道方式"
    assert_not_contains "$alpine_section" "bash <(" "Alpine 安装不使用可能受限的进程替换"
}

test_readme_documents_letsencrypt_live_path_and_network_modes() {
    local readme
    readme=$(<"$PROJECT_ROOT/README.md")

    assert_contains "$readme" "/etc/letsencrypt/live/<domain>/fullchain.pem" "README 使用新的 letsencrypt 证书目录"
    assert_contains "$readme" "w ssl <domain> [ipv4\\|ipv6\\|dual]" "README 说明 IPv4 IPv6 双栈命令"
}

test_network_mode_persistence_and_legacy_certificate_migration
test_network_mode_rejects_invalid_values
test_interactive_network_mode_menu_writes_to_terminal
test_renewal_retry_schedule_is_documented_and_persistent
test_ipv6_dns_validation_uses_local_addresses_without_ipv4_egress_lookup
test_ipv4_dns_validation_accepts_public_nat_address
test_dual_stack_dns_requires_matching_a_and_aaaa_records
test_issue_and_renew_reuse_saved_ipv6_listener_mode
test_renew_does_not_force_reissue
test_certificate_expiry_uses_china_standard_time_format
test_remove_certificate_removes_local_files_and_acme_record
test_remove_certificate_requires_confirmation
test_dns_failure_does_not_pause_services
test_docker_inspect_finds_non_wildcard_bindings
test_docker_container_name_requires_a_running_container
test_supported_listener_uses_its_actual_systemd_unit
test_unsupported_listener_is_not_matched_to_a_systemd_unit
test_process_name_without_verified_unit_is_unmanaged
test_preflight_does_not_stop_when_any_listener_is_unmanaged
test_renew_skip_does_not_pause_services
test_renew_failure_returns_nonzero
test_remote_installer_is_independent_bootstrap
test_installer_deploys_uninstaller
test_entry_help_uses_installed_command_name
test_entry_supports_uninstall_command
test_acme_installer_does_not_use_removed_install_online_option
test_acme_bootstrap_does_not_receive_account_options
test_acme_setup_does_not_require_an_email_address
test_acme_email_cleanup_covers_account_and_ca_configs
test_ssl_menu_includes_update_and_uninstall_actions
test_readme_uses_pipe_installation_for_alpine
test_readme_documents_letsencrypt_live_path_and_network_modes

if [[ "$fail_count" -ne 0 ]]; then
    printf '%s test(s) failed; %s passed.\n' "$fail_count" "$pass_count" >&2
    exit 1
fi

printf 'All %s tests passed.\n' "$pass_count"
