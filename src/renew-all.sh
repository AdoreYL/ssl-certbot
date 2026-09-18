#!/usr/bin/env bash
# ssl-certbot automatic renewal script
# Called by cron to renew all managed certificates
# Uses the same port-handling logic as initial issuance

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/ssl-certbot"

# Source all modules
# shellcheck source=common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=port_service.sh
source "${LIB_DIR}/port_service.sh"
# shellcheck source=cert.sh
source "${LIB_DIR}/cert.sh"

readonly RENEW_MODE="${1:-baseline}"
readonly RENEW_MAX_RETRIES=6

renew_retry_count() {
    if [[ -f "$SSL_RENEW_RETRY_STATE" ]]; then
        local count
        count="$(cat "$SSL_RENEW_RETRY_STATE" 2>/dev/null || true)"
        if [[ "$count" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$count"
            return 0
        fi
    fi
    printf '0\n'
}

renew_save_retry_count() {
    mkdir -p "$(dirname "$SSL_RENEW_RETRY_STATE")"
    printf '%s\n' "$1" > "$SSL_RENEW_RETRY_STATE"
}

renew_clear_retry_state() {
    rm -f "$SSL_RENEW_RETRY_STATE"
}

renew_retry_state_exists() {
    [[ -f "$SSL_RENEW_RETRY_STATE" ]]
}

renew_should_run() {
    local retry_count
    retry_count="$(renew_retry_count)"

    if [[ "$RENEW_MODE" == "baseline" && ! -f "$SSL_RENEW_RETRY_STATE" ]]; then
        return 0
    fi
    # All three slots are eight hours apart, including the next day's 02:30
    # slot. Once a failure exists, every slot participates in the retry loop.
    if [[ -f "$SSL_RENEW_RETRY_STATE" && "$retry_count" -lt "$RENEW_MAX_RETRIES" ]]; then
        return 0
    fi
    ssl_log INFO "当前续期时段无需执行，跳过。"
    return 1
}

# ── Trap for cleanup ───────────────────────────────────────────────
_renew_cleanup() {
    ssl_log INFO "正在清理自动续期流程..."
    ssl_restore_services
    ssl_release_lock
}
trap _renew_cleanup EXIT INT TERM HUP

# ── Main ────────────────────────────────────────────────────────────
main() {
    ssl_init_log
    ssl_log INFO "=== 自动续期开始 ==="
    ssl_detect_os

    # Acquire lock
    ssl_acquire_lock

    if ! renew_should_run; then
        exit 0
    fi

    if ssl_renew_managed_certificates; then
        renew_clear_retry_state
        ssl_log INFO "=== 自动续期成功结束 ==="
        exit 0
    fi

    local retry_count
    retry_count="$(renew_retry_count)"
    if renew_retry_state_exists; then
        retry_count=$((retry_count + 1))
    fi
    if [[ "$retry_count" -ge "$RENEW_MAX_RETRIES" ]]; then
        renew_clear_retry_state
        ssl_log ERROR "已完成 ${RENEW_MAX_RETRIES} 轮 8 小时重试，下一次恢复为每天 02:30 执行。"
    else
        renew_save_retry_count "$retry_count"
        ssl_log WARN "自动续期失败，将在下一个 8 小时续期时段再次尝试（已完成第 ${retry_count} 轮）。"
    fi
    ssl_log ERROR "=== 自动续期结束，存在失败项 ==="
    exit 1
}

main "$@"
