# ssl-certbot

专为轻量 VPS / 云服务器打造的轻量级自动化 SSL 证书管理工具。基于 **acme.sh** 与 **Let's Encrypt HTTP-01** 独立模式（Standalone）签发权威可信证书，无需 Docker、Certbot、Python 或 Node.js 运行时。

## 支持系统

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04
- Alpine Linux 3.x

## 快速上手

```bash
# 一键远程安装（推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh)

# 安装后，直接为域名申请证书
w ssl example.com

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
SSL_CERTBOT_BIN=sslcert bash <(curl -fsSL https://raw.githubusercontent.com/AdoreYL/ssl-certbot/main/install.sh)
sslcert ssl example.com
```

## 常用命令

| 命令 | 说明 |
|------|------|
| `w ssl` | 打开交互式管理菜单 |
| `w ssl <domain>` | 申请或续期指定域名证书 |
| `w ssl list` | 列出所有已管理的证书及是否进入续期窗口 |
| `w ssl status` | 查看指定域名的详细证书状态与端口环境 |
| `w ssl renew` | 批量手动续期所有证书 |
| `w ssl renew <domain>` | 手动续期指定域名的证书 |
| `w ssl logs` | 查看工具操作与续期日志 |
| `w ssl help` | 查看命令行帮助信息 |

> 指令大小写不敏感：`w ssl`、`W ssl`、`w SSL`、`W SSL` 均可正常执行。

## 工作机制

1. **域名与 DNS 预检**：校验域名格式合法性，检查公网 DNS 是否已正确解析到本机公网 IP。
2. **端口占用检测**：检测当前占用 TCP 80 与 443 端口的具体服务进程。
3. **安全暂停已知服务**：识别已知 Web/代理服务（Nginx、Caddy、x-ui、3x-ui）或映射了上述端口的 Docker 容器，并安全暂停它们以释放验证端口。
4. **HTTP-01 验证**：启动 `acme.sh --standalone` 监听 80 端口，完成 Let's Encrypt 证书申请与签发。
5. **规范归档证书**：将签发的证书与私钥统一安装归档到 `/root/cert/<domain>/` 目录。
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
/root/cert/<domain>/fullchain.pem   # 证书公钥链（权限 644）
/root/cert/<domain>/privkey.pem     # 证书私钥（权限 600）
```

示例：

```
/root/cert/hk.example.com/fullchain.pem
/root/cert/hk.example.com/privkey.pem
```

各域名独立目录隔离存储，绝不发生覆盖冲突。

## 自动续期机制

安装后会自动注册 Cron 定时任务，每天凌晨 02:30 执行扫描。脚本使用 `openssl x509 -checkend` 判断证书是否进入约 30 天的续期窗口，避免依赖 Alpine BusyBox 与 GNU `date` 的参数差异。

只有存在需要续期的证书时，工具才会暂停已识别且实际占用 TCP 80/443 的服务并执行普通 `acme.sh --renew`；没有需要续期的证书时不会暂停服务。任一证书续期、证书读取或服务恢复失败时，自动任务会以非零状态结束并记录日志，原有有效证书不会被删除。

## 适配服务检测清单

当以下服务实际占用了 TCP 80 或 443 端口时，工具会自动进行识别与受控启停：

| 服务名称 | Systemd 服务名 | OpenRC 服务名 |
|----------|----------------|---------------|
| Nginx | `nginx.service` | `nginx` |
| Caddy | `caddy.service` | `caddy` |
| x-ui | `x-ui.service` | `x-ui` |
| 3x-ui | `3x-ui.service` | `3x-ui` |

同时支持检测占用 80/443 的 Docker 容器并仅暂停容器自身，绝不停止 Docker 守护进程（dockerd）。

## 依赖要求

仅依赖极简的系统基础工具（缺少时自动尝试安装）：

- `bash`
- `curl`
- `openssl`
- `socat`
- `acme.sh`（自动下载引导）
- `cron` / `crond`
- `ss` / `netstat` / `lsof`（至少具备其一）
- `flock`（并发进程排他锁）

**无需安装：** Docker、Certbot、Python、Node.js，也无需配置 Cloudflare API Token。

## 设计边界与说明 (v1)

- 仅支持 HTTP-01 验证（暂不提供 DNS-01 API 接入）
- 仅支持单域名证书（不支持通配符通配证书与多 SAN 域名合并）
- 不主动侵入修改 Nginx/Caddy/x-ui 等服务的原有配置文件
- 不自动 reload 或 restart 服务；服务如何加载更新后的证书由管理员自行配置
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
bash install/uninstall.sh
```

卸载仅移除本工具的软链接与脚本本体，已签发的证书与 `acme.sh` 均会安全保留。

## 项目文件结构

```
ssl-certbot/
  install.sh             # 可通过 curl 运行的远程安装入口
  src/
    common.sh          # 基础公共函数库、系统识别、依赖校验、锁与日志
    port_service.sh    # 80/443 端口检测与服务识别、安全暂停与现场恢复
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
