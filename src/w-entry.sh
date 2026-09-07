#!/usr/bin/env bash
# Lightweight VPS management entry point.
# This file is installed as /usr/local/bin/w by default.

set -euo pipefail

# ── Subcommand dispatch (case-insensitive) ──────────────────────────
subcmd="${1:-}"
subcmd_lower=$(echo "$subcmd" | tr '[:upper:]' '[:lower:]')
command_name=$(basename "$0")

case "$subcmd_lower" in
    ssl)
        shift
        exec /usr/local/lib/ssl-certbot/ssl-certbot.sh "$@"
        ;;
    ""|help|--help|-h)
        echo ""
        echo "  ${command_name} - VPS 管理工具"
        echo ""
        echo "  用法："
        echo "    ${command_name} ssl [子命令]        SSL 证书管理"
        echo "    ${command_name} help                查看帮助"
        echo ""
        echo "  SSL 子命令："
        echo "    ${command_name} ssl                 打开交互式菜单"
        echo "    ${command_name} ssl <域名>          申请或续期证书"
        echo "    ${command_name} ssl list            查看证书列表"
        echo "    ${command_name} ssl status          查看证书状态"
        echo "    ${command_name} ssl renew           续期证书"
        echo "    ${command_name} ssl logs            查看日志"
        echo "    ${command_name} ssl help            SSL 帮助"
        echo ""
        ;;
    *)
        echo "未知命令：$subcmd"
        echo "执行 '${command_name} help' 查看用法。"
        exit 1
        ;;
esac
