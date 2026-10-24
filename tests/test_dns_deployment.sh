#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
source "$PROJECT_ROOT/src/cert.sh"
ssl_log() { :; }
ssl_validate_dns_domain() { :; }
ssl_cf_account_ready() { :; }
ssl_cf_test_account() { :; }
ssl_cert_slug() { printf '%s' "$1"; }
ssl_cf_bind_domain() { [[ "$failure" != binding ]]; }
ssl_cf_account_for_domain() { printf 2; }
ssl_dns_acme_call() {
    if [[ "$failure" == renew && " $* " == *' --renew '* ]]; then
        printf partial-auto-install > "$SSL_CERT_BASE/example.com/fullchain.pem"
        return 1
    fi
    if [[ " $* " == *' --install-cert '* ]]; then
        printf broken-new-chain > "$SSL_CERT_BASE/example.com/fullchain.pem"
        [[ "$failure" != install ]] || return 1
        printf new-key > "$SSL_CERT_BASE/example.com/privkey.pem"
    fi
}
for failure in install binding renew; do
    SSL_CERT_BASE="$TEST_TMP/$failure"
    mkdir -p "$SSL_CERT_BASE/example.com"
    printf old-chain > "$SSL_CERT_BASE/example.com/fullchain.pem"
    printf old-key > "$SSL_CERT_BASE/example.com/privkey.pem"
    operation=ssl_issue_dns_cert
    [[ "$failure" != renew ]] || operation=ssl_renew_dns_cert
    if "$operation" example.com 2 force; then
        echo "FAIL: $failure must return failure"; exit 1
    fi
    [[ $(cat "$SSL_CERT_BASE/example.com/fullchain.pem") == old-chain ]] || { echo "FAIL: $failure overwrote old chain"; exit 1; }
    [[ $(cat "$SSL_CERT_BASE/example.com/privkey.pem") == old-key ]] || { echo "FAIL: $failure overwrote old key"; exit 1; }
    echo "PASS: $failure preserves deployed certificate pair"
done

if (
    SSL_CERTBOT_NO_MAIN=1
    source "$PROJECT_ROOT/src/ssl-certbot.sh"
    trap - EXIT INT TERM HUP
    locked=no
    ssl_acquire_lock() { locked=yes; }
    ssl_cf_rebind_domain() { [[ "$locked" == yes ]]; }
    ssl_log() { :; }
    ssl_cf_cmd_rebind example.com 2
); then
    echo 'PASS: rebind holds the shared process lock'
else
    echo 'FAIL: rebind does not hold the shared process lock'; exit 1
fi
