#!/usr/bin/env bash
# ssl-certbot cron / auto-renewal management

# ── Cron health checks ──────────────────────────────────────────────
ssl_cron_command_available() {
    if ! command -v crontab >/dev/null 2>&1; then
        ssl_log WARN "crontab command not found."
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
        ssl_log INFO "Installing cron daemon..."
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
        ssl_log ERROR "Failed to set up cron. Auto-renewal will not be available."
        return 1
    fi

    if ! ssl_cron_boot_enabled; then
        ssl_log WARN "Cron is running, but automatic startup could not be verified."
    fi

    ssl_log INFO "Cron is available and running."
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
        ssl_log ERROR "Cannot install auto-renewal: cron is not available."
        return 1
    fi

    if ssl_cron_job_installed; then
        ssl_log INFO "Auto-renewal cron job already installed."
        return 0
    fi

    # Determine the renewal script path
    local renew_script="/usr/local/lib/ssl-certbot/renew-all.sh"

    # Cron commonly runs commands with /bin/sh, so use a portable fixed schedule.
    local cron_entry="30 2 * * * ${renew_script} $SSL_CRON_MARKER"

    # Append to crontab
    (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab -

    # Verify
    if crontab -l 2>/dev/null | grep -qF "$SSL_CRON_MARKER"; then
        ssl_log INFO "Auto-renewal cron job installed successfully."
        ssl_enable_cron_boot
        return 0
    else
        ssl_log ERROR "Failed to install cron job."
        return 1
    fi
}

# ── Show cron status ───────────────────────────────────────────────
ssl_cron_status() {
    echo ""
    echo "${C_BOLD}Cron Daemon${C_RESET}"
    if ssl_cron_command_available; then
        echo "  Command: ${C_GREEN}Available${C_RESET}"
    else
        echo "  Command: ${C_RED}Unavailable${C_RESET}"
    fi
    if ssl_cron_is_running; then
        echo "  Status: ${C_GREEN}Running${C_RESET}"
    else
        echo "  Status: ${C_RED}Not running${C_RESET}"
    fi
    if ssl_cron_boot_enabled; then
        echo "  Boot:   ${C_GREEN}Enabled${C_RESET}"
    else
        echo "  Boot:   ${C_YELLOW}Not verified${C_RESET}"
    fi

    echo ""
    echo "${C_BOLD}Auto-Renewal Job${C_RESET}"
    local job
    job=$(crontab -l 2>/dev/null | grep -F "$SSL_CRON_MARKER" || true)
    if [[ -n "$job" ]]; then
        echo "  Status: ${C_GREEN}Installed${C_RESET}"
        echo "  Entry:  $job"
    else
        echo "  Status: ${C_YELLOW}Not installed${C_RESET}"
    fi
    echo ""
}
