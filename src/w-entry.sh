#!/usr/bin/env bash
# w - Lightweight VPS management entry point
# This file is installed as /usr/local/bin/w

set -euo pipefail

# ── Subcommand dispatch (case-insensitive) ──────────────────────────
subcmd="${1:-}"
subcmd_lower=$(echo "$subcmd" | tr '[:upper:]' '[:lower:]')

case "$subcmd_lower" in
    ssl)
        shift
        exec /usr/local/lib/ssl-certbot/ssl-certbot.sh "$@"
        ;;
    ""|help|--help|-h)
        echo ""
        echo "  w - VPS Management Tool"
        echo ""
        echo "  Usage:"
        echo "    w ssl [subcommand]    SSL certificate management"
        echo "    w help                Show this help"
        echo ""
        echo "  SSL subcommands:"
        echo "    w ssl                 Interactive menu"
        echo "    w ssl <domain>        Apply certificate for domain"
        echo "    w ssl list            List certificates"
        echo "    w ssl status          Show certificate status"
        echo "    w ssl renew           Renew certificates"
        echo "    w ssl logs            View logs"
        echo "    w ssl help            SSL help"
        echo ""
        ;;
    *)
        echo "Unknown command: $subcmd"
        echo "Run 'w help' for usage."
        exit 1
        ;;
esac
