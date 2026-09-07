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

info()  { echo "${C_GREEN}[INFO]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
error() { echo "${C_RED}${C_BOLD}[ERROR]${C_RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
    die "This uninstaller must be run as root."
fi

echo ""
echo "${C_BOLD}ssl-certbot Uninstaller${C_RESET}"
echo "────────────────────────────────────────"
echo ""
echo "This will remove:"
echo "  - ${INSTALL_LIB_DIR}"
echo "  - Any tagged ssl-certbot command in /usr/local/bin/ (if present)"
echo "  - Auto-renewal cron job"
echo ""
echo "This will NOT remove:"
echo "  - Existing certificates in /root/cert/"
echo "  - acme.sh installation in /root/.acme.sh/"
echo "  - Log files"
echo ""
read -rp "Proceed? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Remove cron job
if crontab -l 2>/dev/null | grep -qF "$SSL_CRON_MARKER"; then
    info "Removing auto-renewal cron job..."
    crontab -l 2>/dev/null | grep -vF "$SSL_CRON_MARKER" | crontab -
    info "Cron job removed."
fi

# Remove library
if [[ -d "$INSTALL_LIB_DIR" ]]; then
    info "Removing ${INSTALL_LIB_DIR}..."
    rm -rf "$INSTALL_LIB_DIR"
    info "Library removed."
fi

# Remove any tagged commands without touching other tools. This also covers
# custom command names supplied through SSL_CERTBOT_BIN at installation time.
for command_bin in /usr/local/bin/*; do
    [[ -f "$command_bin" ]] || continue
    if grep -qF "$PROJECT_TAG" "$command_bin" 2>/dev/null; then
        info "Removing ${command_bin}..."
        rm -f "$command_bin"
    fi
done

# Clean up runtime state
rm -rf /run/ssl-certbot 2>/dev/null || true
rm -f /run/ssl-certbot.lock 2>/dev/null || true

echo ""
echo "${C_GREEN}${C_BOLD}Uninstallation complete.${C_RESET}"
echo ""
echo "  Certificates in /root/cert/ have been preserved."
echo "  To remove them manually: rm -rf /root/cert/"
echo "  To remove acme.sh: rm -rf /root/.acme.sh/"
echo ""
