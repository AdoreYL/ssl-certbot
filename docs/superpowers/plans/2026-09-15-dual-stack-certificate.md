# Dual-Stack Certificate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support saved IPv4, IPv6, and dual-stack HTTP-01 modes while moving managed certificates to `/etc/letsencrypt/live`.

**Architecture:** Common helpers own paths, migration, and per-domain state. The command entry point selects a network mode and validates DNS against local interface addresses. Certificate operations convert that mode to acme.sh listener flags and reuse it during renewal.

**Tech Stack:** Bash, acme.sh, OpenSSL, iproute2/BusyBox networking utilities, existing shell test harness.

**Spec:** `docs/superpowers/specs/2026-09-15-dual-stack-certificate-design.md`

## Global Constraints

- Use standalone HTTP-01 and TCP 80 only.
- Do not use outbound WARP/egress IPv4 discovery for DNS ownership validation.
- Store managed certificates in `/etc/letsencrypt/live/<domain>/`.
- Permit only `ipv4`, `ipv6`, and `dual` saved modes.
- Fail DNS preflight before any managed service is stopped.
- Support Debian, Ubuntu, and Alpine.

### Task 1: Persist Mode and Migrate Storage

**Files:** `src/common.sh`, `tests/test_ssl_certbot.sh`

- [x] Write a failing test for `ssl_save_network_mode`, `ssl_load_network_mode`, and legacy `/root/cert` migration.
- [x] Run `tests/test_ssl_certbot.sh` and confirm it fails for absent helpers.
- [x] Implement the helpers and canonical path constants.
- [x] Run the suite and confirm it passes.

### Task 2: Validate Selected Address Family

**Files:** `src/ssl-certbot.sh`, `tests/test_ssl_certbot.sh`

- [x] Write a failing test for IPv6-only validation without an IPv4 egress lookup and dual mode requiring both record types.
- [x] Run the suite and confirm the tests fail.
- [x] Implement local-address discovery, DNS record lookup, selection UI, and CLI mode argument parsing.
- [x] Run the suite and confirm it passes.

### Task 3: Apply and Renew by Saved Mode

**Files:** `src/cert.sh`, `src/ssl-certbot.sh`, `tests/test_ssl_certbot.sh`

- [x] Write a failing test for `--listen-v4` / `--listen-v6` issuance and renewal flags.
- [x] Run the suite and confirm the tests fail.
- [x] Implement acme.sh argument selection and persist mode after successful installation.
- [x] Run the suite and confirm it passes.

### Task 4: Integrate Cleanup and Documentation

**Files:** `src/common.sh`, `src/cert.sh`, `src/ssl-certbot.sh`, `README.md`, `tests/test_ssl_certbot.sh`

- [x] Write failing tests for removing per-domain mode state and the canonical README path.
- [x] Run the suite and confirm the tests fail.
- [x] Update delete, help, final output, documentation, and startup migration integration.
- [x] Run `tests/test_ssl_certbot.sh`, Bash syntax checks, and `git diff --check`.
- [ ] Commit and push the completed work to `origin main`.
