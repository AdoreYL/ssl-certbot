#!/usr/bin/env bash
# ssl-certbot uninstaller

set -euo pipefail

readonly INSTALL_LIB_DIR="/usr/local/lib/ssl-certbot"
readonly PROJECT_TAG="ssl-certbot"
readonly SSL_CRON_MARKER="# ssl-certbot auto-renew"

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BOLD=''; C_RESET=''
fi

info()  { echo "${C_GREEN}[信息]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[警告]${C_RESET} $*" >&2; }
error() { echo "${C_RED}${C_BOLD}[错误]${C_RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
    die "必须以 root 权限运行卸载器。"
fi

echo ""
echo "${C_BOLD}ssl-certbot 卸载器${C_RESET}"
echo "────────────────────────────────────────"
echo ""
echo "将删除："
echo "  - ${INSTALL_LIB_DIR}"
echo "  - /usr/local/bin/ 中带 ssl-certbot 标记的命令（若存在）"
echo "  - 自动续期 cron 任务"
echo ""
echo "不会删除："
echo "  - /root/cert/ 中已有的证书"
echo "  - /root/.acme.sh/ 中的 acme.sh 安装"
echo "  - 日志文件"
echo ""
read -rp "继续吗？[y/N]：" confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "已取消。"
    exit 0
fi

# Remove cron job
if crontab -l 2>/dev/null | grep -qF "$SSL_CRON_MARKER"; then
    info "正在删除自动续期 cron 任务..."
    crontab -l 2>/dev/null | grep -vF "$SSL_CRON_MARKER" | crontab -
    info "cron 任务已删除。"
fi

# Remove library
if [[ -d "$INSTALL_LIB_DIR" ]]; then
    info "正在删除 ${INSTALL_LIB_DIR}..."
    rm -rf "$INSTALL_LIB_DIR"
    info "程序目录已删除。"
fi

# Remove any tagged commands without touching other tools. This also covers
# custom command names supplied through SSL_CERTBOT_BIN at installation time.
for command_bin in /usr/local/bin/*; do
    [[ -f "$command_bin" ]] || continue
    if grep -qF "$PROJECT_TAG" "$command_bin" 2>/dev/null; then
        info "正在删除 ${command_bin}..."
        rm -f "$command_bin"
    fi
done

# Clean up runtime state
rm -rf /run/ssl-certbot 2>/dev/null || true
rm -f /run/ssl-certbot.lock 2>/dev/null || true

echo ""
echo "${C_GREEN}${C_BOLD}卸载完成。${C_RESET}"
echo ""
echo "  已保留 /root/cert/ 中的证书。"
echo "  如需手动删除证书：rm -rf /root/cert/"
echo "  如需删除 acme.sh：rm -rf /root/.acme.sh/"
echo ""
