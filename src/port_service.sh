#!/usr/bin/env bash
# ssl-certbot port detection and service management

# Returns lines: PID PROCESS PORT PROTO
ssl_detect_port_listeners() {
    local port="$1"
    local results=""

    if command -v ss >/dev/null 2>&1; then
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
            NR > 1 { print $2, $1, '"$port"', "tcp" }
        ' 2>/dev/null || true)
    else
        ssl_die "未找到端口检测工具（需要 ss、netstat 或 lsof）。"
    fi

    [[ -z "$results" ]] || echo "$results" | sort -u -k1,1
}

ssl_is_port_free() {
    [[ -z "$(ssl_detect_port_listeners "$1")" ]]
}

# Process names are not reliable service ownership. Return a unit only when
# /proc/<PID>/cgroup proves that this listener belongs to a known systemd unit.
# Output: systemd:unit.service, docker-proxy:PID, or an empty string.
ssl_identify_service() {
    local pid="$1"
    local pname="$2"
    local unit svc

    if [[ "$SSL_INIT" == "systemd" && -r "/proc/$pid/cgroup" ]]; then
        while IFS= read -r unit; do
            unit="${unit##*/}"
            for svc in "${SSL_KNOWN_SERVICES[@]}"; do
                if [[ "$unit" == "${svc}.service" ]]; then
                    echo "systemd:$unit"
                    return 0
                fi
            done
        done < <(grep -oE '[^/]+\.service' "/proc/$pid/cgroup" 2>/dev/null | sort -u)
    fi

    if [[ "${pname,,}" == "docker-proxy" ]] && command -v docker >/dev/null 2>&1; then
        echo "docker-proxy:$pid"
        return 0
    fi

    echo ""
}

# Output running containers that publish the requested host port. It is used
# only after a docker-proxy listener was observed for that same port.
ssl_detect_docker_containers_for_port() {
    local requested_port="$1"

    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | while read -r cid cname; do
        [[ -z "$cid" ]] && continue
        docker inspect --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{.HostIp}} {{.HostPort}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null | \
            while read -r host_ip host_port; do
                [[ "$host_port" == "$requested_port" ]] && echo "$cid $cname $requested_port"
            done
    done
}

# A read-only helper retained for diagnostics and regression tests.
ssl_detect_docker_containers() {
    local port result=""
    for port in 80 443; do
        result+="$(ssl_detect_docker_containers_for_port "$port")"$'\n'
    done
    printf '%s' "$result" | sed '/^$/d'
}

SSL_PAUSED_FILE=""

ssl_init_state() {
    mkdir -p "$SSL_STATE_DIR"
    SSL_PAUSED_FILE="$SSL_STATE_DIR/paused.state"
    : > "$SSL_PAUSED_FILE"
}

# State format: manager:identifier:details
ssl_record_paused() {
    echo "$1:$2:$3" >> "$SSL_PAUSED_FILE"
}

ssl_stop_service() {
    local manager="$1"
    local unit="$2"
    ssl_log INFO "正在停止服务：$unit"

    case "$manager" in
        systemd) systemctl stop "$unit" ;;
        openrc) rc-service "$unit" stop ;;
        *)
            ssl_log ERROR "无法停止服务 $unit：未知的服务管理器。"
            return 1
            ;;
    esac
}

ssl_start_service() {
    local manager="$1"
    local unit="$2"
    ssl_log INFO "正在恢复服务：$unit"

    case "$manager" in
        systemd) systemctl start "$unit" ;;
        openrc) rc-service "$unit" start ;;
        *)
            ssl_log ERROR "无法恢复服务 $unit：未知的服务管理器。"
            return 1
            ;;
    esac
}

ssl_stop_docker_container() {
    local cid="$1"
    ssl_log INFO "正在停止 Docker 容器：$cid"
    docker stop "$cid" --time 10
}

ssl_start_docker_container() {
    local cid="$1"
    ssl_log INFO "正在恢复 Docker 容器：$cid"
    docker start "$cid"
}

ssl_report_unmanaged_listener() {
    local port="$1"
    local pid="$2"
    local pname="$3"

    ssl_log ERROR "TCP $port 被无法安全自动管理的进程占用。"
    ssl_log ERROR "PID：$pid，进程：$pname"
    ssl_log INFO "未确认其对应的 systemd/OpenRC 服务，工具不会强制停止该进程。"
    ssl_log INFO "请手动停止该服务后重新执行，或将其配置为受支持的服务单元。"
}

# Build a complete pause plan before stopping anything. Every listener must be
# a verified systemd unit or an observed Docker bridge listener with a matching
# running container. Otherwise no service is interrupted.
ssl_pause_port_services() {
    ssl_init_state

    local -a pause_plan=()
    local port listeners pid pname lport proto service_id identifier
    local has_unmanaged=0

    for port in 80 443; do
        listeners=$(ssl_detect_port_listeners "$port")
        if [[ -z "$listeners" ]]; then
            ssl_log INFO "端口 $port 空闲。"
            continue
        fi

        while read -r pid pname lport proto; do
            [[ -z "$pid" ]] && continue
            service_id=$(ssl_identify_service "$pid" "$pname")

            if [[ "$service_id" == docker-proxy:* ]]; then
                local docker_containers
                docker_containers=$(ssl_detect_docker_containers_for_port "$port")
                if [[ -z "$docker_containers" ]]; then
                    ssl_report_unmanaged_listener "$port" "$pid" "$pname"
                    has_unmanaged=1
                    continue
                fi
                while read -r identifier pname lport; do
                    [[ -z "$identifier" ]] && continue
                    pause_plan+=("docker:$identifier:$pname:$port")
                done <<< "$docker_containers"
            elif [[ "$service_id" == systemd:* ]]; then
                pause_plan+=("$service_id:$port")
            else
                ssl_report_unmanaged_listener "$port" "$pid" "$pname"
                has_unmanaged=1
            fi
        done <<< "$listeners"
    done

    if [[ "$has_unmanaged" -ne 0 ]]; then
        ssl_log ERROR "端口预检查失败：不会暂停任何服务。"
        return 1
    fi

    local entry entry_type first second third
    for entry in "${pause_plan[@]}"; do
        IFS=: read -r entry_type first second third <<< "$entry"
        case "$entry_type" in
            systemd)
                grep -qF "systemd:$first:" "$SSL_PAUSED_FILE" 2>/dev/null && continue
                if ! ssl_stop_service systemd "$first"; then
                    ssl_log ERROR "停止服务失败：$first"
                    ssl_restore_services
                    return 1
                fi
                ssl_record_paused systemd "$first" "$second"
                ;;
            docker)
                grep -qF "docker:$first:" "$SSL_PAUSED_FILE" 2>/dev/null && continue
                if ! ssl_stop_docker_container "$first"; then
                    ssl_log ERROR "停止 Docker 容器失败：$second ($first)"
                    ssl_restore_services
                    return 1
                fi
                ssl_record_paused docker "$first" "$second:$third"
                ;;
        esac
    done

    sleep 1
    for port in 80 443; do
        if ! ssl_is_port_free "$port"; then
            ssl_log ERROR "停止已识别服务后，端口 $port 仍被占用。"
            ssl_restore_services
            return 1
        fi
    done

    ssl_log INFO "端口 80 和 443 已释放。"
    return 0
}

ssl_restore_services() {
    if [[ ! -f "$SSL_PAUSED_FILE" ]] || [[ ! -s "$SSL_PAUSED_FILE" ]]; then
        ssl_log INFO "没有需要恢复的服务。"
        return 0
    fi

    ssl_log INFO "正在恢复本次暂停的服务..."
    local any_failed=0 line entry_type identifier details

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS=: read -r entry_type identifier details <<< "$line"

        case "$entry_type" in
            systemd|openrc)
                if ssl_start_service "$entry_type" "$identifier"; then
                    ssl_log INFO "已恢复服务：$identifier"
                else
                    ssl_log ERROR "恢复服务失败：$identifier"
                    any_failed=1
                fi
                ;;
            docker)
                if ssl_start_docker_container "$identifier"; then
                    ssl_log INFO "已恢复 Docker 容器：$details ($identifier)"
                else
                    ssl_log ERROR "恢复 Docker 容器失败：$details ($identifier)"
                    any_failed=1
                fi
                ;;
        esac
    done < "$SSL_PAUSED_FILE"

    : > "$SSL_PAUSED_FILE"

    if [[ "$any_failed" -ne 0 ]]; then
        ssl_log WARN "部分服务未能恢复，请手动检查。"
        return 1
    fi

    ssl_log INFO "所有已暂停服务均已恢复。"
    return 0
}
