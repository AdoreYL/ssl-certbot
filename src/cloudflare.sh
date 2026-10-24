#!/usr/bin/env bash
# Local Cloudflare credentials and per-domain account bindings.

ssl_cf_root() { printf '%s/cloudflare\n' "$SSL_CERTBOT_CONFIG_DIR"; }
ssl_cf_acme_home() { printf '%s/acme\n' "$(ssl_cf_account_dir "$1")"; }

ssl_cf_valid_id() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

# Tokens are handed to curl through a --config file, where a double quote
# would end the string and let the value inject further curl options. Only
# characters that appear in Cloudflare API tokens and Global API keys are
# accepted; the length bound keeps a mistake from filling the disk.
ssl_cf_valid_token() {
    local token="$1"
    [[ -n "$token" && ${#token} -le 2048 ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9._~/+-]+$ ]]
}

ssl_cf_valid_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* && "$1" != *'/'* && "$1" != *'\\'* ]]
}

# Credential files must be readable only by root. POSIX mode bits are only
# observable on filesystems that honour them, so the mode is checked strictly
# when the host enforces it and reduced to a symlink/type check when it does
# not (the development host here is Windows, the target hosts are Linux).
_ssl_cf_mode_cache=""

ssl_cf_mode() { stat -c %a "$1" 2>/dev/null || printf '700\n'; }

ssl_cf_modes_enforced() {
    if [[ -z "$_ssl_cf_mode_cache" ]]; then
        local probe dir_probe mode dir_mode
        probe=$(mktemp "${SSL_CERTBOT_CONFIG_DIR}/.mode-probe.XXXXXX" 2>/dev/null || true)
        dir_probe=$(mktemp -d "${SSL_CERTBOT_CONFIG_DIR}/.mode-probe-dir.XXXXXX" 2>/dev/null || true)
        if [[ -z "$probe" || -z "$dir_probe" ]]; then
            _ssl_cf_mode_cache=yes
        else
            chmod 600 "$probe" 2>/dev/null || true
            chmod 700 "$dir_probe" 2>/dev/null || true
            mode=$(stat -c %a "$probe" 2>/dev/null || printf '600')
            dir_mode=$(stat -c %a "$dir_probe" 2>/dev/null || printf '700')
            if [[ "$mode" == 600 && "$dir_mode" == 700 ]]; then
                _ssl_cf_mode_cache=yes
            else
                _ssl_cf_mode_cache=no
            fi
        fi
        if [[ -n "$probe" ]]; then
            rm -f "$probe" 2>/dev/null || true
        fi
        if [[ -n "$dir_probe" ]]; then
            rmdir "$dir_probe" 2>/dev/null || true
        fi
    fi
    if [[ "$_ssl_cf_mode_cache" == yes ]]; then
        return 0
    fi
    return 1
}

ssl_cf_private_dir() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] || return 1
    if ssl_cf_modes_enforced; then
        [[ "$(ssl_cf_mode "$path")" == 700 ]] || return 1
    fi
    return 0
}

ssl_cf_private_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    if ssl_cf_modes_enforced; then
        [[ "$(ssl_cf_mode "$path")" == 600 ]] || return 1
    fi
    return 0
}

ssl_cf_init() {
    local root
    root=$(ssl_cf_root)
    if [[ -L "$SSL_CERTBOT_CONFIG_DIR" || -L "$root" ]]; then
        ssl_log ERROR '账号配置目录不能是符号链接。'
        return 1
    fi
    mkdir -p -m 700 "$SSL_CERTBOT_CONFIG_DIR" || return 1
    mkdir -p -m 700 "$root" || return 1
    chmod 700 "$SSL_CERTBOT_CONFIG_DIR" "$root" 2>/dev/null || true
    ssl_cf_private_dir "$SSL_CERTBOT_CONFIG_DIR" || { ssl_log ERROR '账号配置目录权限不安全。'; return 1; }
    ssl_cf_private_dir "$root" || { ssl_log ERROR 'Cloudflare 目录权限不安全。'; return 1; }
    if ! ssl_cf_modes_enforced; then
        ssl_log WARN '当前文件系统不强制执行权限位，请在 Linux 主机上使用本工具保存 Token。'
    fi
    return 0
}

ssl_cf_write() {
    local path="$1" value="$2" tmp
    [[ ! -L "$path" ]] || return 1
    if [[ -e "$path" ]]; then
        ssl_cf_private_file "$path" || return 1
    fi
    tmp=$(mktemp "${path}.XXXXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if ! printf '%s\n' "$value" > "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    chmod 600 "$path" 2>/dev/null || true
    ssl_cf_private_file "$path"
}

ssl_cf_account_dir() { printf '%s/%s\n' "$(ssl_cf_root)" "$1"; }

ssl_cf_account_ready() {
    local id="$1" dir
    ssl_cf_valid_id "$id" || return 1
    ssl_cf_private_dir "$SSL_CERTBOT_CONFIG_DIR" || return 1
    ssl_cf_private_dir "$(ssl_cf_root)" || return 1
    dir=$(ssl_cf_account_dir "$id")
    ssl_cf_private_dir "$dir" && ssl_cf_private_file "$dir/token" && ssl_cf_private_file "$dir/name"
}

ssl_cf_add_account() {
    local name="$1" token="$2" root next id dir
    ssl_cf_valid_name "$name" && ssl_cf_valid_token "$token" || return 1
    ssl_cf_init || return 1
    root=$(ssl_cf_root)
    next="$root/next-id"
    if [[ -e "$next" ]]; then
        ssl_cf_private_file "$next" || return 1
        id=$(<"$next")
        ssl_cf_valid_id "$id" || return 1
    else
        id=1
    fi
    dir=$(ssl_cf_account_dir "$id")
    [[ ! -e "$dir" && ! -L "$dir" ]] || return 1
    mkdir -p -m 700 "$dir" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    if ! ssl_cf_write "$dir/name" "$name" || ! ssl_cf_write "$dir/token" "$token" || ! ssl_cf_write "$next" "$((id + 1))"; then
        rm -f "$dir/name" "$dir/token"
        rmdir "$dir" 2>/dev/null || true
        return 1
    fi
    ssl_log INFO "已保存 Cloudflare 账号编号：$id（$name）。"
}

ssl_cf_list_accounts() {
    local dir id name
    [[ -d "$(ssl_cf_root)" ]] || return 0
    ssl_cf_private_dir "$(ssl_cf_root)" || return 1
    for dir in "$(ssl_cf_root)"/*/; do
        [[ -d "$dir" ]] || continue
        id=$(basename "$dir")
        ssl_cf_account_ready "$id" || return 1
        name=$(<"$dir/name")
        ssl_cf_valid_name "$name" || return 1
        printf '%s\t%s\n' "$id" "$name"
    done
}

ssl_cf_update_account() {
    local id="$1" token="$2" dir
    ssl_cf_valid_token "$token" || return 1
    ssl_cf_account_ready "$id" || return 1
    dir=$(ssl_cf_account_dir "$id")
    ssl_cf_write "$dir/token" "$token" || return 1
    # A rotated Token must not leave the old value anywhere acme.sh could read.
    ssl_cf_prepare_acme "$id"
}

ssl_cf_token() {
    local id="$1" token
    ssl_cf_account_ready "$id" || { ssl_log ERROR "Cloudflare 账号 $id 不存在或权限不安全。"; return 1; }
    token=$(<"$(ssl_cf_account_dir "$id")/token")
    # Re-check on read so a hand-edited or truncated file cannot reach curl.
    ssl_cf_valid_token "$token" || return 1
    printf '%s' "$token"
}

ssl_cf_prepare_acme() {
    local id="$1" home
    ssl_cf_account_ready "$id" || return 1
    home=$(ssl_cf_acme_home "$id")
    if [[ -e "$home" || -L "$home" ]]; then
        ssl_cf_private_dir "$home" || return 1
    else
        mkdir -p -m 700 "$home" || return 1
        chmod 700 "$home" 2>/dev/null || true
    fi
    # dns_cf persists credentials in account.conf; a rotated Token must never
    # fall back to a stale value if an environment variable becomes empty.
    local conf="$home/account.conf"
    if [[ -e "$conf" || -L "$conf" ]]; then
        ssl_cf_private_file "$conf" || return 1
        # acme.sh writes both plain and quoted forms; a stale value of any of
        # these keys would let one account borrow another account's identity.
        sed -i -E '/^(SAVED_)?CF_(Token|Key|Email|Account_ID|Zone_ID)=/d' "$conf" || return 1
        chmod 600 "$conf" 2>/dev/null || true
    fi
    local domain_conf
    for domain_conf in "$home"/*/*.conf; do
        [[ -e "$domain_conf" ]] || continue
        ssl_cf_private_file "$domain_conf" || return 1
        sed -i -E '/^(SAVED_)?CF_(Token|Key|Email|Account_ID|Zone_ID)=/d' "$domain_conf" || return 1
        chmod 600 "$domain_conf" 2>/dev/null || true
    done
}

ssl_ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    ssl_log INFO "正在安装 jq..."
    ssl_pkg_install jq
}

# Only the zone owning the requested name is eligible; do not infer an account
# from DNS records. The actual TXT write capability is checked by dns_cf during issuance.
ssl_cf_test_account() {
    local id="$1" domain="${2:-}" token zone name result
    ssl_ensure_jq || return 1
    token=$(ssl_cf_token "$id") || return 1
    if ! result=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS --connect-timeout 5 --max-time 15 \
        --config - 'https://api.cloudflare.com/client/v4/user/tokens/verify' 2>/dev/null) || \
        [[ $(printf '%s' "$result" | jq -r '.success == true and .result.status == "active"' 2>/dev/null) != true ]]; then
        ssl_log ERROR "Cloudflare 账号 $id 的 Token 验证失败。"
        return 1
    fi
    [[ -z "$domain" ]] && return 0
    ssl_validate_dns_domain "$domain" || return 1
    name="${domain#\*.}"
    while [[ "$name" == *.* ]]; do
        if ! result=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -fsS --connect-timeout 5 --max-time 15 -G \
            --config - --data-urlencode "name=$name" \
            'https://api.cloudflare.com/client/v4/zones' 2>/dev/null); then
            ssl_log ERROR "Cloudflare 账号 $id 无法查询域名所属 Zone。"
            return 1
        fi
        zone=$(printf '%s' "$result" | jq -r --arg name "$name" \
            'if .success == true then [.result[] | select(.name == $name and .status == "active") | .id][0] // empty else empty end' 2>/dev/null) || return 1
        [[ -n "$zone" ]] && return 0
        name="${name#*.}"
    done
    ssl_log ERROR "账号 $id 无法访问 $domain 所属的 Cloudflare Zone。"
    return 1
}

ssl_cf_account_for_domain() {
    local domain="$1" file id
    ssl_validate_dns_domain "$domain" >/dev/null 2>&1 || return 1
    file="$(ssl_network_mode_file "$domain")"
    [[ -e "$file" || -L "$file" ]] || return 0
    ssl_cf_private_file "$file" || return 1
    id=$(sed -n 's/^SSL_CERTBOT_CF_ACCOUNT=//p' "$file" | head -n 1)
    [[ -z "$id" ]] || ssl_cf_valid_id "$id" || return 1
    printf '%s' "$id"
}

ssl_validation_method() {
    local domain="$1" file method
    ssl_validate_dns_domain "$domain" >/dev/null 2>&1 || return 1
    file="$(ssl_network_mode_file "$domain")"
    [[ -e "$file" || -L "$file" ]] || { printf 'http\n'; return 0; }
    ssl_cf_private_file "$file" || return 1
    method=$(sed -n 's/^SSL_CERTBOT_METHOD=//p' "$file" | head -n 1)
    case "$method" in
        ''|http) printf 'http\n' ;;
        dns) printf 'dns\n' ;;
        *) return 1 ;;
    esac
}

ssl_cf_bind_domain() {
    local domain="$1" id="$2" force="${3:-}" file existing
    ssl_validate_dns_domain "$domain" && ssl_cf_account_ready "$id" || return 1
    file=$(ssl_network_mode_file "$domain")
    [[ ! -e "$file" && ! -L "$file" ]] || {
        ssl_cf_private_file "$file" || return 1
        # An existing config file that still describes HTTP-01 must not be
        # converted by binding; the domain has no DNS-01 acme state yet.
        [[ "$(ssl_validation_method "$domain")" == dns ]] || return 1
        existing=$(ssl_cf_account_for_domain "$domain") || return 1
        # Switching to a different account is only allowed through an explicit
        # rebind (force), never by re-running the apply command.
        [[ "$force" == force || -z "$existing" || "$existing" == "$id" ]] || return 1
    }
    ssl_cf_write "$file" "$(printf 'SSL_CERTBOT_METHOD=dns\nSSL_CERTBOT_CF_ACCOUNT=%s' "$id")"
}

ssl_cf_rebind_domain() {
    local domain="$1" id="$2"
    # Only an existing DNS-01 certificate can be rebound; HTTP certs use the
    # separate apply flow.
    [[ "$(ssl_validation_method "$domain")" == dns ]] || { ssl_log ERROR "$domain 不是 DNS-01 证书，无需改绑。"; return 1; }
    ssl_cf_account_ready "$id" || { ssl_log ERROR "Cloudflare 账号 $id 不存在或权限不安全。"; return 1; }
    ssl_cf_test_account "$id" "$domain" || return 1
    # Reissuing through the target account is mandatory: its acme config-home
    # has no record of this domain yet, so a bare re-bind would leave every
    # future auto-renewal failing until the certificate expires.
    ssl_issue_dns_cert "$domain" "$id" force
}

ssl_cf_bound_domains_for_account() {
    local id="$1" file domain bound found=0
    ssl_cf_valid_id "$id" || return 1
    for file in "$SSL_CERTBOT_CONFIG_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        domain=$(ssl_slug_to_domain "$(basename "$file" .conf)")
        bound=$(ssl_cf_account_for_domain "$domain") || return 1
        [[ "$bound" == "$id" ]] || continue
        if [[ "$found" -eq 0 ]]; then
            printf '%s' "$domain"
            found=1
        else
            printf ',%s' "$domain"
        fi
    done
    printf '\n'
}

ssl_cf_remove_account() {
    local id="$1" dir file domain bound
    ssl_cf_account_ready "$id" || return 1
    for file in "$SSL_CERTBOT_CONFIG_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        domain=$(ssl_slug_to_domain "$(basename "$file" .conf)")
        bound=$(ssl_cf_account_for_domain "$domain") || return 1
        if [[ "$bound" == "$id" ]]; then
            ssl_log ERROR "账号 $id 仍绑定域名 $domain，不可删除。"
            return 1
        fi
    done
    # The account's own acme state holds the credential dns_cf persisted during
    # issuance (SAVED_CF_Token) plus that account's ACME key. Removing only
    # token/name would leave the secret behind, so the whole account directory
    # goes; $id is validated above as a bare positive integer and dir is
    # verified to be a real (non-symlink) directory owned by this account.
    dir=$(ssl_cf_account_dir "$id")
    rm -rf -- "$dir"
    [[ ! -e "$dir" ]] || { ssl_log ERROR "无法删除账号 $id 的本机凭据目录。"; return 1; }
    ssl_log INFO "已删除 Cloudflare 账号 $id 的本机凭据与其 acme.sh 状态。"
}
