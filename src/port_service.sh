#!/usr/bin/env bash
# ssl-certbot port detection and service management
# Handles: port scanning, service identification, pause/resume

# ── Port detection ──────────────────────────────────────────────────
# Returns lines: PID PROCESS PORT PROTO
# e.g. "1234 nginx 80 tcp"
ssl_detect_port_listeners() {
    local port="$1"
    local results=""

    if command -v ss >/dev/null 2>&1; then
        # ss -tlnp: extract PIDs from lines matching the port
        results=$(ss -tlnp 2>/dev/null | grep -E "[:.](${port})[[:space:]]" | \
            grep -oE 'pid=[0-9]+' | sed 's/pid=//' | sort -u | while read -r pid; do
                local pname
                pname=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
                echo "$pid $pname $port tcp"
            done 2>/dev/null || true)
    elif command -v netstat >/dev/null 2>&1; then
        results=$(netstat -tlnp 2>/dev/null | awk -v p=":${port}$" '
            $4 ~ p {
                split($7, a, "/")
                if (a[1] != "" && a[1] != "-") {
                    print a[1], a[2], '"$port"', "tcp"
                }
            }
        ' 2>/dev/null || true)
    elif command -v lsof >/dev/null 2>&1; then
        results=$(lsof -i "TCP:${port}" -s TCP:LISTEN -n -P 2>/dev/null | awk '
            NR > 1 {
                print $2, $1, '"$port"', "tcp"
            }
        ' 2>/dev/null || true)
    else
        ssl_die "No port detection tool available (ss, netstat, or lsof required)."
    fi

    # Deduplicate by PID
    if [[ -n "$results" ]]; then
        echo "$results" | sort -u -k1,1
    fi
}

# Check if a specific port is free
ssl_is_port_free() {
    local port="$1"
    local listeners
    listeners=$(ssl_detect_port_listeners "$port")
    [[ -z "$listeners" ]]
}

# ── Service identification ──────────────────────────────────────────
# Given a PID, determine if it belongs to a known service
# Returns: "systemd:nginx" or "openrc:nginx" or "docker:CONTAINER_ID:name" or ""
ssl_identify_service() {
    local pid="$1"
    local pname="$2"

    # Normalize process name to lowercase
    local pname_lower
    pname_lower=$(echo "$pname" | tr '[:upper:]' '[:lower:]')

    # Check known system services
    for svc in "${SSL_KNOWN_SERVICES[@]}"; do
        if [[ "$pname_lower" == "$svc" ]] || [[ "$pname_lower" == "${svc}.service" ]]; then
            # Verify it's managed by init system
            if [[ "$SSL_INIT" == "systemd" ]]; then
                local unit="${svc}.service"
                if systemctl list-units --type=service --all 2>/dev/null | grep -q "$unit"; then
                    echo "systemd:$svc"
                    return 0
                fi
            elif [[ "$SSL_INIT" == "openrc" ]]; then
                if rc-service --list 2>/dev/null | grep -q "^${svc}$"; then
                    echo "openrc:$svc"
                    return 0
                fi
            fi
            # Even without init management, we recognize the process
            echo "process:$svc"
            return 0
        fi
    done

    # Check if PID belongs to a Docker container's proxy
    if [[ "$pname_lower" == "docker-proxy" ]] && command -v docker >/dev/null 2>&1; then
        echo "docker-proxy:$pid"
        return 0
    fi

    # Unknown
    echo ""
}

# ── Docker container detection ──────────────────────────────────────
# Find Docker containers with host port mappings for 80 or 443
# Output: CONTAINER_ID CONTAINER_NAME PORT
ssl_detect_docker_containers() {
    if ! command -v docker >/dev/null 2>&1; then
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        return 0
    fi

    # List running containers with port mappings
    docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' 2>/dev/null | while read -r cid cname ports; do
        # Check for host port 80 mapping
        if echo "$ports" | grep -qE '0\.0\.0\.0:80->|:::80->'; then
            echo "$cid $cname 80"
        fi
        # Check for host port 443 mapping
        if echo "$ports" | grep -qE '0\.0\.0\.0:443->|:::443->'; then
            echo "$cid $cname 443"
        fi
    done
}

# ── State recording ─────────────────────────────────────────────────
# Records what was paused so we can restore it
SSL_PAUSED_FILE=""

ssl_init_state() {
    mkdir -p "$SSL_STATE_DIR"
    SSL_PAUSED_FILE="$SSL_STATE_DIR/paused.state"
    : > "$SSL_PAUSED_FILE"
}

ssl_record_paused() {
    # type:identifier:ports:stop_cmd:start_cmd
    echo "$*" >> "$SSL_PAUSED_FILE"
}

# ── Service pause ───────────────────────────────────────────────────
ssl_stop_service() {
    local svc="$1"
    ssl_log INFO "Stopping service: $svc"
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl stop "${svc}.service"
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        rc-service "$svc" stop
    else
        ssl_log WARN "Unknown init system; attempting generic stop for $svc"
        if command -v service >/dev/null 2>&1; then
            service "$svc" stop
        else
            ssl_log ERROR "Cannot stop service $svc: no service manager found."
            return 1
        fi
    fi
}

ssl_start_service() {
    local svc="$1"
    ssl_log INFO "Starting service: $svc"
    if [[ "$SSL_INIT" == "systemd" ]]; then
        systemctl start "${svc}.service"
    elif [[ "$SSL_INIT" == "openrc" ]]; then
        rc-service "$svc" start
    else
        if command -v service >/dev/null 2>&1; then
            service "$svc" start
        else
            ssl_log ERROR "Cannot start service $svc: no service manager found."
            return 1
        fi
    fi
}

ssl_stop_docker_container() {
    local cid="$1"
    ssl_log INFO "Stopping Docker container: $cid"
    docker stop "$cid" --time 10
}

ssl_start_docker_container() {
    local cid="$1"
    ssl_log INFO "Starting Docker container: $cid"
    docker start "$cid"
}

# ── Main pause/resume orchestration ────────────────────────────────
# Pause all services/containers occupying ports 80 and 443
# Returns 0 on success, 1 if unknown processes block the ports
ssl_pause_port_services() {
    ssl_init_state

    local has_unknown=0
    local port

    for port in 80 443; do
        local listeners
        listeners=$(ssl_detect_port_listeners "$port")

        if [[ -z "$listeners" ]]; then
            ssl_log INFO "Port $port is free."
            continue
        fi

        while read -r pid pname lport proto; do
            [[ -z "$pid" ]] && continue

            local svc_id
            svc_id=$(ssl_identify_service "$pid" "$pname")

            if [[ -z "$svc_id" ]]; then
                # Unknown process
                ssl_log ERROR "TCP $port is occupied by an unknown process:"
                ssl_log ERROR "  PID: $pid"
                ssl_log ERROR "  Process: $pname"
                has_unknown=1
                continue
            fi

            local svc_type svc_name
            svc_type="${svc_id%%:*}"
            svc_name="${svc_id#*:}"

            case "$svc_type" in
                systemd|openrc|process)
                    # Check if already recorded (avoid duplicate stops)
                    if grep -q "^service:${svc_name}:" "$SSL_PAUSED_FILE" 2>/dev/null; then
                        continue
                    fi
                    ssl_stop_service "$svc_name"
                    ssl_record_paused "service:${svc_name}:${port}:stop:start"
                    ;;
                docker-proxy)
                    ;; # Handled via docker container detection below
            esac
        done <<< "$listeners"
    done

    # Handle Docker containers separately for clean identification
    local docker_containers
    docker_containers=$(ssl_detect_docker_containers)
    if [[ -n "$docker_containers" ]]; then
        while read -r cid cname cport; do
            [[ -z "$cid" ]] && continue
            if grep -q "^docker:${cid}:" "$SSL_PAUSED_FILE" 2>/dev/null; then
                continue
            fi
            ssl_stop_docker_container "$cid"
            ssl_record_paused "docker:${cid}:${cname}:${cport}"
        done <<< "$docker_containers"
    fi

    if [[ "$has_unknown" -eq 1 ]]; then
        ssl_log ERROR "Cannot proceed: unknown processes occupy required ports."
        ssl_log ERROR "Please stop them manually and retry."
        # Restore what we already stopped
        ssl_restore_services
        return 1
    fi

    # Verify ports are now free
    sleep 1
    for port in 80 443; do
        if ! ssl_is_port_free "$port"; then
            ssl_log ERROR "Port $port is still occupied after stopping known services."
            ssl_restore_services
            return 1
        fi
    done

    ssl_log INFO "Ports 80 and 443 are now free."
    return 0
}

# ── Restore all paused services ────────────────────────────────────
ssl_restore_services() {
    if [[ ! -f "$SSL_PAUSED_FILE" ]] || [[ ! -s "$SSL_PAUSED_FILE" ]]; then
        ssl_log INFO "No services to restore."
        return 0
    fi

    ssl_log INFO "Restoring previously paused services..."
    local any_failed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local entry_type
        entry_type="${line%%:*}"

        case "$entry_type" in
            service)
                local svc_name
                svc_name=$(echo "$line" | cut -d: -f2)
                if ssl_start_service "$svc_name"; then
                    ssl_log INFO "Restored service: $svc_name"
                else
                    ssl_log ERROR "Failed to restore service: $svc_name"
                    any_failed=1
                fi
                ;;
            docker)
                local cid cname
                cid=$(echo "$line" | cut -d: -f2)
                cname=$(echo "$line" | cut -d: -f3)
                if ssl_start_docker_container "$cid"; then
                    ssl_log INFO "Restored Docker container: $cname ($cid)"
                else
                    ssl_log ERROR "Failed to restore Docker container: $cname ($cid)"
                    any_failed=1
                fi
                ;;
        esac
    done < "$SSL_PAUSED_FILE"

    # Clear state file
    : > "$SSL_PAUSED_FILE"

    if [[ "$any_failed" -eq 1 ]]; then
        ssl_log WARN "Some services could not be restored. Please check manually."
        return 1
    fi

    ssl_log INFO "All services restored successfully."
    return 0
}
