#!/usr/bin/env bash
# ssl-certbot common utilities
# Shared constants, logging, and helper functions

set -euo pipefail
umask 077

# ── Constants ───────────────────────────────────────────────────────
readonly SSL_CERT_BASE="/root/cert"
readonly SSL_LOG_PRIMARY="/var/log/ssl-certbot.log"
readonly SSL_LOG_FALLBACK="/root/.ssl-certbot/logs/ssl-certbot.log"
readonly SSL_STATE_DIR="/run/ssl-certbot"
readonly SSL_LOCK_FILE="/run/ssl-certbot.lock"
readonly SSL_ACME_HOME="/root/.acme.sh"
readonly SSL_CRON_MARKER="# ssl-certbot auto-renew"
readonly SSL_PROJECT_TAG="ssl-certbot"
readonly SSL_W_BIN="/usr/local/bin/w"

# Supported listener process names. The actual systemd unit is resolved from
# the listener PID's cgroup at runtime and is never derived from this list.
readonly -a SSL_SUPPORTED_LISTENER_PROCESSES=(
    "nginx" "caddy" "apache2" "httpd" "haproxy" "traefik" "openresty" "x-ui" "3x-ui"
)

# ── Colour helpers (disabled when not a tty) ────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''
    C_CYAN=''; C_BOLD=''; C_RESET=''
fi

# ── Logging ─────────────────────────────────────────────────────────
_ssl_log_file=""

ssl_init_log() {
    if [[ -w "$(dirname "$SSL_LOG_PRIMARY")" ]]; then
        _ssl_log_file="$SSL_LOG_PRIMARY"
    else
        mkdir -p "$(dirname "$SSL_LOG_FALLBACK")"
        _ssl_log_file="$SSL_LOG_FALLBACK"
    fi
}

ssl_log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$ts] [$level] $*"
    if [[ -n "$_ssl_log_file" ]]; then
        echo "$msg" >> "$_ssl_log_file"
    fi
    case "$level" in
        ERROR)   echo "${C_RED}${C_BOLD}[错误]${C_RESET} $*" >&2 ;;
        WARN)    echo "${C_YELLOW}[警告]${C_RESET} $*" >&2 ;;
        INFO)    echo "${C_GREEN}[信息]${C_RESET} $*" ;;
        DEBUG)   ;; # silent unless VERBOSE
    esac
}

ssl_die() {
    ssl_log ERROR "$@"
    exit 1
}

# ── Root check ──────────────────────────────────────────────────────
ssl_require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        ssl_die "必须以 root 权限运行此工具。"
    fi
}

# ── OS detection ────────────────────────────────────────────────────
SSL_OS=""        # debian | ubuntu | alpine
SSL_OS_VER=""    # e.g. 12, 22.04, 3.19
SSL_INIT=""      # systemd | openrc | unknown
SSL_PKG=""       # apt | apk

ssl_detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        ssl_die "无法识别操作系统：未找到 /etc/os-release。"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID:-}" in
        debian)
            SSL_OS="debian"
            SSL_OS_VER="${VERSION_ID:-unknown}"
            SSL_PKG="apt"
            ;;
        ubuntu)
            SSL_OS="ubuntu"
            SSL_OS_VER="${VERSION_ID:-unknown}"
            SSL_PKG="apt"
            ;;
        alpine)
            SSL_OS="alpine"
            SSL_OS_VER="${VERSION_ID:-unknown}"
            SSL_PKG="apk"
            ;;
        *)
            ssl_die "不支持的操作系统：${ID:-unknown}。仅支持 Debian、Ubuntu 和 Alpine Linux。"
            ;;
    esac

    # Init system
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        SSL_INIT="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        SSL_INIT="openrc"
    else
        SSL_INIT="unknown"
    fi

    ssl_log INFO "识别到系统：$SSL_OS $SSL_OS_VER，初始化系统：$SSL_INIT，包管理器：$SSL_PKG"
}

# ── Package helpers ─────────────────────────────────────────────────
ssl_pkg_installed() {
    local pkg="$1"
    case "$SSL_PKG" in
        apt) dpkg -s "$pkg" >/dev/null 2>&1 ;;
        apk) apk info -e "$pkg" >/dev/null 2>&1 ;;
    esac
}

ssl_pkg_install() {
    local pkg="$1"
    if ssl_pkg_installed "$pkg"; then
        ssl_log INFO "依赖已安装：$pkg"
        return 0
    fi
    ssl_log INFO "正在安装依赖：$pkg"
    case "$SSL_PKG" in
        apt) apt-get update -qq && apt-get install -y -qq "$pkg" ;;
        apk) apk add --no-cache "$pkg" ;;
    esac
}

# ── Dependency bootstrap ───────────────────────────────────────────
ssl_ensure_deps() {
    # Bash itself (Alpine)
    if [[ "$SSL_OS" == "alpine" ]] && ! command -v bash >/dev/null 2>&1; then
        ssl_pkg_install bash
    fi

    local -a needed=(curl openssl socat)
    for dep in "${needed[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            ssl_pkg_install "$dep"
        fi
    done

    # Port detection: need at least one of ss, netstat, lsof
    if ! command -v ss >/dev/null 2>&1 \
       && ! command -v netstat >/dev/null 2>&1 \
       && ! command -v lsof >/dev/null 2>&1; then
        ssl_log WARN "未找到端口检测工具，正在安装 iproute2/net-tools..."
        case "$SSL_PKG" in
            apt) ssl_pkg_install iproute2 ;;
            apk) ssl_pkg_install iproute2 ;;
        esac
        if ! command -v ss >/dev/null 2>&1; then
            ssl_die "无法安装端口检测工具（ss/netstat/lsof），请手动安装。"
        fi
    fi

    # flock for concurrency
    if ! command -v flock >/dev/null 2>&1; then
        case "$SSL_PKG" in
            apt) ssl_pkg_install util-linux ;;
            apk) ssl_pkg_install util-linux ;;
        esac
    fi

    ssl_log INFO "所有依赖均已满足。"
}

# ── acme.sh install ────────────────────────────────────────────────
ssl_ensure_acme() {
    if [[ -f "$SSL_ACME_HOME/acme.sh" ]]; then
        ssl_log INFO "acme.sh 已安装：$SSL_ACME_HOME"
        return 0
    fi
    ssl_log INFO "正在安装 acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s -- email=ssl-certbot@localhost
    if [[ ! -f "$SSL_ACME_HOME/acme.sh" ]]; then
        ssl_die "acme.sh 安装失败。"
    fi
    "$SSL_ACME_HOME/acme.sh" --uninstall-cronjob >/dev/null 2>&1 || \
        ssl_log WARN "未能移除 acme.sh 自带的 cron 任务，请手动检查 crontab。"
    # Default CA = Let's Encrypt
    "$SSL_ACME_HOME/acme.sh" --set-default-ca --server letsencrypt 2>/dev/null || true
    ssl_log INFO "acme.sh 安装完成。"
}

# ── Domain validation ──────────────────────────────────────────────
ssl_validate_domain() {
    local domain="$1"

    # No leading/trailing whitespace
    if [[ "$domain" != "$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]]; then
        ssl_log ERROR "域名前后不能包含空白字符。"
        return 1
    fi

    # No internal whitespace
    if [[ "$domain" =~ [[:space:]] ]]; then
        ssl_log ERROR "域名不能包含空白字符。"
        return 1
    fi

    # No wildcard
    if [[ "$domain" == *'*'* ]]; then
        ssl_log ERROR "暂不支持通配符域名。"
        return 1
    fi

    # No URL schemes
    if [[ "$domain" =~ ^https?:// ]]; then
        ssl_log ERROR "请输入域名，不要输入 URL（请去掉 https:// 或 http://）。"
        return 1
    fi

    # No path
    if [[ "$domain" == */* ]]; then
        ssl_log ERROR "域名不能包含路径。"
        return 1
    fi

    # No port
    if [[ "$domain" == *:* ]]; then
        ssl_log ERROR "域名不能包含端口号。"
        return 1
    fi

    # No IP addresses
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ssl_log ERROR "不支持申请 IP 地址证书，请使用域名。"
        return 1
    fi

    # RFC-compliant label check: letters, digits, hyphens; no leading/trailing hyphens
    local label IFS_SAVE="$IFS"
    IFS='.'
    for label in $domain; do
        if [[ -z "$label" ]]; then
            ssl_log ERROR "域名包含空标签（连续的点）。"
            IFS="$IFS_SAVE"
            return 1
        fi
        if [[ ${#label} -gt 63 ]]; then
            ssl_log ERROR "域名标签 '$label' 超过 63 个字符。"
            IFS="$IFS_SAVE"
            return 1
        fi
        if ! [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            ssl_log ERROR "无效的域名标签：'$label'。标签必须以字母或数字开头和结尾，且只能包含字母、数字和连字符。"
            IFS="$IFS_SAVE"
            return 1
        fi
    done
    IFS="$IFS_SAVE"

    # At least two labels (e.g. example.com)
    local dot_count
    dot_count=$(echo "$domain" | tr -cd '.' | wc -c)
    if [[ "$dot_count" -lt 1 ]]; then
        ssl_log ERROR "域名至少需要两级，例如 example.com。"
        return 1
    fi

    # Total length
    if [[ ${#domain} -gt 253 ]]; then
        ssl_log ERROR "域名长度超过 253 个字符。"
        return 1
    fi

    return 0
}

# ── Concurrency lock ───────────────────────────────────────────────
SSL_LOCK_FD=""

ssl_acquire_lock() {
    mkdir -p "$(dirname "$SSL_LOCK_FILE")"
    exec 9>"$SSL_LOCK_FILE"
    SSL_LOCK_FD=9
    if ! flock -n 9; then
        ssl_die "已有 ssl-certbot 进程正在运行。如确认不是，请删除 $SSL_LOCK_FILE 后重试。"
    fi
    ssl_log INFO "已获取进程锁。"
}

ssl_release_lock() {
    if [[ -n "$SSL_LOCK_FD" ]]; then
        flock -u 9 2>/dev/null || true
        SSL_LOCK_FD=""
    fi
}
