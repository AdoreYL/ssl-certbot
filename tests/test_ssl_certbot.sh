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

test_cf_account_state_and_binding() {
    local root="$TEST_TMP/cf-state" out
    mkdir -p "$root"
    if out=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cloudflare.sh"
        ssl_cf_add_account "主账号" "test-secret-one"
        ssl_cf_add_account "备用账号" "test-secret-two"
        [[ "$(ssl_cf_account_for_domain example.com)" == "" ]]
        ssl_cf_bind_domain example.com 1
        [[ "$(ssl_cf_account_for_domain example.com)" == 1 ]]
        [[ "$(ssl_validation_method example.com)" == dns ]]
        ! ssl_cf_remove_account 1
        ssl_cf_remove_account 2
        ssl_cf_add_account "第三账号" "test-secret-three"
        [[ "$(ssl_cf_list_accounts)" == *$'3\t第三账号'* ]]
        # Mode bits are only meaningful where the host enforces them; on the
        # Windows development host they are emulated, so check them only when
        # the state layer reports enforcement.
        if ssl_cf_modes_enforced; then
            [[ "$(stat -c %a "$root/config/cloudflare/1/token")" == 600 ]] || exit 1
            [[ "$(stat -c %a "$root/config/cloudflare")" == 700 ]] || exit 1
        fi
    ); then
        assert_not_contains "$out" 'test-secret-' "Cloudflare 凭据不进入输出，账号编号不复用且绑定不漂移"
    else
        fail "Cloudflare 账号存储和域名绑定"
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
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
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

test_ipv6_local_address_filter_excludes_ula_addresses() {
    local addresses

    addresses=$(
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ip() {
            printf '%s\n' \
                '2: eth0    inet6 fd00::100/64 scope global' \
                '2: eth0    inet6 2001:db8:100::165/64 scope global'
        }
        ssl_local_ip_addresses ipv6
    )

    assert_not_contains "$addresses" "fd00::100" "IPv6 本机地址忽略 ULA 私有地址"
    assert_contains "$addresses" "2001:db8:100::165" "IPv6 本机地址保留公网地址"
}

test_ipv4_dns_validation_accepts_public_nat_address() {
    local case_dir="$TEST_TMP/ipv4-nat"
    local calls="$case_dir/calls"
    mkdir -p "$case_dir"

    if (
        SSL_CERTBOT_NO_MAIN=1
        ssl_log() { :; }
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
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

test_ipv6_dns_validation_accepts_public_nat_address() {
    local case_dir="$TEST_TMP/ipv6-nat"
    local calls="$case_dir/calls"
    mkdir -p "$case_dir"

    if (
        SSL_CERTBOT_NO_MAIN=1
        ssl_log() { :; }
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_resolve_dns_records() {
            [[ "$2" == "AAAA" ]] && printf '%s\n' '2001:db8:100::165'
        }
        ssl_local_ip_addresses() {
            [[ "$1" == "ipv6" ]] && printf '%s\n' 'fd00::100'
        }
        curl() {
            printf '%s\n' "$*" >> "$calls"
            printf '%s\n' '2001:db8:100::165'
        }
        ssl_check_dns nat6.example.com ipv6
    ); then
        assert_contains "$(cat "$calls")" "-6" "IPv6 NAT 校验使用 IPv6 公网出口查询"
        assert_not_contains "$(cat "$calls")" "-4" "IPv6 NAT 校验不使用 IPv4 公网出口查询"
    else
        fail "IPv6 NAT 校验接受与公网出口匹配的 AAAA 记录"
    fi
}

test_dual_stack_dns_requires_matching_a_and_aaaa_records() {
    if (
        SSL_CERTBOT_NO_MAIN=1
        ssl_log() { :; }
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
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
        source "$PROJECT_ROOT/src/cloudflare.sh"
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
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
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

test_remove_still_clears_local_files_when_acme_record_fails() {
    local root="$TEST_TMP/remove-acme-fail" output
    mkdir -p "$root/live/api.example.com" "$root/acme-install"
    cat > "$root/acme-install/acme.sh" <<'FAKEACME'
#!/usr/bin/env bash
exit 1
FAKEACME
    printf cert > "$root/live/api.example.com/fullchain.pem"
    printf key > "$root/live/api.example.com/privkey.pem"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/acme-install"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_cf_add_account primary 'test-secret-one' >/dev/null || exit 1
        ssl_cf_bind_domain api.example.com 1 || exit 1
        ssl_remove_cert api.example.com yes || exit 1
        [[ ! -d "$root/live/api.example.com" ]] || exit 1
        [[ ! -e "$root/config/api.example.com.conf" ]] || exit 1
        # The account itself stays usable for other domains.
        ssl_cf_account_ready 1 || exit 1
    ); then
        assert_contains "$output" "未能" "删除证书时 acme.sh 记录失败只警告不阻断"
    else
        fail "删除证书时 acme.sh 记录失败只警告不阻断"
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
        source "$PROJECT_ROOT/src/cloudflare.sh"
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

test_cf_security_and_dns_route() {
    local root="$TEST_TMP/cf-security" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_cf_add_account primary 'test-secret-one' >/dev/null || exit 1
        ssl_cf_add_account backup 'test-secret-two' >/dev/null || exit 1
        ! ssl_cf_add_account unsafe $'bad\nname' || exit 1
        ! ssl_validate_dns_domain 'foo.*.example.com' || exit 1
        ! ssl_validate_dns_domain '../example.com' || exit 1
        ssl_validate_dns_domain '*.example.com' || exit 1
        ssl_acquire_lock() { :; }
        ssl_ensure_acme() { :; }
        ssl_install_cron_job() { :; }
        ssl_check_dns() { echo 'wrong DNS preflight' >&2; return 1; }
        ssl_pause_port_services() { echo 'wrong pause' >&2; return 1; }
        ssl_issue_dns_cert() {
            [[ "$1" == '*.example.com' && "$2" == 1 ]] || return 1
            ssl_cf_bind_domain "$1" "$2"
        }
        ssl_cmd_apply '*.example.com' dns 1 || exit 1
        ! ssl_cmd_apply '*.example.com' dns 2 || exit 1
        ! ssl_cmd_apply '*.example.com' ipv4 || exit 1
        ! ssl_cmd_apply '*.example.com' dns || exit 1
        [[ $(ssl_validation_method '*.example.com') == dns ]] || exit 1
        [[ $(ssl_cf_account_for_domain '*.example.com') == 1 ]] || exit 1
        ! ssl_cf_remove_account 1 || exit 1
        ssl_cf_update_account 1 'test-secret-new' || exit 1
        [[ $(ssl_cf_token 1) == 'test-secret-new' ]] || exit 1
        # Only assert the symlink guard where the filesystem really supports
        # symlinks; Git Bash degrades "ln -s" to a copy, which would make this
        # check test the platform instead of the code.
        if ln -s "$root/config/cloudflare/2/token" "$root/config/cloudflare/1/link-probe" 2>/dev/null && [[ -L "$root/config/cloudflare/1/link-probe" ]]; then
            mv "$root/config/cloudflare/1/token" "$root/config/cloudflare/1/old" || exit 1
            mv "$root/config/cloudflare/1/link-probe" "$root/config/cloudflare/1/token" || exit 1
            ! ssl_cf_token 1 || exit 1
        fi
    ); then
        assert_not_contains "$output" 'test-secret-' '账号校验、改绑保护及 DNS 路径不泄漏 Token'
        assert_not_contains "$output" 'wrong' 'DNS 路径不查询地址也不暂停服务'
    else
        fail '账号校验、改绑保护及 DNS 路径'
    fi
}

test_cf_api_does_not_expose_token_in_argv() {
    local root="$TEST_TMP/cf-api" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        source "$PROJECT_ROOT/src/common.sh"
        source "$PROJECT_ROOT/src/cloudflare.sh"
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        jq() {
            case "$*" in
                *'.success == true and .result.status'*) printf 'true\n' ;;
                *'select(.name == $name'*) printf 'zone1\n' ;;
                *) return 1 ;;
            esac
        }
        curl() {
            [[ " $* " != *test-secret-one* ]] || return 1
            local config='' arg
            for arg in "$@"; do [[ "$arg" == '-' ]] && config=$(cat); done
            [[ "$config" == *'test-secret-one'* ]] || return 1
            case "$*" in
                *tokens/verify*) printf '%s' '{"success":true,"result":{"status":"active"}}' ;;
                *zones*) printf '%s' '{"success":true,"result":[{"name":"example.com","status":"active","id":"zone1"}]}' ;;
            esac
        }
        ssl_cf_test_account 1 '*.example.com' || exit 1
    2>&1); then
        assert_not_contains "$output" 'test-secret-' 'API 凭据通过 stdin 传送且输出无 Token'
    else
        fail 'API 调用不得在 argv 携带 Token'
    fi
}

test_dns_acme_calls_are_isolated_per_account() {
    local root="$TEST_TMP/cf-acme" output calls conf
    mkdir -p "$root/acme-install/dnsapi"
    cat > "$root/acme-install/acme.sh" <<'FAKEACME'
#!/usr/bin/env bash
{
    printf 'CALL'
    for arg in "$@"; do printf ' %s' "$arg"; done
    if [[ -n ${CF_Token:-} ]]; then printf ' CF_TOKEN_PRESENT=yes'; else printf ' CF_TOKEN_PRESENT=no'; fi
    printf '\n'
} >> "$ACME_ARGS_FILE"
fullchain=''
prev=''
for arg in "$@"; do
    if [[ "$prev" == "--fullchain-file" ]]; then fullchain="$arg"; fi
    prev="$arg"
done
if [[ -n "$fullchain" ]]; then
    mkdir -p "${fullchain%/*}"
    printf 'cert-%s' "$(wc -l < "$ACME_ARGS_FILE")" > "$fullchain"
    printf key > "${fullchain%fullchain.pem}privkey.pem"
fi
exit 0
FAKEACME
    chmod +x "$root/acme-install/acme.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/acme-install/dnsapi/dns_cf.sh"

    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/acme-install"
        export ACME_ARGS_FILE="$root/acme.args"
        : > "$ACME_ARGS_FILE"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        ssl_cf_add_account backup 'test-secret-two' >/dev/null
        ssl_issue_dns_cert '*.example.com' 1 || exit 1
        ssl_issue_dns_cert 'api.example.net' 2 || exit 1
        printf 'SAVED_CF_Token=stale-secret\nCF_Token=stale-secret\n' >> "$root/config/cloudflare/1/acme/account.conf"
        ssl_cf_update_account 1 'test-secret-new' || exit 1
        ssl_renew_dns_cert '*.example.com' 1 || exit 1
    ); then
        calls=$(<"$root/acme.args")
        assert_contains "$calls" "--issue --dns dns_cf" "DNS 申请使用 dns_cf 插件"
        assert_not_contains "$calls" "--standalone" "DNS 申请不使用 standalone 监听"
        assert_contains "$calls" "--config-home $root/config/cloudflare/1/acme" "账号 1 使用独立的 acme 配置目录"
        assert_contains "$calls" "--config-home $root/config/cloudflare/2/acme" "账号 2 使用另一个 acme 配置目录"
        assert_not_contains "$calls" "--config-home $root/acme-install" "DNS 调用不复用 HTTP 的 acme 配置目录"
        assert_not_contains "$calls" "--key-file $root/acme-install" "DNS 私钥不写入共享 acme 目录"
        assert_contains "$calls" "CF_TOKEN_PRESENT=yes" "Token 通过环境变量交给 dns_cf"
        assert_not_contains "$calls" "test-secret" "acme.sh 参数不携带 Token"
        assert_not_contains "$calls" "--debug" "DNS 调用不启用会泄漏凭据的 debug 模式"
        assert_not_contains "$calls" "--output-insecure" "DNS 调用不关闭 acme.sh 的敏感信息遮蔽"
        assert_contains "$calls" "--log-level 1" "DNS 调用把 acme.sh 日志限制在最小级别"
        assert_not_contains "$output" "test-secret" "DNS 签发输出不泄漏 Token"
        conf=$(<"$root/config/cloudflare/1/acme/account.conf")
        assert_not_contains "$conf" "stale-secret" "换票后不残留 acme.sh 持久化的旧 Token"
    else
        fail "DNS 签发按账号隔离 acme 状态"
    fi
}

test_dns_acme_rejects_unsafe_log_before_execution() {
    local root="$TEST_TMP/cf-unsafe-log"
    mkdir -p "$root/install" "$root/state"
    printf '#!/usr/bin/env bash\nprintf called > "$ACME_CALLED"\n' > "$root/install/acme.sh"
    chmod +x "$root/install/acme.sh"
    printf 'keep-existing-log\n' > "$root/state/acme.sh.log"
    if (
        source "$PROJECT_ROOT/src/cert.sh"
        SSL_ACME_HOME="$root/install"
        export ACME_CALLED="$root/called"
        ssl_cf_prepare_acme() { :; }
        ssl_cf_token() { printf test-token; }
        ssl_cf_acme_home() { printf '%s' "$root/state"; }
        # Model the state module rejecting an existing unsafe log on Linux.
        ssl_cf_private_file() { return 1; }
        ssl_log() { :; }
        if ssl_dns_acme_call 1 --renew -d example.com; then exit 1; fi
        [[ ! -e "$ACME_CALLED" ]] || exit 1
        [[ $(cat "$root/state/acme.sh.log") == keep-existing-log ]] || exit 1
    ); then
        pass "DNS 调用在执行 acme.sh 前拒绝不安全日志且保留原内容"
    else
        fail "DNS 调用在执行 acme.sh 前拒绝不安全日志且保留原内容"
    fi
}

test_corrupted_certificate_does_not_abort_listing() {
    local root="$TEST_TMP/corrupt-cert" output status_out
    mkdir -p "$root/live/bad.example.com" "$root/live/also-bad.example.com"
    printf 'this is not a certificate\n' > "$root/live/bad.example.com/fullchain.pem"
    printf key > "$root/live/bad.example.com/privkey.pem"
    printf 'also not a certificate\n' > "$root/live/also-bad.example.com/fullchain.pem"
    printf key > "$root/live/also-bad.example.com/privkey.pem"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_deps() { :; }
        ssl_pause_port_services() { return 1; }
        ssl_restore_services() { :; }
        status_out=$(ssl_cert_status bad.example.com) || exit 1
        # The status page indents fields with two spaces; the list page uses
        # four. Anchor the check at the start of the line so a four-space
        # indent cannot satisfy it as a substring.
        if printf '%s\n' "$status_out" | grep -qE '^  验证方式'; then
            echo "STATUS_INDENT_OK"
        else
            echo "STATUS_INDENT_BAD"
        fi
        ssl_list_certs || exit 1
        # An unreadable certificate is a counted failure, not a crash: the
        # batch must still report it and return a non-zero status.
        if ssl_renew_managed_certificates; then
            echo "batch renew should report failure for unreadable certs" >&2
            exit 1
        fi
    ); then
        assert_contains "$output" "also-bad.example.com" "损坏证书不会中断列表与状态显示"
        assert_contains "$output" "未知" "损坏证书显示为未知到期时间"
        assert_contains "$output" "无法确定到期时间" "损坏证书被计入续期失败而不是静默跳过"
        assert_not_contains "$output" "STATUS_INDENT_BAD" "状态页的验证方式行使用两空格缩进"
    else
        fail "损坏证书不会中断列表、状态与批量续期"
    fi
}

test_dns_renewal_requires_existing_acme_installation() {
    local root="$TEST_TMP/cf-noacme" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/missing-acme"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        ssl_cf_bind_domain api.example.com 1
        mkdir -p "$root/live/api.example.com"
        ssl_renew_dns_cert 'api.example.com' 1
    ); then
        fail "缺少 acme.sh 时 DNS 续期必须失败"
    else
        assert_contains "$output" "acme.sh" "缺少 acme.sh 时给出明确错误"
        assert_not_contains "$output" "test-secret" "失败信息不泄漏 Token"
    fi
}

test_mixed_renewal_processes_dns_when_http_pause_fails() {
    local root="$TEST_TMP/cf-mixed" output
    mkdir -p "$root/live/web.example.com" "$root/live/api.example.com"
    printf cert > "$root/live/web.example.com/fullchain.pem"
    printf cert > "$root/live/api.example.com/fullchain.pem"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_cert_needs_renewal_file() { return 0; }
        ssl_pause_port_services() { return 1; }
        ssl_restore_services() { :; }
        ssl_renew_cert() { echo 'wrong http renewal' >&2; return 1; }
        ssl_renew_dns_cert() {
            [[ "$1" == 'api.example.com' && "$2" == 1 ]] || return 1
            echo 'dns renewed' >&2
        }
        ssl_save_network_mode web.example.com ipv4
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        ssl_cf_bind_domain api.example.com 1
        ssl_renew_managed_certificates
    ); then
        fail "HTTP 端口预检失败时批量续期必须返回失败"
    else
        assert_contains "$output" "dns renewed" "HTTP 端口预检失败时 DNS 证书仍然续期"
        assert_not_contains "$output" "wrong http renewal" "HTTP 预检失败时不尝试 HTTP 续期"
    fi
}

test_dedicated_dns_batch_renewal_does_not_touch_ports() {
    local root="$TEST_TMP/cf-dnsbatch" output
    mkdir -p "$root/live/api.example.com"
    printf cert > "$root/live/api.example.com/fullchain.pem"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_cert_needs_renewal_file() { return 0; }
        ssl_pause_port_services() { echo 'wrong pause' >&2; return 1; }
        ssl_restore_services() { echo 'wrong restore' >&2; }
        ssl_renew_dns_cert() { echo 'dns renewed' >&2; }
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        ssl_cf_bind_domain api.example.com 1
        ssl_renew_managed_certificates
    ); then
        assert_not_contains "$output" "wrong pause" "纯 DNS 批量续期不暂停端口"
        assert_not_contains "$output" "wrong restore" "纯 DNS 批量续期不恢复端口服务"
        assert_contains "$output" "dns renewed" "纯 DNS 批量续期执行续期"
    else
        fail "纯 DNS 批量续期"
    fi
}

test_dns_account_isolation_helpers() {
    local root="$TEST_TMP/cf-isolation" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        ssl_cf_prepare_acme 1 || exit 1
        printf 'SAVED_CF_Token=stale-secret\nCF_Token="stale-secret"\nSAVED_CF_Account_ID=stale-acct\nCF_Zone_ID=stale-zone\nACCOUNT_THUMBPRINT=keep-me\n' > "$root/config/cloudflare/1/acme/account.conf"
        mkdir -p "$root/config/cloudflare/1/acme/example.com"
        printf 'CF_Token=stale-secret\nCF_Account_ID=stale-acct\nLe_Webroot=dns dns_cf\n' > "$root/config/cloudflare/1/acme/example.com/reg.conf"
        ssl_cf_prepare_acme 1 || exit 1
        acct=$(<"$root/config/cloudflare/1/acme/account.conf")
        [[ "$acct" != *stale-secret* ]] || exit 1
        [[ "$acct" != *stale-acct* ]] || exit 1
        [[ "$acct" != *stale-zone* ]] || exit 1
        [[ "$acct" == *ACCOUNT_THUMBPRINT=keep-me* ]] || exit 1
        reg=$(<"$root/config/cloudflare/1/acme/example.com/reg.conf")
        [[ "$reg" != *stale-secret* ]] || exit 1
        [[ "$reg" != *stale-acct* ]] || exit 1
        [[ "$reg" == *Le_Webroot=dns\ dns_cf* ]] || exit 1
        if ssl_cf_modes_enforced; then
            [[ "$(stat -c %a "$root/config/cloudflare/1/acme/account.conf")" == 600 ]] || exit 1
        fi
        mkdir -p "$root/live/api.example.com" "$root/live/wild.example.com"
        printf 'SSL_CERTBOT_NETWORK_MODE=ipv4\n' > "$root/config/api.example.com.conf"
        ! ssl_cf_bind_domain api.example.com 1 || exit 1
        conf=$(<"$root/config/api.example.com.conf")
        [[ "$conf" == *SSL_CERTBOT_NETWORK_MODE=ipv4* ]] || exit 1
        ssl_cf_bind_domain '*.wild.example.com' 1 || exit 1
        [[ $(ssl_validation_method '*.wild.example.com') == dns ]] || exit 1
    ); then
        assert_not_contains "$output" "stale-secret" "账号状态清理覆盖大小写与等号空格变体"
        pass "DNS 账号隔离辅助行为"
    else
        fail "DNS 账号隔离辅助行为"
    fi
}

test_dns_renewal_passes_dns_hook_to_acme() {
    local root="$TEST_TMP/cf-renewhook" output calls
    mkdir -p "$root/acme-install/dnsapi"
    cat > "$root/acme-install/acme.sh" <<'FAKEACME'
#!/usr/bin/env bash
{
    printf 'CALL'
    for arg in "$@"; do printf ' %s' "$arg"; done
    printf '\n'
} >> "$ACME_ARGS_FILE"
prev=''
for arg in "$@"; do
    if [[ "$prev" == --fullchain-file ]]; then printf renewed-cert > "$arg"; fi
    prev="$arg"
done
exit 0
FAKEACME
    chmod +x "$root/acme-install/acme.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/acme-install/dnsapi/dns_cf.sh"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/acme-install"
        export ACME_ARGS_FILE="$root/acme.args"
        : > "$root/acme.args"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        ssl_cf_add_account primary 'test-secret-one' >/dev/null
        ssl_cf_bind_domain api.example.com 1
        mkdir -p "$root/live/api.example.com"
        printf cert > "$root/live/api.example.com/fullchain.pem"
        printf key > "$root/live/api.example.com/privkey.pem"
        ssl_renew_dns_cert api.example.com 1 || exit 1
    ); then
        calls=$(<"$root/acme.args")
        assert_contains "$calls" "--renew -d api.example.com --server letsencrypt" "DNS 续期按账号 config-home 续期"
        assert_not_contains "$calls" "--standalone" "DNS 续期不启动 standalone 监听"
    else
        fail "DNS 续期显式使用 dns_cf"
    fi
}

test_http_mode_is_only_added_when_no_file_exists() {
    local root="$TEST_TMP/http-mode-guard" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        ssl_log() { :; }
        source "$PROJECT_ROOT/src/common.sh"
        mkdir -p "$root/config"
        printf 'SSL_CERTBOT_METHOD=dns\nSSL_CERTBOT_CF_ACCOUNT=1\n' > "$root/config/api.example.com.conf"
        ssl_save_network_mode api.example.com ipv6
        conf=$(<"$root/config/api.example.com.conf")
        [[ "$conf" == *"SSL_CERTBOT_METHOD=dns"* ]] || exit 1
        [[ "$conf" != *SSL_CERTBOT_NETWORK_MODE* ]] || exit 1
        ssl_save_network_mode new.example.com ipv4
        conf=$(<"$root/config/new.example.com.conf")
        [[ "$conf" == "SSL_CERTBOT_NETWORK_MODE=ipv4" ]] || exit 1
    2>&1); then
        pass "已有 DNS 绑定的配置文件不被追加网络模式"
    else
        fail "已有 DNS 绑定的配置文件不被追加网络模式"
    fi
}

test_cf_token_rejects_shell_and_config_metacharacters() {
    local root="$TEST_TMP/cf-token-chars" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        # A quote inside the Token would terminate the curl config string and
        # let the value inject further curl options.
        ! ssl_cf_add_account quoted 'abc" --config-url http://evil' || exit 1
        ! ssl_cf_add_account newline "$(printf 'a\nb')" || exit 1
        ! ssl_cf_add_account empty '' || exit 1
        ! ssl_cf_add_account toolong "$(printf 'a%.0s' $(seq 1 3000))" || exit 1
        ssl_cf_add_account good 'v1.abcdef-123456_XY' || exit 1
        [[ $(ssl_cf_token 1) == 'v1.abcdef-123456_XY' ]] || exit 1
        ! ssl_cf_update_account 1 'bad token with spaces' || exit 1
        [[ $(ssl_cf_token 1) == 'v1.abcdef-123456_XY' ]] || exit 1
    ); then
        pass "Cloudflare Token 只接受安全字符且更新失败不破坏原值"
    else
        fail "Cloudflare Token 只接受安全字符且更新失败不破坏原值"
    fi
}

test_account_deletion_honours_wildcard_bindings() {
    local root="$TEST_TMP/cf-wildbinding" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_add_account primary 'test-secret-one' >/dev/null || exit 1
        ssl_cf_add_account backup 'test-secret-two' >/dev/null || exit 1
        ssl_cf_bind_domain '*.example.com' 1 || exit 1
        [[ -f "$root/config/_wildcard_example.com.conf" ]] || exit 1
        # An unrelated account stays deletable while the wildcard binding lives.
        ssl_cf_remove_account 2 || exit 1
        # The bound account must be refused, naming the wildcard domain.
        if ssl_cf_remove_account 1; then
            echo "BAD: bound account was removed" >&2
            exit 1
        fi
    ); then
        assert_not_contains "$output" "test-secret" "账号删除按通配符绑定判定且不泄漏 Token"
        assert_contains "$output" "*.example.com" "拒绝删除时列出通配符域名"
    else
        fail "账号删除按通配符绑定判定"
    fi
}

test_removed_account_leaves_no_credential_on_disk() {
    local root="$TEST_TMP/cf-purge" output
    mkdir -p "$root"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        ssl_cf_add_account primary 'test-secret-one' >/dev/null || exit 1
        # Reproduce what acme.sh itself persists during a dns_cf issuance.
        ssl_cf_prepare_acme 1 || exit 1
        printf "SAVED_CF_Token='persisted-secret'\nACCOUNT_THUMBPRINT=x\n" \
            > "$root/config/cloudflare/1/acme/account.conf" || exit 1
        mkdir -p "$root/config/cloudflare/1/acme/ca/acme-v02.api.letsencrypt.org/directory" || exit 1
        printf 'key-material\n' > "$root/config/cloudflare/1/acme/ca/acme-v02.api.letsencrypt.org/directory/account.key" || exit 1
        mkdir -p "$root/config/cloudflare/1/acme/example.com" || exit 1
        printf "Le_Domain=example.com\nSAVED_CF_Token='persisted-secret'\n" \
            > "$root/config/cloudflare/1/acme/example.com/reg.conf" || exit 1
        ssl_cf_remove_account 1 || exit 1
        [[ ! -e "$root/config/cloudflare/1" ]] || { echo "account dir survives" >&2; exit 1; }
        ! find "$root/config" -name '*.conf' -o -name 'account.key' | grep . >/dev/null 2>&1 || {
            echo "credential file survives" >&2
            exit 1
        }
    ); then
        assert_not_contains "$output" "persisted-secret" "删除账号会连同该账号的 acme 状态一起清除"
    else
        fail "删除账号会连同该账号的 acme 状态一起清除"
    fi
}

test_cloudflare_menu_and_cli_are_wired() {
    local entry
    entry=$(<"$PROJECT_ROOT/src/ssl-certbot.sh")
    assert_contains "$entry" "ssl_cf_menu()" "存在 Cloudflare 账号管理菜单"
    assert_contains "$entry" "read -rs" "Token 输入不回显"
    assert_contains "$entry" "cf-add)" "命令行支持 cf-add"
    assert_contains "$entry" "cf-list)" "命令行支持 cf-list"
    assert_contains "$entry" "cf-test)" "命令行支持 cf-test"
    assert_contains "$entry" "cf-update)" "命令行支持 cf-update"
    assert_contains "$entry" "cf-remove)" "命令行支持 cf-remove"
    assert_contains "$entry" "cf-rebind)" "命令行支持 cf-rebind"
    assert_contains "$entry" "cf-menu)" "命令行支持 cf-menu"
    assert_contains "$entry" "w ssl cf-add <名称>" "帮助说明添加账号命令"
    assert_contains "$entry" "w ssl cf-list" "帮助说明账号列表命令"
    assert_contains "$entry" "w ssl cf-test <编号>" "帮助说明测试账号命令"
    assert_contains "$entry" "w ssl cf-update <编号>" "帮助说明更新 Token 命令"
    assert_contains "$entry" "w ssl cf-remove <编号>" "帮助说明删除账号命令"
    assert_contains "$entry" "w ssl cf-rebind <域名> <编号>" "帮助说明改绑命令"
    assert_contains "$entry" "dns <编号>" "帮助说明 DNS 申请用法"
}

test_uninstaller_keeps_cloudflare_account_state() {
    local uninstaller readme
    uninstaller=$(<"$PROJECT_ROOT/install/uninstall.sh")
    assert_contains "$uninstaller" "/etc/letsencrypt/ssl-certbot" "卸载器说明会保留本机配置目录"
    assert_contains "$uninstaller" "Cloudflare" "卸载器说明会保留 Cloudflare 账号"
    assert_contains "$uninstaller" "/etc/letsencrypt/live" "卸载器使用当前证书目录"
    assert_not_contains "$uninstaller" "rm -rf /root/cert" "卸载器不建议整体删除证书目录"
}

test_jq_is_only_ensured_for_dns_paths() {
    local common cloudflare installer
    common=$(<"$PROJECT_ROOT/src/common.sh")
    cloudflare=$(<"$PROJECT_ROOT/src/cloudflare.sh")
    installer=$(<"$PROJECT_ROOT/install/install.sh")
    # jq is only needed to parse Cloudflare API responses. Making it a global
    # hard dependency would break existing HTTP-only renewals on a host where
    # the package cannot be installed.
    assert_not_contains "$common" "needed=(curl openssl socat jq)" "全局依赖清单不强制要求 jq"
    assert_contains "$cloudflare" "ssl_ensure_jq" "DNS 路径按需确保 jq"
    assert_contains "$cloudflare" "ssl_ensure_jq || return 1" "jq 不可用时 DNS 测试安全失败"
    assert_not_contains "$installer" "for dep in curl openssl socat jq" "安装器不把 jq 作为强制依赖"
    assert_not_contains "$installer" "for cmd in bash curl openssl socat jq" "安装验证不强制要求 jq"
    assert_contains "$installer" "ssl cf-menu" "安装完成提示包含账号管理入口"
}

test_rebind_reissues_through_target_account() {
    local root="$TEST_TMP/cf-rebind" output calls issue_rc
    mkdir -p "$root/acme-install/dnsapi" "$root/live/api.example.com"
    # Fake acme.sh: records argv; --issue writes a NEW cert generation into
    # its own config-home store; --install-cert copies that store out. A renew
    # with no prior --issue in that home produces no new content.
    cat > "$root/acme-install/acme.sh" <<'FAKEACME'
#!/usr/bin/env bash
{ printf 'CALL'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "$ACME_ARGS_FILE"
home='' fullchain='' prev=''
for a in "$@"; do
    [ -z "$home" ] && case "$a" in */acme) home="$a";; esac
    [ "$prev" = "--fullchain-file" ] && fullchain="$a"
    prev="$a"
done
case "$*" in
    *--issue*) gen=$(( $(cat "$home/gen" 2>/dev/null || echo 0) + 1 )); printf '%s' "$gen" > "$home/gen"; printf 'gen-%s' "$gen" > "$home/cert-store" ;;
    *--install-cert*) if [[ -n "$fullchain" && -f "$home/cert-store" ]]; then mkdir -p "$(dirname "$fullchain")"; cp "$home/cert-store" "$fullchain"; printf key > "${fullchain%fullchain.pem}privkey.pem"; else exit 3; fi ;;
esac
exit 0
FAKEACME
    chmod +x "$root/acme-install/acme.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/acme-install/dnsapi/dns_cf.sh"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/acme-install"
        export ACME_ARGS_FILE="$root/acme.args"
        : > "$root/acme.args"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        ssl_install_cron_job() { :; }
        ssl_acquire_lock() { :; }
        ssl_cf_add_account main 'tok.aaa111' >/dev/null || exit 1
        ssl_cf_add_account backup 'tok.bbb222' >/dev/null || exit 1
        ssl_issue_dns_cert api.example.com 1 || exit 1
        : > "$root/acme.args"
        # Rebind to account 2: must reissue under account 2 config-home.
        ssl_cf_rebind_domain api.example.com 2 || exit 1
        [[ $(ssl_cf_account_for_domain api.example.com) == 2 ]] || exit 1
    ); then
        calls=$(<"$root/acme.args")
        assert_contains "$calls" "--issue --dns dns_cf -d api.example.com" "改绑通过目标账号重新签发"
        assert_contains "$calls" "--config-home $root/config/cloudflare/2/acme" "改绑后的签发使用目标账号的 acme 状态"
        assert_contains "$(cat "$root/live/api.example.com/fullchain.pem")" "gen-" "改绑后部署的是新签发证书"
        assert_not_contains "$output" "tok." "改绑输出不泄漏 Token"
    else
        fail "改绑通过目标账号重新签发"
    fi

    # Failure path: issuing for the target account fails, so the original
    # binding must survive untouched.
    mkdir -p "$root/empty-acme/dnsapi"
    printf '#!/usr/bin/env bash\nexit 7\n' > "$root/empty-acme/acme.sh"
    chmod +x "$root/empty-acme/acme.sh"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/empty-acme"
        export ACME_ARGS_FILE="$root/acme2.args"
        : > "$root/acme2.args"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        # current binding is account 2 from the success half
        ! ssl_cf_rebind_domain api.example.com 1 || exit 1
        [[ $(ssl_cf_account_for_domain api.example.com) == 2 ]] || exit 1
    ); then
        pass "签发失败时改绑恢复原绑定"
    else
        fail "签发失败时改绑恢复原绑定"
    fi
}

test_renew_dns_fails_when_certificate_did_not_change() {
    local root="$TEST_TMP/cf-renew-nochange" output
    mkdir -p "$root/acme-install/dnsapi" "$root/live/api.example.com"
    # This fake acme.sh does nothing on --renew (no state in this account) and
    # --install-cert merely re-copies the identical deployed bytes.
    cat > "$root/acme-install/acme.sh" <<'FAKEACME'
#!/usr/bin/env bash
exit 0
FAKEACME
    chmod +x "$root/acme-install/acme.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/acme-install/dnsapi/dns_cf.sh"
    printf 'same-old-cert' > "$root/live/api.example.com/fullchain.pem"
    printf key > "$root/live/api.example.com/privkey.pem"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_ACME_HOME="$root/acme-install"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_ensure_acme() { :; }
        ssl_cf_test_account() { :; }
        ssl_cf_add_account main 'tok.aaa111' >/dev/null || exit 1
        ssl_cf_bind_domain api.example.com 1 || exit 1
        ! ssl_renew_dns_cert api.example.com 1 || exit 1
    ); then
        assert_contains "$output" "未产生新证书" "未变更的 DNS 续期报告为失败而不是成功"
    else
        fail "未变更的 DNS 续期报告为失败而不是成功"
    fi
}

test_bad_metadata_does_not_abort_listing() {
    local root="$TEST_TMP/cf-badmeta" output
    mkdir -p "$root/live/a.example.com" "$root/live/b.example.com" "$root/config"
    printf cert > "$root/live/a.example.com/fullchain.pem"
    printf key > "$root/live/a.example.com/privkey.pem"
    printf cert > "$root/live/b.example.com/fullchain.pem"
    printf key > "$root/live/b.example.com/privkey.pem"
    printf 'SSL_CERTBOT_METHOD=bogus\n' > "$root/config/a.example.com.conf"
    if output=$(
        SSL_CERTBOT_CONFIG_DIR="$root/config"
        SSL_CERT_BASE="$root/live"
        SSL_CERTBOT_NO_MAIN=1
        source "$PROJECT_ROOT/src/ssl-certbot.sh" >/dev/null 2>&1
        exec 2>&1
        trap - EXIT INT TERM HUP
        ssl_log() { :; }
        set -e
        ssl_list_certs
        ssl_cert_status b.example.com
    ); then
        assert_contains "$output" "b.example.com" "损坏的配置不会中断其他证书的显示"
    else
        fail "损坏的配置不会中断其他证书的显示"
    fi
}

test_readme_documents_cloudflare_dns_mode() {
    local readme entry
    readme=$(<"$PROJECT_ROOT/README.md")
    entry=$(<"$PROJECT_ROOT/src/w-entry.sh")
    assert_contains "$readme" "Cloudflare DNS-01" "README 说明 DNS-01 验证"
    assert_contains "$readme" "w ssl <domain> dns" "README 说明 DNS 申请命令"
    assert_contains "$readme" "w ssl cf-add" "README 说明账号管理命令"
    assert_contains "$readme" "通配符" "README 说明通配符证书"
    assert_contains "$readme" "明文" "README 说明 Token 的保密边界"
    assert_contains "$entry" "cf-add" "入口帮助包含账号管理命令"
    assert_contains "$readme" "自动续期任务不占用 80 端口" "README 说明 DNS 续期不占用端口"
    installer=$(<"$PROJECT_ROOT/install/install.sh")
    assert_contains "$installer" "cf-add" "安装完成提示包含账号管理命令"
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

    assert_contains "$ssl_script" "6. 更新脚本" "交互菜单提供更新脚本选项"
    assert_contains "$ssl_script" "7. 卸载 ssl-certbot" "交互菜单提供卸载选项"
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

test_cf_account_state_and_binding
if bash "$PROJECT_ROOT/tests/test_certificate_menu.sh"; then
    pass '证书多选删除与合并菜单回归'
else
    fail '证书多选删除与合并菜单回归'
fi
if bash "$PROJECT_ROOT/tests/test_dns_deployment.sh"; then
    pass 'DNS 部署失败保护与改绑锁回归'
else
    fail 'DNS 部署失败保护与改绑锁回归'
fi
test_cf_security_and_dns_route
test_cf_api_does_not_expose_token_in_argv
test_dns_acme_calls_are_isolated_per_account
test_dns_acme_rejects_unsafe_log_before_execution
test_dns_renewal_requires_existing_acme_installation
test_corrupted_certificate_does_not_abort_listing
test_mixed_renewal_processes_dns_when_http_pause_fails
test_dedicated_dns_batch_renewal_does_not_touch_ports
test_dns_account_isolation_helpers
test_dns_renewal_passes_dns_hook_to_acme
test_http_mode_is_only_added_when_no_file_exists
test_cf_token_rejects_shell_and_config_metacharacters
test_account_deletion_honours_wildcard_bindings
test_removed_account_leaves_no_credential_on_disk
test_cloudflare_menu_and_cli_are_wired
test_jq_is_only_ensured_for_dns_paths
test_rebind_reissues_through_target_account
test_renew_dns_fails_when_certificate_did_not_change
test_bad_metadata_does_not_abort_listing
test_uninstaller_keeps_cloudflare_account_state
test_readme_documents_cloudflare_dns_mode
test_network_mode_persistence_and_legacy_certificate_migration
test_network_mode_rejects_invalid_values
test_interactive_network_mode_menu_writes_to_terminal
test_renewal_retry_schedule_is_documented_and_persistent
test_ipv6_dns_validation_uses_local_addresses_without_ipv4_egress_lookup
test_ipv6_local_address_filter_excludes_ula_addresses
test_ipv4_dns_validation_accepts_public_nat_address
test_ipv6_dns_validation_accepts_public_nat_address
test_dual_stack_dns_requires_matching_a_and_aaaa_records
test_issue_and_renew_reuse_saved_ipv6_listener_mode
test_renew_does_not_force_reissue
test_certificate_expiry_uses_china_standard_time_format
test_remove_certificate_removes_local_files_and_acme_record
test_remove_still_clears_local_files_when_acme_record_fails
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
