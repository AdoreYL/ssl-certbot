#!/usr/bin/env bash
# ssl-certbot cron / auto-renewal management

# ── Cron detection ──────────────────────────────────────────────────
ssl_detect_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        ssl_log WARN "crontab command not found."
        return 1
    fi

    # Check cron daemon is installed and running
    if [[ "$SSL_INIT" == "systemd" ]]; then
        if systemctl is-active cron.service >/dev/null 2>&1 || \
           systemctl is-active crond.service >/dev/null 2>&1; then
            return 0
        fi
        # Try to start it
        if systemctl start cron.service 2>/dev/null || \
           systemctl start crond.service 2>/dev/null; then
            ssl_log INFO "Started cron daemon."
            return 0
        fi
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        if rc-service crond status >/dev/null 2>&1; then
            return 0
        fi
        if rc-service crond start 2>/dev/null; then
            ssl_log INFO "Started crond daemon."
            return 0
        fi
    fi

    # Fallback: check if any cron process is running
    if pgrep -x "cron" >/dev/null 2>&1 || pgrep -x "crond" >/dev/null 2>&1; then
        return 0
    fi

    ssl_log WARN "Cron daemon does not appear to be running."
    return 1
}

# ── Ensure cron is available ────────────────────────────────────────
ssl_ensure_cron() {
    if ssl_detect_cron; then
        return 0
    fi

    ssl_log INFO "Installing cron..."
    case "$SSL_PKG" in
        apt)
            ssl_pkg_install cron
            systemctl enable cron.service 2>/dev/null || true
            systemctl start cron.service 2>/dev/null || true
            ;;
        apk)
            ssl_pkg_install busybox-openrc 2>/dev/null || true
            # Alpine uses crond from busybox or dcron
            if ! command -v crond >/dev/null 2>&1; then
                ssl_pkg_install dcron 2>/dev/null || true
            fi
            rc-update add crond default 2>/dev/null || true
            rc-service crond start 2>/dev/null || true
            ;;
    esac

    if ! ssl_detect_cron; then
        ssl_log ERROR "Failed to set up cron. Auto-renewal will not be available."
        return 1
    fi

    ssl_log INFO "Cron is now available and running."
    return 0
}

# ── Enable boot-start for cron ──────────────────────────────────────
ssl_enable_cron_boot() {
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl enable cron.service 2>/dev/null || \
        systemctl enable crond.service 2>/dev/null || true
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        rc-update add crond default 2>/dev/null || true
    fi
}

# ── Install renewal cron job ────────────────────────────────────────
ssl_install_cron_job() {
    if ! ssl_ensure_cron; then
        ssl_log ERROR "Cannot install auto-renewal: cron is not available."
        return 1
    fi

    # Check if already installed
    if crontab -l 2>/dev/null | grep -qF "$SSL_CRON_MARKER"; then
        ssl_log INFO "Auto-renewal cron job already installed."
        return 0
    fi

    # Determine the renewal script path
    local renew_script="/usr/local/lib/ssl-certbot/renew-all.sh"

    # Build cron entry: run daily at 2:30 AM (with random sleep 0-3600s)
    local cron_entry="30 2 * * * sleep \$((RANDOM \\% 3600)) && ${renew_script} $SSL_CRON_MARKER"

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
    if ssl_detect_cron; then
        echo "  Status: ${C_GREEN}Running${C_RESET}"
    else
        echo "  Status: ${C_RED}Not running${C_RESET}"
    fi

    echo ""
    echo "${C_BOLD}Auto-Renewal Job${C_RESET}"
    local job
    job=$(crontab -l 2>/dev/null | grep "$SSL_CRON_MARKER" || true)
    if [[ -n "$job" ]]; then
        echo "  Status: ${C_GREEN}Installed${C_RESET}"
        echo "  Entry:  $job"
    else
        echo "  Status: ${C_YELLOW}Not installed${C_RESET}"
    fi
    echo ""
}
