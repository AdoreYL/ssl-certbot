#!/usr/bin/env bash
# ssl-certbot installer
# Installs the lightweight SSL certificate manager on Debian/Ubuntu/Alpine

set -euo pipefail
umask 077

readonly INSTALL_LIB_DIR="/usr/local/lib/ssl-certbot"
readonly INSTALL_W_BIN="/usr/local/bin/w"
readonly PROJECT_TAG="ssl-certbot"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR="${SCRIPT_DIR}/../src"

# ── Colours ─────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''
    C_CYAN=''; C_BOLD=''; C_RESET=''
fi

info()  { echo "${C_GREEN}[INFO]${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
error() { echo "${C_RED}${C_BOLD}[ERROR]${C_RESET} $*" >&2; }
die()   { error "$@"; exit 1; }

# ── Root check ──────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    die "This installer must be run as root."
fi

# ── OS detection ────────────────────────────────────────────────────
if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release not found."
fi
# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu) PKG="apt" ;;
    alpine)        PKG="apk" ;;
    *) die "Unsupported OS: ${ID:-unknown}. This tool supports Debian, Ubuntu, and Alpine Linux." ;;
esac

info "Detected OS: ${ID} ${VERSION_ID:-} (package manager: ${PKG})"

# ── Source files check ──────────────────────────────────────────────
for f in common.sh port_service.sh cert.sh cron.sh ssl-certbot.sh w-entry.sh renew-all.sh; do
    if [[ ! -f "${SRC_DIR}/${f}" ]]; then
        die "Missing source file: ${SRC_DIR}/${f}"
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
        info "Already installed: $1"
        return 0
    fi
    info "Installing: $1"
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
info "Installing ssl-certbot to ${INSTALL_LIB_DIR}..."
mkdir -p "$INSTALL_LIB_DIR"

for f in common.sh port_service.sh cert.sh cron.sh ssl-certbot.sh renew-all.sh; do
    cp -f "${SRC_DIR}/${f}" "${INSTALL_LIB_DIR}/${f}"
    chmod 755 "${INSTALL_LIB_DIR}/${f}"
done

# ── Install w command ──────────────────────────────────────────────
install_w_command() {
    if [[ -f "$INSTALL_W_BIN" ]]; then
        # Check if it belongs to this project
        if grep -qF "$PROJECT_TAG" "$INSTALL_W_BIN" 2>/dev/null; then
            info "Updating existing w command (belongs to $PROJECT_TAG)."
        else
            warn ""
            warn "  /usr/local/bin/w already exists and belongs to another program."
            warn "  File content preview:"
            head -5 "$INSTALL_W_BIN" 2>/dev/null | sed 's/^/    /' >&2
            warn ""
            read -rp "  Overwrite /usr/local/bin/w? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[yY]$ ]]; then
                warn "Skipping w command installation."
                warn "You can still run: /usr/local/lib/ssl-certbot/ssl-certbot.sh"
                return 0
            fi
        fi
    fi

    # Write w entry script with project tag embedded
    cp -f "${SRC_DIR}/w-entry.sh" "$INSTALL_W_BIN"
    # Inject project tag as a comment for ownership detection
    sed -i "2a\\# $PROJECT_TAG" "$INSTALL_W_BIN" 2>/dev/null || \
        sed -i '' "2a\\
# $PROJECT_TAG" "$INSTALL_W_BIN" 2>/dev/null || true
    chmod 755 "$INSTALL_W_BIN"
    info "Installed: $INSTALL_W_BIN"
}

install_w_command

# ── Verify installation ────────────────────────────────────────────
info "Verifying installation..."

verify_ok=1

if [[ ! -x "${INSTALL_LIB_DIR}/ssl-certbot.sh" ]]; then
    error "ssl-certbot.sh not executable."
    verify_ok=0
fi

if [[ -x "$INSTALL_W_BIN" ]]; then
    info "w command: OK"
else
    warn "w command not installed (may be skipped due to conflict)."
fi

for cmd in bash curl openssl socat; do
    if command -v "$cmd" >/dev/null 2>&1; then
        info "$cmd: OK"
    else
        error "$cmd: NOT FOUND"
        verify_ok=0
    fi
done

if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
    info "Port detection tool: OK"
else
    error "No port detection tool available."
    verify_ok=0
fi

if command -v flock >/dev/null 2>&1; then
    info "flock: OK"
else
    warn "flock not available; directory-based locking will be used."
fi

if [[ "$verify_ok" -eq 0 ]]; then
    die "Installation verification failed. Please check errors above."
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "${C_GREEN}${C_BOLD}Installation complete!${C_RESET}"
echo "────────────────────────────────────────"
echo ""
echo "  Usage:"
echo "    w ssl                 Interactive SSL menu"
echo "    w ssl example.com     Apply certificate for a domain"
echo "    w ssl list            List managed certificates"
echo "    w ssl status          Show certificate status"
echo "    w ssl renew           Renew certificates"
echo "    w ssl help            Show help"
echo ""
echo "  Library: ${INSTALL_LIB_DIR}"
if [[ -x "$INSTALL_W_BIN" ]]; then
echo "  Command: ${INSTALL_W_BIN}"
fi
echo ""
echo "  ${C_YELLOW}Note:${C_RESET} acme.sh will be installed automatically on first use"
echo "  if not already present."
echo ""
