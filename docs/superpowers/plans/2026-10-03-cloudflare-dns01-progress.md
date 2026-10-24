# SDD ledger — plan: docs/superpowers/plans/2026-10-03-cloudflare-dns01.md

## 2026-10-24 continuation

- Existing branch: `feat/cloudflare-dns01`; baseline commit: `9285df7`.
- Tasks 1–4 already have implementation commits. Continue from the three uncommitted drafts rather than recreating those tasks.
- Retained and verified draft changes: reissue through the target account on explicit rebind; fail unchanged DNS renewal; tolerate malformed metadata in display commands.
- Fixed regression fixtures to generate a new certificate on successful renewal, assert the binding inside its configured subshell, and mark fake acme executables executable on Linux.
- Added guards for existing unsafe acme logs and restrictive creation of new logs before provider output is redirected.
- Added a shared deployment backup/restore path covering issuance, renewal, install and binding failures. Restore the old certificate/key pair on failure; retain the backup and report its path if restoration itself fails.
- Added the shared process lock to the rebind command.

## Rulings

- Continue in the existing feature checkout to preserve the user's uncommitted work. Do not recreate the feature or overwrite drafts.
- Explicit rebind also issues in the target account's isolated config-home: replacing only metadata leaves that account without the domain record needed for renewal. This can request another certificate and is documented in README.
- Back up before `--issue`/`--renew`, because upstream renewal can install directly to saved `Le_Real*Path` destinations. Backing up only before `--install-cert` is too late.
- A skipped or unchanged renewal must return failure rather than claim that a new certificate was deployed.
- Do not publish automatically: the current user instructions require confirmation before external publication, despite the old plan's Delivery paragraph claiming prior approval.

## Upstream evidence checked

- https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_cf.sh — environment `CF_Token` takes precedence over the saved fallback; credentials can be persisted in account or domain configuration.
- https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh — config-home selects account/CA/certificate state; renew passes saved real deployment paths to issue, which may install directly.

## Verification

- New unsafe-log test: failed before the guard and passed after it.
- New install/binding rollback tests: failed before rollback and passed after it.
- New renewal auto-install failure test: failed before the transaction covered `--renew` and passed after it.
- New rebind lock test: failed before acquiring the lock and passed after it.
- Complete regression suite: `All 149 tests passed.` (exit 0); includes four additional assertions in the deployment/lock script. All tracked Bash scripts plus the new script passed `bash -n`; `git diff --check` passed.
- Final independent read-only review: no remaining blocking findings in this change.
- Real Cloudflare/Let's Encrypt issuance, TXT propagation/cleanup and Debian/Ubuntu/Alpine runtime renewal remain unverified. No real Token was supplied or used.
