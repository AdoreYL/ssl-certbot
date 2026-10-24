#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export SSL_CERT_BASE="$TEST_TMP/live"
export SSL_CERTBOT_CONFIG_DIR="$TEST_TMP/config"
SSL_CERTBOT_NO_MAIN=1
source "$PROJECT_ROOT/src/ssl-certbot.sh"
trap - EXIT INT TERM HUP
trap 'rm -rf "$TEST_TMP"' EXIT
ssl_log() { printf '%s\n' "$*"; }
ssl_acquire_lock() { :; }
mkdir -p "$SSL_CERT_BASE/a.example.com" "$SSL_CERT_BASE/b.example.com" "$SSL_CERT_BASE/_wildcard_example.com"
touch "$SSL_CERT_BASE/a.example.com/fullchain.pem" "$SSL_CERT_BASE/b.example.com/fullchain.pem" "$SSL_CERT_BASE/_wildcard_example.com/fullchain.pem"
calls="$TEST_TMP/deleted"
ssl_remove_cert() { printf '%s\n' "$1" >> "$calls"; [[ "$1" != "${fail_domain:-}" ]]; }
check() { if ! "$@"; then echo "FAIL: $*"; exit 1; fi; }

if ! ssl_cmd_remove <<< $'1 3 1\nyes' > "$TEST_TMP/output"; then
    echo 'FAIL: multi-selection is not accepted'; exit 1
fi
check test "$(cat "$calls")" = $'*.example.com\nb.example.com'
echo 'PASS: multi-select deletes only selected domains and deduplicates'
: > "$calls"
ssl_cmd_remove <<< $'all\nyes' > "$TEST_TMP/output"
check test "$(wc -l < "$calls" | tr -d ' ')" = 3
echo 'PASS: all selects every listed certificate'
for input in $'1 99\nyes' $'1 ../../bad\nyes' $'1 9999999999999999999999999\nyes' $'1\nno' '' ; do
    : > "$calls"
    if ssl_cmd_remove <<< "$input" > "$TEST_TMP/output"; then :; fi
    check test ! -s "$calls"
done
echo 'PASS: invalid selection, cancellation and empty input delete nothing'
: > "$calls"
fail_domain=a.example.com
if ssl_cmd_remove <<< $'all\nyes' > "$TEST_TMP/output"; then echo 'FAIL: partial failure reported success'; exit 1; fi
check test "$(wc -l < "$calls" | tr -d ' ')" = 3
echo 'PASS: one failure does not prevent remaining selected deletions'
unset fail_domain
: > "$calls"
ssl_cmd_remove b.example.com <<< yes > "$TEST_TMP/output"
check test "$(cat "$calls")" = b.example.com
echo 'PASS: single-domain CLI remains compatible'

ssl_cert_status() { echo COMBINED_STATUS; }
ssl_cmd_logs() { echo LOGS; }
ssl_cmd_help() { echo HELP; }
output=$(ssl_interactive_menu <<< $'2\n3\n4\n0')
check test "$(printf '%s' "$output" | grep -c 'SSL 证书管理')" = 4
check grep -q COMBINED_STATUS <<< "$output"
check grep -q LOGS <<< "$output"
check grep -q HELP <<< "$output"
if [[ "$output" == *'查看证书列表'* || "$output" == *'查看证书状态'* ]]; then echo 'FAIL: duplicate menu entries'; exit 1; fi
echo 'PASS: combined view, logs and help return to the menu'
ssl_interactive_menu < /dev/null > "$TEST_TMP/output"
echo 'PASS: EOF exits the menu cleanly'

if (
    source "$PROJECT_ROOT/src/cert.sh"
    ssl_validation_method() { printf http; }
    ssl_remove_network_mode() { touch "$TEST_TMP/metadata-removed"; }
    rm() { return 1; }
    if ssl_remove_cert a.example.com yes > "$TEST_TMP/output"; then exit 1; fi
    [[ ! -e "$TEST_TMP/metadata-removed" ]]
); then
    echo 'PASS: filesystem deletion failure preserves metadata and returns failure'
else
    echo 'FAIL: filesystem deletion failure reported success or removed metadata'; exit 1
fi
