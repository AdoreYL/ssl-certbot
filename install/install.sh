#!/usr/bin/env bash
# ssl-certbot installer
# Installs the lightweight SSL certificate manager on Debian/Ubuntu/Alpine

set -euo pipefail
umask 077

readonly INSTALL_LIB_DIR="/usr/local/lib/ssl-certbot"
readonly PROJECT_TAG="ssl-certbot"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="${SCRIPT_DIR}/../src"

INSTALL_COMMAND_NAME="${SSL_CERTBOT_BIN:-w}"
if [[ ! "$INSTALL_COMMAND_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    echo "[错误] SSL_CERTBOT_BIN 必须是只包含字母、数字、_ 或 - 的命令名。" >&2
    exit 1
fi
INSTALL_COMMAND_BIN="/usr/local/bin/${INSTALL_COMMAND_NAME}"

# ── Colours ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''
    C_CYAN=''; C_BOLD=''; C_RESET=''
fi

info()  { echo "${C_GREEN}[信息]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[警告]${C_RESET} $*" >&2; }
error() { echo "${C_RED}${C_BOLD}[错误]${C_RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Root check ──────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    die "必须以 root 权限运行安装器。"
fi

# ── OS detection ────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
    die "无法识别操作系统：未找到 /etc/os-release。"
fi
# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu) PKG="apt" ;;
    alpine)        PKG="apk" ;;
    *) die "不支持的操作系统：${ID:-unknown}。仅支持 Debian、Ubuntu 和 Alpine Linux。" ;;
esac

info "识别到系统：${ID} ${VERSION_ID:-}（包管理器：${PKG}）"

# ── Source files check ──────────────────────────────────────────────
for f in common.sh port_service.sh cert.sh cron.sh ssl-certbot.sh w-entry.sh renew-all.sh; do
    if [[ ! -f "${SRC_DIR}/${f}" ]]; then
        die "缺少源文件：${SRC_DIR}/${f}"
    fi
done

# ── Install dependencies ───────────────────────────────────────────
pkg_installed() {
    case "$PKG" in
        apt) dpkg -s "$1" >/dev/null 2>&1 ;;
        apk) apk info -e "$1" >/dev/null 2>&1 ;;
    esac
}

pkg_install() {
    if pkg_installed "$1"; then
        info "依赖已安装：$1"
        return 0
    fi
    info "正在安装：$1"
    case "$PKG" in
        apt) apt-get update -qq && apt-get install -y -qq "$1" ;;
        apk) apk add --no-cache "$1" ;;
    esac
}

# Bash (Alpine may not have it)
if [[ "$PKG" == "apk" ]] && ! command -v bash >/dev/null 2>&1; then
    pkg_install bash
fi

# Core deps
for dep in curl openssl socat; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        pkg_install "$dep"
    fi
done

# Port detection
if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
    pkg_install iproute2
fi

# flock
if ! command -v flock >/dev/null 2>&1; then
    pkg_install util-linux
fi

# ── Install library files ──────────────────────────────────────────
info "正在将 ssl-certbot 安装到 ${INSTALL_LIB_DIR}..."
mkdir -p "$INSTALL_LIB_DIR"

for f in common.sh port_service.sh cert.sh cron.sh ssl-certbot.sh renew-all.sh; do
    cp -f "${SRC_DIR}/${f}" "${INSTALL_LIB_DIR}/${f}"
    chmod 755 "${INSTALL_LIB_DIR}/${f}"
done

cp -f "${SCRIPT_DIR}/uninstall.sh" "${INSTALL_LIB_DIR}/uninstall.sh"
chmod 755 "${INSTALL_LIB_DIR}/uninstall.sh"

# ── Install w command ──────────────────────────────────────────────
install_w_command() {
    if [[ -f "$INSTALL_COMMAND_BIN" ]]; then
        # Check if it belongs to this project
        if grep -qF "$PROJECT_TAG" "$INSTALL_COMMAND_BIN" 2>/dev/null; then
            info "正在更新已有的 ${INSTALL_COMMAND_NAME} 命令（属于 $PROJECT_TAG）。"
        else
            warn ""
            warn "  ${INSTALL_COMMAND_BIN} 已存在，且属于其他程序。"
            warn "  文件内容预览："
            head -5 "$INSTALL_COMMAND_BIN" 2>/dev/null | sed 's/^/    /' >&2
            warn ""
            read -rp "  覆盖 ${INSTALL_COMMAND_BIN} 吗？[y/N]：" confirm
            if [[ ! "$confirm" =~ ^[yY]$ ]]; then
                if [[ "$INSTALL_COMMAND_NAME" == "w" ]]; then
                    INSTALL_COMMAND_NAME="sslcert"
                    INSTALL_COMMAND_BIN="/usr/local/bin/${INSTALL_COMMAND_NAME}"
                    warn "正在安装备用命令：${INSTALL_COMMAND_BIN}"
                    if [[ -f "$INSTALL_COMMAND_BIN" ]] && ! grep -qF "$PROJECT_TAG" "$INSTALL_COMMAND_BIN" 2>/dev/null; then
                        warn "${INSTALL_COMMAND_BIN} 也已被占用，跳过命令安装。"
                        warn "仍可执行：/usr/local/lib/ssl-certbot/ssl-certbot.sh"
                        return 0
                    fi
                else
                    warn "跳过 ${INSTALL_COMMAND_NAME} 命令安装。"
                    warn "仍可执行：/usr/local/lib/ssl-certbot/ssl-certbot.sh"
                    return 0
                fi
            fi
        fi
    fi

    # Write w entry script with project tag embedded
    cp -f "${SRC_DIR}/w-entry.sh" "$INSTALL_COMMAND_BIN"
    # Inject project tag as a comment for ownership detection
    sed -i "2a\\# $PROJECT_TAG" "$INSTALL_COMMAND_BIN" 2>/dev/null || \
        sed -i '' "2a\\
# $PROJECT_TAG" "$INSTALL_COMMAND_BIN" 2>/dev/null || true
    chmod 755 "$INSTALL_COMMAND_BIN"
    info "已安装：$INSTALL_COMMAND_BIN"
}

install_w_command

# ── Verify installation ────────────────────────────────────────────
info "正在验证安装..."

verify_ok=1

if [[ ! -x "${INSTALL_LIB_DIR}/ssl-certbot.sh" ]]; then
    error "ssl-certbot.sh 不可执行。"
    verify_ok=0
fi

if [[ -x "$INSTALL_COMMAND_BIN" ]]; then
    info "${INSTALL_COMMAND_NAME} 命令：正常"
else
    warn "${INSTALL_COMMAND_NAME} 命令未安装（可能因冲突而跳过）。"
fi

for cmd in bash curl openssl socat; do
    if command -v "$cmd" >/dev/null 2>&1; then
        info "$cmd：正常"
    else
        error "$cmd：未找到"
        verify_ok=0
    fi
done

if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
    info "端口检测工具：正常"
else
    error "没有可用的端口检测工具。"
    verify_ok=0
fi

if command -v flock >/dev/null 2>&1; then
    info "flock：正常"
else
    warn "flock 不可用，将使用基于目录的锁。"
fi

if [[ "$verify_ok" -eq 0 ]]; then
    die "安装验证失败，请检查上方错误。"
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "${C_GREEN}${C_BOLD}安装完成！${C_RESET}"
echo "────────────────────────────────────────"
echo ""
echo "  用法："
echo "    ${INSTALL_COMMAND_NAME} ssl                 打开 SSL 交互式菜单"
echo "    ${INSTALL_COMMAND_NAME} ssl example.com     为域名申请证书"
echo "    ${INSTALL_COMMAND_NAME} ssl list            查看已管理的证书"
echo "    ${INSTALL_COMMAND_NAME} ssl status          查看证书状态"
echo "    ${INSTALL_COMMAND_NAME} ssl renew           续期证书"
echo "    ${INSTALL_COMMAND_NAME} ssl remove <域名>   删除本地证书"
echo "    ${INSTALL_COMMAND_NAME} ssl uninstall       卸载 ssl-certbot"
echo "    ${INSTALL_COMMAND_NAME} ssl help            查看帮助"
echo ""
echo "  程序目录：${INSTALL_LIB_DIR}"
if [[ -x "$INSTALL_COMMAND_BIN" ]]; then
echo "  命令：${INSTALL_COMMAND_BIN}"
fi
echo ""
echo "  ${C_YELLOW}提示：${C_RESET} 若 acme.sh 尚未安装，将在首次使用时自动安装。"
echo "  证书变更不会自动重载 Web 或代理服务。"
echo ""
