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

    SSL_ACME_HOME="$acme_home"
    SSL_CERT_BASE="$cert_base"
    _ssl_log_file="$case_dir/ssl-certbot.log"
    ssl_log() { :; }
    source "$PROJECT_ROOT/src/cert.sh"

    ACME_ARGS_FILE="$args_file" ssl_renew_cert "$domain"

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
        export ACME_ARGS_FILE="$acme_args"
        ssl_log() { :; }
        ssl_validate_domain() { return 0; }
        source "$PROJECT_ROOT/src/cert.sh"
        ssl_remove_cert "$domain" yes
    ); then
        if [[ ! -d "$cert_base/$domain" ]] && grep -q -- '--remove -d example.com' "$acme_args"; then
            pass "删除证书会移除本地文件和 acme.sh 记录"
        else
            fail "删除证书会移除本地文件和 acme.sh 记录"
        fi
    else
        fail "删除证书会移除本地文件和 acme.sh 记录"
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
        ssl_log() { :; }
        ssl_validate_domain() { return 0; }
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
        _ssl_log_file="$case_dir/ssl-certbot.log"
        ssl_log() { :; }
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
        _ssl_log_file="$case_dir/ssl-certbot.log"
        ssl_log() { :; }
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

test_renew_does_not_force_reissue
test_certificate_expiry_uses_china_standard_time_format
test_remove_certificate_removes_local_files_and_acme_record
test_remove_certificate_requires_confirmation
test_docker_inspect_finds_non_wildcard_bindings
test_docker_container_name_requires_a_running_container
test_supported_listener_uses_its_actual_systemd_unit
test_unsupported_listener_is_not_matched_to_a_systemd_unit
test_process_name_without_verified_unit_is_unmanaged
test_preflight_does_not_stop_when_any_listener_is_unmanaged
test_renew_skip_does_not_pause_services
test_renew_failure_returns_nonzero
test_remote_installer_is_independent_bootstrap
test_entry_help_uses_installed_command_name

if [[ "$fail_count" -ne 0 ]]; then
    printf '%s test(s) failed; %s passed.\n' "$fail_count" "$pass_count" >&2
    exit 1
fi

printf 'All %s tests passed.\n' "$pass_count"
