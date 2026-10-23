# Cloudflare DNS-01 多账号证书 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `w ssl` 增加本机保存多套 Cloudflare Token、逐域名绑定账号的 DNS-01 签发和自动续期，同时保留 HTTP-01 旧证书行为。

**Architecture:** 新的账号状态模块只处理受限本机数据、验证和 Cloudflare 权限测试；签发模块只接收经校验的编号并调用与账号隔离的 acme.sh home/config。入口根据每域名元数据把 HTTP/DNS 申请、单域名续期和批量续期分流；仅 HTTP 路径进入端口暂停逻辑。

**Tech Stack:** Bash、acme.sh (`dns_cf`)、Cloudflare API、curl、openssl、现有 Git Bash 测试脚本。

**Spec:** `docs/superpowers/specs/2026-10-03-cloudflare-dns01-design.md`

## Global Constraints

- 仅支持 Debian、Ubuntu、Alpine；现有 HTTP 模式 `ipv4|ipv6|dual` 与旧配置须继续可用。
- 证书在 `/etc/letsencrypt/live/<domain>/`；持久状态在 `/etc/letsencrypt/ssl-certbot/`；目录 `0700`、凭据/配置 `0600`。
- 首版只支持 Cloudflare；一个输入域名一张证书；新域名 DNS 首次签发由用户指定固定编号；后续续期绝不猜测或切换账号。
- Token 本机明文可被 root、备份及有权限的进程访问；不使用命令参数传 Token，不在菜单、日志及测试输出展示。
- DNS-01 不预检 A/AAAA、也不停止 80/443 服务；HTTP-01 保留端口安全预检，证书变化后均不自动重载服务。
- 现有 02:30 + 最多六轮 8 小时失败重试不变；安装、更新和卸载都保留用户数据。

## Review Focus

- Token 文件被其他用户读取或被 symlink 重定向时，必须拒绝使用，不读取并执行其内容（Task 1 测试）。
- `*.example.com` 仅 DNS 可用；`foo.*.example.com` 和路径分隔符输入必须拒绝（Task 2 测试）。
- 更新账号 Token 后，acme.sh 不得复用此前持久保存的 `CF_Token`（Task 3 测试）。
- HTTP 监听者不可安全暂停时，同一批次 DNS 证书仍须尝试续期并返回总体失败（Task 4 测试）。
- 一个账号仍被域名引用时必须拒绝删除，且已删编号不复用（Task 1 测试）。

## File Map

- `src/cloudflare.sh`（新增）：账号编号分配、受限存储、Cloudflare Token/zone 权限测试、绑定文件读写。
- `src/cert.sh`：DNS 签发/续期的 acme.sh 包装及按模式处理批量证书；原有 HTTP 路径继续可用。
- `src/common.sh`：验证 DNS 域名、纯数据元数据读写与安全路径检查。
- `src/ssl-certbot.sh`：菜单、CLI 参数、账号命令和模式分流。
- `src/renew-all.sh`：加载新模块并保留重试状态机。
- `install/install.sh`：安装新模块；`install/uninstall.sh`：明确保留账号和绑定。
- `src/w-entry.sh`、`README.md`：同步中文帮助与保密说明。
- `tests/test_ssl_certbot.sh`：现有回归及新增 Bash 行为测试。

### Task 1: 账号存储、绑定和权限测试

**Files:** Create `src/cloudflare.sh`; Modify `src/common.sh`; Test `tests/test_ssl_certbot.sh`.

**Interfaces:** Produce `ssl_cf_add_account NAME TOKEN`, `ssl_cf_list_accounts`, `ssl_cf_test_account ID DOMAIN`, `ssl_cf_update_account ID TOKEN`, `ssl_cf_remove_account ID`, `ssl_cf_bind_domain DOMAIN ID`, `ssl_cf_account_for_domain DOMAIN`; each returns nonzero on invalid input/error and never prints Token. DNS domain metadata exposes `ssl_validation_method DOMAIN` (`http` by default) and `ssl_cf_account_for_domain DOMAIN` (empty only for unbound).

- [ ] **Step 1: Write failing behavioral tests.** In `tests/test_ssl_certbot.sh`, source `src/common.sh` and `src/cloudflare.sh` in temporary overridden config paths. Cover add/list/update/delete, monotonically increasing IDs, atomic `0600` files and `0700` directories, invalid ID/name, unreadable or symlinked Token file, deleted/nonexistent account, blocked deletion with a bound domain, and the absence of Token in stdout/stderr. Mock `curl` to return Cloudflare `/user/tokens/verify`, zone lookup and zone permission responses; test API rejection and a zone outside the Token scope.
- [ ] **Step 2: Run `& 'C:\Program Files\Git\bin\bash.exe' -lc 'tests/test_ssl_certbot.sh'` and confirm the new cases fail because the account functions do not exist.**
- [ ] **Step 3: Implement pure-data state.** Persist the next numeric ID separately (never reuse it), map each ID to a validated display name and Token file, bind a validated domain only after account scope test, read values as data (never `source`); reject unsafe paths/permissions. Use `umask 077`, `mktemp` in the target directory, `chmod` and `mv` for atomic updates. For Cloudflare checks, send `Authorization: Bearer` from a hidden Token read; do not enable curl verbose or trace output, and do not log the request headers. Validate zone ownership and the TXT edit capability before binding; report generic Chinese API errors without response dumps.
- [ ] **Step 4: Rerun the suite; inspect generated test files with `stat -c %a` in Git Bash; verify no test log or console contains the test Token.**
- [ ] **Step 5: Commit just this slice with `git add src/cloudflare.sh src/common.sh tests/test_ssl_certbot.sh` and `git commit -m "feat: store isolated Cloudflare accounts and bindings"`.**

### Task 2: 模式和通配符入口

**Files:** Modify `src/ssl-certbot.sh`, `src/common.sh`; Test `tests/test_ssl_certbot.sh`.

**Interfaces:** Produce `ssl_validate_dns_domain DOMAIN`; `ssl_cmd_apply DOMAIN [ipv4|ipv6|dual|dns] [ACCOUNT_ID]` routes existing HTTP or new DNS mode, rejects conflicting saved metadata, and never passes Token as argv.

- [ ] **Step 1: Add tests** for default HTTP CLI compatibility, interactive DNS selection, wildcard DNS-only validation, invalid `*` position and path, missing/invalid account ID and attempted silent rebind. Verify HTTP still calls `ssl_check_dns` and `ssl_pause_port_services`, while DNS calls neither and selects the chosen account. Mock issuance and cron functions so no live certificate is requested.
- [ ] **Step 2: Run the shell suite and confirm the new tests fail on missing DNS route/validator.**
- [ ] **Step 3: Implement the route.** Make the CLI accept `w ssl <domain> dns <id>` for noninteractive first issuance, while a TTY prompts for an account from the stored list; preserve `w ssl <domain> [ipv4|ipv6|dual]`. DNS validates only `*.valid-domain` or an ordinary valid domain. Check existing binding before any network/port action. Keep a separate explicit account-rebind command that verifies the new account before atomically replacing only the binding.
- [ ] **Step 4: Run the suite and Bash syntax checks on all tracked `.sh` files.**
- [ ] **Step 5: Commit with `git add src/common.sh src/ssl-certbot.sh tests/test_ssl_certbot.sh` and `git commit -m "feat: route domain issuance by validation method"`.**

### Task 3: 独立的 acme.sh DNS 签发与部署

**Files:** Modify `src/cert.sh`, `src/cloudflare.sh`; Test `tests/test_ssl_certbot.sh`.

**Interfaces:** Produce `ssl_issue_dns_cert DOMAIN ACCOUNT_ID` and `ssl_renew_dns_cert DOMAIN ACCOUNT_ID`; use the same shared certificate deployment path as HTTP and return nonzero when issuance, deployment or metadata commit fails.

- [ ] **Step 1: Before coding, inspect the actual installed/versioned acme.sh `dns_cf` implementation and documented `--home`/`--config-home` semantics (official acme.sh upstream).** Confirm whether `CF_Token` in the environment overrides persisted account data, how the plugin saves the Token, and which state directory `--renew`/`--remove` use. Record these exact behaviors in test assertions; do not implement multi-account mode if safe isolation cannot be established.
- [ ] **Step 2: Add tests** with a fake acme.sh executable recording sanitized argv, selected home/config and a boolean for environment Token presence (never its value). Assert two IDs have distinct state directories, wildcard uses `--dns dns_cf`, `--renew` uses the saved account, no `--standalone`, DNS does not touch HTTP's acme home, and Token replacement takes precedence over old persisted plugin state. Include failure cases for revoked Token, issuance success followed by install or metadata failure, and partial success that is not reported as complete.
- [ ] **Step 3: Run the suite and confirm the new acme invocation tests fail.**
- [ ] **Step 4: Implement the wrappers** using a verified per-account acme config/home invocation and environment-scoped `CF_Token` from the 0600 file; clear stale persisted Cloudflare Token on rotation without deleting unrelated acme account/certificate records. Reuse existing `--install-cert` paths, permissions and expiry display. Delay publishing a new binding until certificate deployment succeeds; on a later failure retain the previous valid deployment and emit an explicit partial-failure diagnostic. Ensure logs and error messages never include the Token or raw Cloudflare API response.
- [ ] **Step 5: Run suite and Bash syntax checks; review command traces and filesystem permissions without displaying secret values. Commit with `git add src/cert.sh src/cloudflare.sh tests/test_ssl_certbot.sh` and `git commit -m "feat: issue and renew DNS certificates with isolated acme state"`.**

### Task 4: 混合自动续期、删除和文档

**Files:** Modify `src/cert.sh`, `src/ssl-certbot.sh`, `src/renew-all.sh`, `install/install.sh`, `install/uninstall.sh`, `src/w-entry.sh`, `README.md`, `tests/test_ssl_certbot.sh`.

**Interfaces:** `ssl_renew_managed_certificates` returns nonzero if any selected certificate or restoration fails; `ssl_cmd_renew [DOMAIN]` selects DNS vs HTTP by saved metadata; `ssl_remove_cert DOMAIN yes` removes only that domain's state from the correct acme home.

- [ ] **Step 1: Add mixed-mode tests.** Create mocked HTTP and DNS certificates within the renewal window; make HTTP preflight fail and assert DNS renewal still runs, HTTP failure is included in summary, and the cron retry state still advances. Test DNS-only batch never calls pause/restore; HTTP-only retains old behavior; single-domain DNS renewal and delete use the bound ID while other accounts and certs survive. Add a wildcard list/status test and help/menu/installer consistency assertions.
- [ ] **Step 2: Run the suite and confirm mixed-mode and command tests fail.**
- [ ] **Step 3: Implement mixed-mode processing.** Partition due domains before pausing ports; process DNS independently and HTTP with one shared pause/restore. Preserve the `renew-all.sh` retry count and exit code. Update remove/list/status/menu/CLI/help and installer to include the new module, account management and explicit rebind, avoiding sensitive values in UI. Update uninstall to say certificates, account files, bindings and all acme homes are retained; never delete credential state by default. Document both methods, root-only Token persistence, wildcard scope, account scopes and manual real-VPS verification in README.
- [ ] **Step 4: Run full suite, `bash -n` for every tracked shell script and `git diff --check`. Confirm only expected files changed and no secret was staged.**
- [ ] **Step 5: Commit with `git add src/cert.sh src/ssl-certbot.sh src/renew-all.sh install/install.sh install/uninstall.sh src/w-entry.sh README.md tests/test_ssl_certbot.sh` and `git commit -m "feat: support mixed DNS and HTTP renewal workflows"`.**

## Delivery

After all tasks pass, recheck `git status`, `git diff` and `origin` target. The user has already requested publication in this turn: push only reviewed commits to `origin/main` once implementation and tests finish; report commit IDs and remote HEAD. Local mocked tests cannot prove a real Cloudflare/Let's Encrypt issuance, DNS propagation, or an actual Debian/Ubuntu/Alpine renewal; identify those as unverified until tested on a VPS with a least-privilege Token.
