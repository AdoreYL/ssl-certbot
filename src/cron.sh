#!/usr/bin/env bash
# ssl-certbot cron / auto-renewal management

# ── Cron health checks ──────────────────────────────────────────────
ssl_cron_command_available() {
    if ! command -v crontab >/dev/null 2>&1; then
        ssl_log WARN "未找到 crontab 命令。"
        return 1
    fi
    return 0
}

ssl_cron_daemon_available() {
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl list-unit-files cron.service crond.service 2>/dev/null | grep -qE '^(cron|crond)\.service'
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        command -v crond >/dev/null 2>&1 && \
            rc-service --list 2>/dev/null | grep -qxE "(crond|dcron)"
    else
        command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1
    fi
}

ssl_cron_is_running() {
    if [[ "$SSL_INIT" == "systemd" ]]; then
        if systemctl is-active cron.service >/dev/null 2>&1 || \
           systemctl is-active crond.service >/dev/null 2>&1; then
            return 0
        fi
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        if rc-service crond status >/dev/null 2>&1 || \
           rc-service dcron status >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Fallback: check if any cron process is running
    if pgrep -x "cron" >/dev/null 2>&1 || pgrep -x "crond" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

ssl_cron_boot_enabled() {
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl is-enabled cron.service >/dev/null 2>&1 || \
        systemctl is-enabled crond.service >/dev/null 2>&1
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        rc-update show default 2>/dev/null | awk '{print $1}' | grep -qxE "(crond|dcron)"
    else
        return 1
    fi
}

ssl_cron_job_installed() {
    ssl_cron_command_available && \
        crontab -l 2>/dev/null | grep -F "$SSL_CRON_MARKER" | grep -q "renew-all\.sh"
}

ssl_start_cron() {
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl start cron.service 2>/dev/null || systemctl start crond.service 2>/dev/null
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        rc-service crond start 2>/dev/null || rc-service dcron start 2>/dev/null
    else
        return 1
    fi
}

# ── Ensure cron is available ────────────────────────────────────────
ssl_ensure_cron() {
    if ! ssl_cron_command_available || ! ssl_cron_daemon_available; then
        ssl_log INFO "正在安装 cron 服务..."
        case "$SSL_PKG" in
            apt) ssl_pkg_install cron ;;
            apk)
                ssl_pkg_install busybox-openrc 2>/dev/null || true
                if ! command -v crond >/dev/null 2>&1; then
                    ssl_pkg_install dcron
                fi
                ;;
        esac
    fi

    ssl_enable_cron_boot
    if ! ssl_cron_is_running && ! ssl_start_cron; then
        ssl_log ERROR "无法配置 cron，自动续期不可用。"
        return 1
    fi

    if ! ssl_cron_boot_enabled; then
        ssl_log WARN "cron 正在运行，但无法确认是否已设置开机启动。"
    fi

    ssl_log INFO "cron 已可用且正在运行。"
    return 0
}

# ── Enable boot-start for cron ──────────────────────────────────────
ssl_enable_cron_boot() {
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl enable cron.service 2>/dev/null || \
        systemctl enable crond.service 2>/dev/null || true
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        rc-update add crond default 2>/dev/null || \
        rc-update add dcron default 2>/dev/null || true
    fi
}

# ── Install renewal cron job ────────────────────────────────────────
ssl_install_cron_job() {
    if ! ssl_ensure_cron; then
        ssl_log ERROR "无法配置自动续期：cron 不可用。"
        return 1
    fi

    if ssl_cron_job_installed; then
        ssl_log INFO "自动续期 cron 任务已存在。"
        return 0
    fi

    # Determine the renewal script path
    local renew_script="/usr/local/lib/ssl-certbot/renew-all.sh"

    # Cron commonly runs commands with /bin/sh, so use a portable fixed schedule.
    local cron_entry="30 2 * * * ${renew_script} $SSL_CRON_MARKER"

    # Append to crontab
    (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -

    # Verify
    if crontab -l 2>/dev/null | grep -F "$SSL_CRON_MARKER" | grep -qF "$renew_script"; then
        ssl_log INFO "自动续期 cron 任务已配置。"
        ssl_enable_cron_boot
        return 0
    else
        ssl_log ERROR "配置 cron 任务失败。"
        return 1
    fi
}

# ── Show cron status ───────────────────────────────────────────────
ssl_cron_status() {
    echo ""
    echo "${C_BOLD}Cron 服务${C_RESET}"
    if ssl_cron_command_available; then
        echo "  命令：${C_GREEN}可用${C_RESET}"
    else
        echo "  命令：${C_RED}不可用${C_RESET}"
    fi
    if ssl_cron_is_running; then
        echo "  状态：${C_GREEN}运行中${C_RESET}"
    else
        echo "  状态：${C_RED}未运行${C_RESET}"
    fi
    if ssl_cron_boot_enabled; then
        echo "  开机启动：${C_GREEN}已启用${C_RESET}"
    else
        echo "  开机启动：${C_YELLOW}未确认${C_RESET}"
    fi

    echo ""
    echo "${C_BOLD}自动续期任务${C_RESET}"
    local job
    job=$(crontab -l 2>/dev/null | grep -F "$SSL_CRON_MARKER" || true)
    if [[ -n "$job" ]]; then
        echo "  状态：${C_GREEN}已配置${C_RESET}"
        echo "  任务：$job"
    else
        echo "  状态：${C_YELLOW}未配置${C_RESET}"
    fi
    echo ""
}
