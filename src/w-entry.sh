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
        echo "  ${command_name} - VPS Management Tool"
        echo ""
        echo "  Usage:"
        echo "    ${command_name} ssl [subcommand]    SSL certificate management"
        echo "    ${command_name} help                Show this help"
        echo ""
        echo "  SSL subcommands:"
        echo "    ${command_name} ssl                 Interactive menu"
        echo "    ${command_name} ssl <domain>        Apply certificate for domain"
        echo "    ${command_name} ssl list            List certificates"
        echo "    ${command_name} ssl status          Show certificate status"
        echo "    ${command_name} ssl renew           Renew certificates"
        echo "    ${command_name} ssl logs            View logs"
        echo "    ${command_name} ssl help            SSL help"
        echo ""
        ;;
    *)
        echo "Unknown command: $subcmd"
        echo "Run '${command_name} help' for usage."
        exit 1
        ;;
esac
