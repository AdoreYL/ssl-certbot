# ssl-certbot

专为轻量 VPS / 云服务器打造的轻量级自动化 SSL 证书管理工具。基于 **acme.sh** 与 **Let's Encrypt HTTP-01** 独立模式（Standalone）签发权威可信证书，无需 Docker、Certbot、Python 或 Node.js 运行时。

## 支持系统

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04
- Alpine Linux 3.x

## 快速上手

```bash
# Debian / Ubuntu 一键远程安装（推荐）
curl -fsSL https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh | bash
```

Alpine Linux 最小系统默认不含 `bash` 和 `curl`，需先安装前置依赖：

```bash
# Alpine Linux 首次安装（兼容 /dev/fd 被限制执行的环境）
apk add --no-cache bash curl tar
curl -fsSL https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh | bash
```

```bash
# 安装后，按 IPv6 模式为域名申请证书
w ssl example.com ipv6

# 或调出交互式操作菜单
w ssl
```

如需检查安装内容或在离线环境部署，也可以克隆仓库后执行安装器：

```bash
git clone https://github.com/AdoreYL/ssl-certbot.git
cd ssl-certbot
bash install/install.sh
```

默认快捷命令为 `w`。若 `/usr/local/bin/w` 已被其他程序占用且不选择覆盖，安装器会尝试安装备用命令 `sslcert`；也可以在安装时主动指定命令名：

```bash
curl -fsSL https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh | SSL_CERTBOT_BIN=sslcert bash
sslcert ssl example.com
```

## 常用命令

| 命令 | 说明 |
|------|------|
| `w ssl` | 打开交互式管理菜单 |
| `w ssl <domain> [ipv4\|ipv6\|dual]` | 按指定网络模式申请或续期证书；未指定时交互选择 |
| `w ssl <domain> dns <编号>` | 使用指定 Cloudflare 账号执行 DNS-01 申请或续期 |
| `w ssl cf-menu` | 打开 Cloudflare 账号管理菜单 |
| `w ssl cf-add <名称>` | 添加 Cloudflare 账号（Token 隐藏输入，不作为命令参数） |
| `w ssl cf-list` | 查看账号编号、名称与已绑定域名 |
| `w ssl cf-test <编号> [域名]` | 测试 Token 是否有效、能否访问该域名所属 Zone |
| `w ssl cf-update <编号>` | 更换账号 Token，并清除 acme.sh 中的旧凭据 |
| `w ssl cf-remove <编号>` | 删除账号（仍绑定域名时会被拒绝） |
| `w ssl cf-rebind <域名> <编号>` | 显式把域名改绑到另一个账号 |
| `w ssl list` | 列出所有已管理的证书及是否进入续期窗口 |
| `w ssl status` | 查看指定域名的详细证书状态与端口环境 |
| `w ssl renew` | 批量手动续期所有证书 |
| `w ssl renew <domain>` | 手动续期指定域名的证书 |
| `w ssl remove <domain>` | 删除本地证书文件及 acme.sh 记录（需输入 `yes` 确认） |
| `w ssl update` | 更新 ssl-certbot 脚本，保留证书与自动续期任务 |
| `w ssl uninstall` | 卸载 ssl-certbot（保留证书、acme.sh 和日志） |
| `w ssl logs` | 查看工具操作与续期日志 |
| `w ssl help` | 查看命令行帮助信息 |

> 指令大小写不敏感：`w ssl`、`W ssl`、`w SSL`、`W SSL` 均可正常执行。

## 工作机制

1. **选择验证方式**：可申请时可选 HTTP-01 或 Cloudflare DNS-01。已绑定 DNS-01 的域名会记住该方式与其账号编号，续期时自动复用，绝不静默换用另一种方式或另一个账号。
2. **域名、网络模式与 DNS 预检（仅 HTTP-01）**：校验域名格式；IPv4 模式要求 A 记录匹配本机 IPv4，IPv6 模式要求 AAAA 记录匹配本机 IPv6，双栈模式要求两者都匹配。优先使用网卡上的公网地址；网卡地址不匹配时，只会按当前模式查询同协议的公网出口地址，IPv6 校验绝不会使用 IPv4 或 Cloudflare WARP 的出口地址。
2. **端口占用检测**：检测当前占用 TCP 80 与 443 端口的具体服务进程。
3. **安全暂停已确认服务**：仅当受支持的 Web 服务监听 PID 可由 `/proc/<PID>/cgroup` 确认归属实际 systemd 单元时，才会暂停该单元；若 cgroup 明确归属某个正在运行的 Docker 容器，则只暂停该容器；检测到 `docker-proxy` 时仅处理可关联到同端口发布映射的 Docker 容器。无法确认来源的进程不会被强制停止。
4. **HTTP-01 验证**：启动 `acme.sh --standalone` 监听 80 端口，完成 Let's Encrypt 证书申请与签发。
5. **规范归档证书**：将签发的证书与私钥统一安装归档到 `/etc/letsencrypt/live/<domain>/` 目录。
6. **现场完全复原**：无论签发成功、失败或人为中断（`Ctrl+C`），自动恢复先前暂停的所有服务，保障业务连续性。
7. **自动续期配置**：注册系统 Cron 任务，实现到期前无人值守自动续签。

### 核心注意事项

- **必须开放公网 TCP 80 端口**：HTTP-01 验证依赖 Let's Encrypt CA 服务器直接访问本机的 80 端口。若存在云厂商安全组/防火墙拦截，需提前放行。
- **TCP 443 端口处理**：443 端口属于安全暂停/恢复范围，但 HTTP-01 验证本身仅占用 80 端口。
- **零破坏与防误杀安全策略**：若检测到非受管的未知进程占用端口，脚本**绝不会**强行使用 `kill -9` 杀除，而是输出其 PID 和进程名，提示管理员手动处理。
- **服务加载新证书**：工具会恢复被暂停的服务，但不会自动 reload 或 restart Nginx、Caddy、x-ui、3x-ui。请自行确保服务配置指向下方的证书路径，并在证书更新后按自己的服务配置 reload。

## 证书保存路径

所有证书均按域名分目录规范化存放：

```
/etc/letsencrypt/live/<domain>/fullchain.pem   # 证书公钥链（权限 644）
/etc/letsencrypt/live/<domain>/privkey.pem     # 证书私钥（权限 600）
```

示例：

```
/etc/letsencrypt/live/hk.example.com/fullchain.pem
/etc/letsencrypt/live/hk.example.com/privkey.pem
```

各域名独立目录隔离存储，绝不发生覆盖冲突。通配符证书目录以 `_wildcard_` 前缀命名，详见下方“Cloudflare DNS-01 与通配符证书”。

列表和详情中的到期时间会统一换算为中国标准时间，例如 `2026年12月06日 17:30:50（中国标准时间）`。

删除证书可使用 `w ssl remove <domain>`，或在交互菜单中选择“删除证书”。该操作会删除 `/etc/letsencrypt/live/<domain>/`、对应的网络模式配置与 acme.sh 本地记录，但不会向 Let's Encrypt 撤销已经签发的证书。

旧版工具写入 `/root/cert/<domain>/` 的证书会在后续运行时自动迁移到新目录；如果新目录已存在同名证书文件，则不会覆盖。

## IPv4、IPv6 与双栈

申请时可在交互菜单选择网络模式，也可以直接指定：

```bash
w ssl example.com ipv4
w ssl example.com ipv6
w ssl example.com dual
```

- `ipv4`：要求域名的 A 记录与本机 IPv4 地址匹配；若网卡只有内网 IPv4，工具会查询 IPv4 公网出口地址以兼容云平台的 NAT 映射，acme.sh 仅监听 IPv4。
- `ipv6`：要求域名的 AAAA 记录与本机全局 IPv6 地址匹配，acme.sh 仅监听 IPv6。会忽略 `fc00::/7` 私有 IPv6 地址；若网卡地址不匹配，会仅通过 IPv6 查询公网出口地址后再校验。适用于原生 IPv6、IPv6 隧道或地址映射的 VPS；WARP 的出口 IPv4 不参与判断。
- `dual`：要求 A 和 AAAA 都与本机地址匹配，acme.sh 保持双栈 standalone 监听。

模式会按域名保存，之后的手动续期与 Cron 自动续期会自动复用。HTTP-01 的实际访问路径由 Let's Encrypt 根据 DNS 解析决定：对应 A 或 AAAA 必须指向本机，且公网 TCP 80 必须可访问。双栈域名的两个地址都应能访问 TCP 80。

工具不要求配置证书通知邮箱，会以无联系邮箱的 Let’s Encrypt 账户完成注册并依靠自动续期维护证书。若旧版脚本曾写入 `ssl-certbot@localhost`，新版会在运行时自动清除这条无效配置。

## Cloudflare DNS-01 与通配符证书

国内机房常会拦截未备案域名的 80 端口，HTTP-01 无法完成验证；通配符证书也只能用 DNS 验证。这两种场景使用 Cloudflare DNS-01：由 acme.sh 的 `dns_cf` 插件调用 Cloudflare API 写入 `_acme-challenge` TXT 记录完成验证，全程不需要开放 80/443，也不会暂停或恢复任何服务。

### 使用步骤

```bash
# 1. 添加一个或多个 Cloudflare 账号（Token 隐藏输入，不写入命令历史）
w ssl cf-add 主账号
w ssl cf-add 备用账号

# 2. 查看自动分配的固定编号
w ssl cf-list

# 3. 申请单域名或通配符证书
w ssl hk.example.com dns 1
w ssl '*.example.com' dns 1

# 4. 之后直接续期，脚本会自动使用绑定账号
w ssl renew '*.example.com'
```

交互式菜单里选择“申请或续期证书”，再选择 `Cloudflare DNS-01`，按提示输入域名和账号编号即可。

### 账号与域名绑定

- 每个 Cloudflare Token 有一个固定编号，编号一旦使用过就不会复用，避免旧绑定指向另一个 Token。
- 首次申请时必须手动指定编号；申请成功后，域名与编号的对应关系写入本机配置。自动续期直接按绑定取回该账号，不会去猜哪个账号拥有这个域名，也不会在失败时改用别的账号。
- 需要换账号时使用 `w ssl cf-rebind <域名> <编号>`：先用目标账号验证 Zone 权限，并通过该账号重新签发、部署证书，成功后才替换绑定；安装或绑定失败会恢复原证书和私钥。此操作与自动续期共用进程锁，避免同时写入。
- 仍被域名绑定的账号不允许删除，否则会破坏自动续期。
- 每个输入域名单独签发一张证书，互不影响；某个域名的 Token 权限有问题时，只会导致该域名失败，不会连累其他证书。

### 通配符范围

`*.example.com` 只覆盖同层子域名（例如 `a.example.com`），不包含 `example.com` 本身，也不包含 `a.b.example.com`。根域名与多级子域名请各自申请一张证书。通配符只能通过 DNS-01 申请，HTTP-01 会拒绝 `*` 输入。

证书与元数据目录使用 `_wildcard_` 前缀保存，避免目录名里出现 `*`：

```
/etc/letsencrypt/live/_wildcard_example.com/fullchain.pem
/etc/letsencrypt/live/_wildcard_example.com/privkey.pem
```

### 凭据保存与保密边界

- Token 只保存在本机 `/etc/letsencrypt/ssl-certbot/cloudflare/<编号>/token`，目录权限 `0700`、文件权限 `0600`，属主为 root。
- Token 不作为命令行参数传递，不回显，不写入菜单输出、工具日志与 GitHub。
- Cloudflare API 请求（验证 Token 与 Zone）会直接从本机发往 `api.cloudflare.com`，Let's Encrypt 请求发往证书颁发机构；除 DNS-01 的这些调用外，工具不上传任何内容。
- 每个 DNS 账号使用独立的 acme.sh 配置目录（`cloudflare/<编号>/acme`），账号密钥、CA 状态与签发的证书互不共享；HTTP-01 仍使用原来的 `/root/.acme.sh`，不受影响。
- 更换 Token 时会同时清除 acme.sh 中持久化的旧凭据，避免某个账号借用另一个账号的身份。
- 这是明文保存而非加密：root、备份软件以及具备相应权限的本机进程仍可读到原文。自动续期需要在无人值守时取回 Token，因此没有额外密钥管理服务时无法做到真正的静态加密。请使用最小权限 Token（只授权需要的 Zone，Zone - DNS - Edit），并保护好 VPS 与备份。

## 自动续期机制

安装后会自动注册 Cron 定时任务，每天 `02:30`、`10:30`、`18:30` 检查一次。正常情况下只有每天 `02:30` 执行续期；如果续期失败，脚本会进入重试状态，在后续每隔 8 小时再次尝试，最多连续重试 6 轮。6 轮仍失败后恢复为每天 `02:30` 执行，下一天继续尝试。重试状态保存于 `/etc/letsencrypt/ssl-certbot/renew-retry.state`，实例重启后仍会保留。脚本使用 `openssl x509 -checkend` 判断证书是否进入约 30 天的续期窗口，避免依赖 Alpine BusyBox 与 GNU `date` 的参数差异。

只有存在**需要续期的 HTTP-01 证书**时，工具才会暂停已识别且实际占用 TCP 80/443 的服务并执行普通 `acme.sh --renew`；没有需要续期的证书时不会暂停服务。Cloudflare DNS-01 证书完全不触碰端口：自动续期任务不占用 80 端口，也不会重启任何服务。若同一批里既有 DNS 证书又有 HTTP 证书，而 HTTP 端口预检失败，DNS 证书仍会各自独立续期，整批任务以失败状态结束并触发下一轮 8 小时重试。任一证书续期、证书读取或服务恢复失败时，自动任务会以非零状态结束并记录日志并触发 8 小时重试，原有有效证书不会被删除。

## 适配服务检测清单

当以下进程实际占用了 TCP 80 或 443 端口，且监听 PID 的 cgroup 可确认归属某个 systemd 单元时，工具会自动进行识别与受控启停。服务单元名无需固定，例如由 Nginx 监听的 `my-nginx.service` 会被识别为实际的 `my-nginx.service`：

| 受支持进程 | 典型服务 |
|------------|----------|
| `nginx` / `openresty` | Nginx / OpenResty |
| `caddy` | Caddy |
| `apache2` / `httpd` | Apache HTTP Server |
| `haproxy` | HAProxy |
| `traefik` | Traefik |
| `x-ui` / `3x-ui` | x-ui / 3x-ui |

对于 Docker 服务，工具只有在监听 PID 的 cgroup 明确归属某个正在运行的容器，或实际观测到同端口的 `docker-proxy` 且能匹配端口发布映射时，才会暂停对应容器，绝不停止 Docker 守护进程（dockerd）。无法可靠关联监听端口的 Docker 服务需要手动处理。

## 依赖要求

仅依赖极简的系统基础工具（缺少时自动尝试安装）：

- `bash`
- `curl`
- `openssl`
- `socat`
- `acme.sh`（自动下载引导）
- `jq`（仅 Cloudflare DNS-01 使用，缺少时按需自动安装）
- `cron` / `crond`
- `ss` / `netstat` / `lsof`（至少具备其一）
- `flock`（并发进程排他锁）

**无需安装：** Docker、Certbot、Python、Node.js。只有使用 Cloudflare DNS-01 时才需要配置 API Token。

## 设计边界与说明 (v1)

- 支持 HTTP-01 与 Cloudflare DNS-01 两种验证方式；DNS-01 目前只接入 Cloudflare
- 每个输入域名单独签发一张证书，不把多个域名合并进一张证书的 SAN；通配符证书通过 DNS-01 申请
- 不主动侵入修改 Nginx/Caddy/x-ui 等服务的原有配置文件
- 不自动 reload 或 restart 服务；服务如何加载更新后的证书由管理员自行配置
- 仅自动暂停可确认归属实际 systemd 单元的受支持监听进程；手工启动或其他无法安全识别的进程会提示手动处理
- 不支持申请纯 IP 证书与自签名证书
- 专为 Debian/Ubuntu/Alpine 优化

## 安全特性

- 需 `root` 权限执行（绑定系统保留端口 80 及启停服务所需）
- 全局限制安全掩码 `umask 077`
- 私钥文件默认严格设定为 `600` 权限
- 不使用任何粗暴的杀进程指令（无 `killall`、`fuser -k`）
- 参数严格格式校验，杜绝 Shell 注入漏洞
- 日志不记录任何私钥及敏感凭证
- 具备退出捕获机制（Trap），遇到异常或信号中断时无条件恢复暂停的服务

## 卸载

```bash
w ssl uninstall
```

卸载仅移除本工具的软链接与脚本本体，已签发的证书与 `acme.sh` 均会安全保留。

若是在克隆仓库的目录中运行，也可以执行 `bash install/uninstall.sh`。远程安装完成后，卸载脚本会随程序一起安装，无需保留仓库目录。

## 项目文件结构

```
ssl-certbot/
  install.sh             # 可通过 curl 运行的远程安装入口
  src/
    common.sh          # 基础公共函数库、系统识别、依赖校验、锁与日志
    port_service.sh    # 80/443 端口检测与服务识别、安全暂停与现场恢复
    cloudflare.sh      # Cloudflare 账号存储、域名绑定与 Zone 权限测试
    cert.sh            # 证书申请、续期、状态查看、列表列出
    cron.sh            # 自动续期定时任务管理
    ssl-certbot.sh     # 业务主入口分发器 (w ssl 命令核心)
    w-entry.sh         # /usr/local/bin/w 快捷包装脚本
    renew-all.sh       # Cron 定时调用的全量续期脚本
  install/
    install.sh         # 仓库内安装脚本
    uninstall.sh       # 卸载脚本
  docs/
    requirements.md    # 架构与需求设计规范文档
  README.md            # 项目说明文档
```

## 开源协议

MIT
