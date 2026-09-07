#!/usr/bin/env bash
# Remote bootstrap installer for ssl-certbot.

set -euo pipefail
umask 077

readonly REPOSITORY="AdoreYL/ssl-certbot"
readonly BRANCH="main"
readonly ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/refs/heads/${BRANCH}.tar.gz"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "[ERROR] This installer must be run as root." >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "[ERROR] Cannot detect OS: /etc/os-release not found." >&2
    exit 1
fi
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu) package_manager="apt" ;;
    alpine) package_manager="apk" ;;
    *)
        echo "[ERROR] Unsupported OS: ${ID:-unknown}. Debian, Ubuntu, and Alpine are supported." >&2
        exit 1
        ;;
esac

ensure_bootstrap_dependency() {
    local command="$1"
    local package="$2"
    command -v "$command" >/dev/null 2>&1 && return 0

    echo "[INFO] Installing bootstrap dependency: $package"
    case "$package_manager" in
        apt)
            apt-get update -qq
            apt-get install -y -qq "$package"
            ;;
        apk) apk add --no-cache "$package" ;;
    esac
}

ensure_bootstrap_dependency curl curl
ensure_bootstrap_dependency tar tar

temp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT INT TERM HUP

archive_path="$temp_dir/ssl-certbot.tar.gz"
echo "[INFO] Downloading ssl-certbot from ${REPOSITORY}/${BRANCH}..."
curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
tar -xzf "$archive_path" -C "$temp_dir"

project_dir="$temp_dir/ssl-certbot-${BRANCH}"
if [[ ! -f "$project_dir/install/install.sh" ]]; then
    echo "[ERROR] Downloaded archive does not contain install/install.sh." >&2
    exit 1
fi

bash "$project_dir/install/install.sh"
