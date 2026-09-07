#!/usr/bin/env bash
# Remote bootstrap installer for ssl-certbot.

set -euo pipefail
umask 077

readonly REPOSITORY="AdoreYL/ssl-certbot"
readonly BRANCH="main"
readonly ARCHIVE_URL="https://github.com/${REPOSITORY}/archive/refs/heads/${BRANCH}.tar.gz"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "[错误] 必须以 root 权限运行安装器。" >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "[错误] 无法识别操作系统：未找到 /etc/os-release。" >&2
    exit 1
fi
. /etc/os-release

case "${ID:-}" in
    debian|ubuntu) package_manager="apt" ;;
    alpine) package_manager="apk" ;;
    *)
        echo "[错误] 不支持的操作系统：${ID:-unknown}。仅支持 Debian、Ubuntu 和 Alpine。" >&2
        exit 1
        ;;
esac

ensure_bootstrap_dependency() {
    local command="$1"
    local package="$2"
    command -v "$command" >/dev/null 2>&1 && return 0

    echo "[信息] 正在安装引导依赖：$package"
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
echo "[信息] 正在从 ${REPOSITORY}/${BRANCH} 下载 ssl-certbot..."
curl -fsSL "$ARCHIVE_URL" -o "$archive_path"
tar -xzf "$archive_path" -C "$temp_dir"

project_dir="$temp_dir/ssl-certbot-${BRANCH}"
if [[ ! -f "$project_dir/install/install.sh" ]]; then
    echo "[错误] 下载的压缩包中未包含 install/install.sh。" >&2
    exit 1
fi

bash "$project_dir/install/install.sh"
