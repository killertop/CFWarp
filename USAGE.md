# CFWarp 使用说明 / Usage

[中文](#中文) · [English](#english) · [项目介绍 / Overview](README.md)

## 中文

### 1. 安装和启动

面向具备 systemd、内核 WireGuard、network namespace 和 iptables 支持的 Linux 服务器。安装、网络配置和进入 namespace 需要 root；通过 SOCKS5 使用出口的普通应用不需要 root。

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

新安装默认准备文件并启用服务开机启动；添加 `--start` 可立即启动或重启。升级会恢复安装前正在运行的服务。缺少隧道配置时，优先复用现有 WARP 账户生成 WireGuard 配置；只有账户也不存在时，才调用 `wgcf register --accept-tos` 注册。默认使用固定版本、带 SHA256 校验的 `wgcf`，MicroSOCKS 从固定 commit 构建。

默认路径为运行文件 `/opt/cfwarp`、环境文件 `/etc/cfwarp/cfwarp.env`、账户与隧道配置 `/var/lib/cfwarp`。可以自定义：

```bash
sudo ./install.sh --prefix /opt/cfwarp-custom \
  --env-dir /etc/cfwarp-custom --data-dir /var/lib/cfwarp-custom \
  --bin-dir /opt/cfwarp-custom/bin
```

使用 root 可控的绝对路径。安装器在运行目录的 `deploy/installation.env` 记录安装路径，让 systemd 与直接执行的助手使用相同配置。此文件由安装器生成，不应提交到仓库。升级和清理自定义安装时，应重复传入相同路径参数。

### 2. 配置文件和优先级

环境文件采用单行 `KEY=VALUE` 数据格式，支持单引号和双引号；双引号中可转义反斜杠、双引号、美元符号和反引号。它不是可执行 Shell 脚本：不运行命令、不展开变量，不支持多行值。带空格的值应加引号。

```text
CFWARP_MODE=netns-proxy
CFWARP_DATA_DIR='/var/lib/cfwarp'
NETNS_DNS_SERVERS="1.1.1.1 1.0.0.1"
```

显式 CLI 选项优先于对应配置；已导出的进程环境变量优先于文件值，其次依次为配置文件、安装记录中的默认路径和脚本默认值。`CFWARP_ENV_FILE` 可指定配置位置；未指定时通过安装记录定位，源码运行才使用默认配置查找。助手通过共享加载逻辑传递已解析的配置，子进程不再重新加载旧值覆盖调用者。

临时检查其他配置：

```bash
sudo env CFWARP_ENV_FILE=/etc/cfwarp-custom/cfwarp.env \
  /opt/cfwarp-custom/cfwarp-healthcheck.sh
```

保持环境文件权限 `0600`、WARP 数据目录权限 `0700`。不要把私钥、账户、代理密码或令牌放进 issue、截图和公开日志。

### 3. 默认模式：按应用使用

`netns-proxy` 将 WARP 和 SOCKS5 放入独立 namespace。默认入口：

```text
socks5h://169.254.240.2:1080
```

应用示例：

```bash
curl --proxy socks5h://169.254.240.2:1080 https://www.cloudflare.com/cdn-cgi/trace
ALL_PROXY=socks5h://169.254.240.2:1080 curl https://www.cloudflare.com/cdn-cgi/trace
```

`socks5h` 把目标域名交给代理端解析；`socks5` 可能由客户端本地解析。应用必须支持所使用的代理配置方式，单纯设置 `ALL_PROXY` 不会强制所有程序走代理。

没有代理选项的命令可在 namespace 中执行：

```bash
sudo /opt/cfwarp/cfwarp-exec curl https://www.cloudflare.com/cdn-cgi/trace
```

这需要 root 权限，命令也以 root 运行；服务未启动、namespace 归属或出口保护不匹配、隧道没有近期握手或路由尚未就绪时会拒绝执行，`host-global` 模式也无法使用。当前 WARP 出站限于 IPv4，SOCKS5 仅转发 TCP，不提供 UDP 代理。

默认不会替换宿主机默认路由，但会创建 veth 和本项目的 NAT/转发规则，并在需要时启用 IPv4 forwarding。停止时按记录的资源归属清理；同名外部资源不应被当作可接管资源。

namespace 的出口防火墙在建立连通性前生效。隧道接口或路由消失时，新请求会失败，不会经宿主机直接出站；健康守护随后可以尝试恢复服务。此保护依赖内核防火墙，不依赖健康检查的轮询间隔。

### 4. DNS 与认证

namespace 默认 DNS：

```text
NETNS_DNS_SERVERS="1.1.1.1 1.0.0.1"
```

可配置空格分隔的 IPv4 DNS 服务器，所选服务器需要能从 namespace 的网络路径访问。默认不复制宿主机私网/VPC DNS，避免 WARP 默认路由将私网解析请求送往不可达出口。依赖内部域名的应用需要另行设计解析和路由；填写宿主机私网 DNS 地址并不自动建立可达路径。

账户下载/初始化和隧道 Endpoint 的初始域名解析在宿主机完成。域名候选需要宿主机的 `getent` 与 `timeout`，优先解析为 IPv4；解析失败会继续尝试备用候选。应用 DNS 没有直连例外，隧道断开时也会被阻断。

通过 SOCKS5 使用认证时，在私有环境文件同时设置：

```text
SOCKS_USER='your-user'
SOCKS_PASS='your-password'
```

用户名和密码必须同时设置或同时留空，并在客户端配置相同凭据。SOCKS5 用户名/密码认证本身不加密客户端到代理的连接；入口应仅对受控网络开放。

### 5. 可选模式：宿主机全局出口

仅在明确需要改变宿主机 IPv4 路由时配置：

```text
CFWARP_MODE=host-global
BIND_ADDR=127.0.0.1
```

然后重启服务。此模式由 `wg-quick` 在宿主机处理 IPv4 路由，可能改变远程管理和现有服务的流量路径。切换前应保留可恢复服务器网络的访问方式。无认证监听通配地址会被拒绝；即使启用认证，也应通过宿主机防火墙限制访问。

`host-global` 不提供 namespace 模式的故障出口阻断；需要“隧道故障时阻止直连”的应用应使用默认 namespace 模式。

### 6. 服务、健康检查与诊断

安装器提供统一管理入口，也可以继续直接使用 systemd 和脚本：

```bash
sudo /opt/cfwarp/bin/cfwarp status
sudo /opt/cfwarp/bin/cfwarp logs -n 100
sudo /opt/cfwarp/bin/cfwarp health --wait
sudo /opt/cfwarp/bin/cfwarp doctor
sudo /opt/cfwarp/bin/cfwarp env
```

`env` 仅输出配置文件路径，不打印配置内容或密码。其他子命令包括 `start`、`stop`、`restart`、`refresh` 和 `exec`。管理入口位于安装目录的 `cfwarp`，默认 `bin/cfwarp` 是对应链接。

```bash
sudo systemctl start cfwarp.service
sudo systemctl stop cfwarp.service
sudo systemctl restart cfwarp.service
sudo systemctl status cfwarp.service
sudo journalctl -u cfwarp.service -n 100 --no-pager
sudo /opt/cfwarp/cfwarp-healthcheck.sh --wait
sudo /opt/cfwarp/cfwarp-healthcheck.sh --format env
sudo /opt/cfwarp/cfwarp-doctor.sh
sudo /opt/cfwarp/cfwarp-doctor.sh --fix
```

`CFWARP_HEALTH_OK=1` 表示这次 SOCKS5 请求成功，且 trace 中 WARP 状态为 `on` 或 `plus`。`CFWARP_TOTAL_MS` 是 trace 请求耗时，不是带宽测量。可用 `--metrics-file /run/cfwarp/health.env` 保存健康结果。

watchdog 默认每五分钟检查一次，连续失败达到阈值后才尝试恢复，并设有重启冷却时间。手动停止的服务不会被正常的健康守护自动启动。具体参数见 [环境模板](deploy/cfwarp.env.example)。

`doctor` 检查安装、配置权限、服务状态和适用的运行状态；`--fix` 仅修复文档化的文件权限与运行目录问题。它不是完整安全审计或真实性能测试。

### 7. Endpoint 选择与刷新

留空时采用现有运行配置或生成 profile 中的 Endpoint。显式配置的 `ENDPOINT_IP` 优先尝试；`ENDPOINT_CANDIDATES` 是可选候选列表：

```text
ENDPOINT_IP=<host-or-ip>:<port>
ENDPOINT_CANDIDATES=<host-or-ip>:<port>,<host-or-ip>:<port>
```

地址格式为 `host:port` 或 `[ipv6]:port`；IPv6 Endpoint 格式支持不代表提供 IPv6 WARP 出站。

每日自动刷新默认关闭，可在安装时添加 `--enable-refresh-timer` 启用。默认的 `CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip` 会在主服务运行时跳过刷新；定时器不会默认停服测速。

只有需要中断活动服务进行评估时，才设置：

```text
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=stop-and-probe
```

探测复用同一 WireGuard 身份并串行运行，避免多个探测隧道相互影响。每个候选受超时控制，退出时终止探测再清理其资源。当前 Endpoint 健康时，仅在达到改善阈值后切换；当前 Endpoint 不可用时，可以选择已验证可用的候选。恢复服务失败时尝试回滚原配置。测量只用于当时的候选比较，不证明长期带宽或稳定性。

若切换验证、配置恢复或探测资源清理失败，原配置、日志与 `RECOVERY.txt` 保留在数据目录的 `recovery/endpoint-refresh-*` 中（默认 `/var/lib/cfwarp/recovery`）。目录权限 0700，文件权限 0600；日志会给出具体路径。恢复不完整时不自动启动半恢复的配置。按说明恢复并验证后再删除该次目录；备份包含凭证，不能公开或当作 Shell 脚本执行。

手动触发与查看日志：

```bash
sudo systemctl start cfwarp-endpoint-refresh.service
sudo journalctl -u cfwarp-endpoint-refresh.service -n 100 --no-pager
```

### 8. 升级与清理

升级前备份私有配置和账户数据，在新版源码目录运行安装器：

```bash
sudo cp -a /etc/cfwarp /root/cfwarp-config-backup
sudo cp -a /var/lib/cfwarp /root/cfwarp-data-backup
sudo ./install.sh --start
```

已有合法数据目录配置会被保留；显式改变 `--data-dir` 不会自动搬迁账户。自定义安装需使用对应路径备份并再次传入安装参数。

清理生成的运行文件、二进制和 systemd units：

```bash
sudo systemctl stop cfwarp.service
sudo ./install.sh --clean-generated
```

私有环境文件和 WARP 数据保留，便于恢复或另行处理。先处理停止失败，再进行文件清理；删除运行文件不等于已经清除了内核网络资源。

没有 `--force` 时，主服务、watchdog 或 Endpoint 刷新服务仍在运行都会拒绝清理，保留其状态与定时器；检查也会在取得安装锁后重复，避免等待锁期间状态改变。

## English

### 1. Install and start

Use a Linux server with systemd, in-kernel WireGuard, network namespaces, and iptables. Installation, network setup, and namespace entry require root. Applications connecting to the SOCKS5 proxy do not need root.

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

A new installation prepares files and enables startup at boot; add `--start` to start or restart immediately. An upgrade restores a service that was running before installation. When the tunnel profile is missing, startup reuses an existing WARP account to generate it. It runs `wgcf register --accept-tos` only when no account exists. The default `wgcf` download is version-pinned and SHA256-verified; MicroSOCKS is built from a pinned commit.

Defaults are `/opt/cfwarp` for runtime files, `/etc/cfwarp/cfwarp.env` for private configuration, and `/var/lib/cfwarp` for account and tunnel data. Custom paths:

```bash
sudo ./install.sh --prefix /opt/cfwarp-custom \
  --env-dir /etc/cfwarp-custom --data-dir /var/lib/cfwarp-custom \
  --bin-dir /opt/cfwarp-custom/bin
```

Use absolute paths controlled by root. The installer records paths in `deploy/installation.env` under the runtime directory, so systemd and directly invoked helpers locate the same configuration. This generated file is excluded from version control. Repeat the same path options when upgrading or cleaning a custom installation.

### 2. Configuration and precedence

The environment file is single-line `KEY=VALUE` data. Single and double quotes are supported; inside double quotes, backslashes, double quotes, dollar signs, and backticks can be escaped. It is not an executable Shell script: commands and variable expansion are not evaluated, and multiline values are unsupported. Quote values containing spaces.

```text
CFWARP_MODE=netns-proxy
CFWARP_DATA_DIR='/var/lib/cfwarp'
NETNS_DNS_SERVERS="1.1.1.1 1.0.0.1"
```

Explicit CLI options take precedence over their corresponding settings. Exported process environment variables override file values; configuration files, installation-record path defaults, and script defaults follow in that order. `CFWARP_ENV_FILE` can select a configuration path. Otherwise, installed helpers use the installation record; source-tree execution falls back to default configuration discovery. Shared loading passes resolved settings to child processes without reloading stale values over the caller's choices.

Check another configuration temporarily:

```bash
sudo env CFWARP_ENV_FILE=/etc/cfwarp-custom/cfwarp.env \
  /opt/cfwarp-custom/cfwarp-healthcheck.sh
```

Keep the environment file at mode `0600` and the WARP data directory at `0700`. Do not publish keys, accounts, proxy passwords, or tokens in issues, screenshots, or logs.

### 3. Default mode: per-application egress

`netns-proxy` runs WARP and SOCKS5 in a separate namespace. Default endpoint:

```text
socks5h://169.254.240.2:1080
```

Examples:

```bash
curl --proxy socks5h://169.254.240.2:1080 https://www.cloudflare.com/cdn-cgi/trace
ALL_PROXY=socks5h://169.254.240.2:1080 curl https://www.cloudflare.com/cdn-cgi/trace
```

`socks5h` delegates destination DNS resolution to the proxy; `socks5` may resolve locally. The application must support the chosen proxy setting. Setting `ALL_PROXY` does not force every program to use a proxy.

Commands without a proxy option can run inside the namespace:

```bash
sudo /opt/cfwarp/cfwarp-exec curl https://www.cloudflare.com/cdn-cgi/trace
```

This requires root and runs the command as root. Execution is refused if the namespace is absent, ownership or egress protection does not match, or the tunnel lacks a recent handshake or a ready route. It is also unavailable in `host-global` mode. Current WARP egress is IPv4 only; SOCKS5 forwards TCP and does not provide UDP proxying.

The default mode preserves the host default route but creates veth devices and project-owned NAT/forwarding rules, enabling IPv4 forwarding when needed. Shutdown uses recorded ownership for cleanup; existing external resources with matching names must not be treated as available for takeover.

The namespace egress firewall is installed before connectivity is established. If the tunnel interface or routes disappear, new requests fail instead of leaving directly through the host; the watchdog can subsequently attempt recovery. This protection relies on the kernel firewall rather than the health-check polling interval.

### 4. DNS and authentication

Default namespace DNS:

```text
NETNS_DNS_SERVERS="1.1.1.1 1.0.0.1"
```

You can specify space-separated IPv4 DNS servers that are reachable through the namespace's network path. Host private/VPC resolvers are not copied by default, because WARP's default route can send private DNS requests to an unreachable destination. Applications requiring internal domains need a separate DNS/routing design; entering a private resolver address does not create a route to it.

Account downloads/initialization and initial tunnel-endpoint DNS resolution run on the host. Domain candidates require host `getent` and `timeout`, resolving to IPv4; failed resolution falls through to backup candidates. Application DNS has no direct-egress exception and is blocked when the tunnel is unavailable.

To enable SOCKS5 authentication, set both values in the private configuration:

```text
SOCKS_USER='your-user'
SOCKS_PASS='your-password'
```

Set both or leave both empty, and configure matching client credentials. SOCKS5 username/password authentication does not encrypt the client-to-proxy connection. Restrict the listener to a controlled network.

### 5. Optional host-wide egress

Only when host IPv4 routing changes are intended, set:

```text
CFWARP_MODE=host-global
BIND_ADDR=127.0.0.1
```

Restart the service afterward. `wg-quick` manages IPv4 routing on the host in this mode, which can change the traffic path for remote administration and existing services. Keep a way to recover server networking before switching. Unauthenticated wildcard listeners are rejected; restrict access with the host firewall even when authentication is enabled.

`host-global` does not provide namespace mode's fail-closed protection. Use default namespace mode for applications that must block direct egress when the tunnel fails.

### 6. Service management and diagnostics

The installer provides a unified entry point; systemd and the individual scripts remain available:

```bash
sudo /opt/cfwarp/bin/cfwarp status
sudo /opt/cfwarp/bin/cfwarp logs -n 100
sudo /opt/cfwarp/bin/cfwarp health --wait
sudo /opt/cfwarp/bin/cfwarp doctor
sudo /opt/cfwarp/bin/cfwarp env
```

`env` prints only the configuration path, not its contents or passwords. Other commands are `start`, `stop`, `restart`, `refresh`, and `exec`. The entry point is `cfwarp` in the installation directory; the default `bin/cfwarp` links to it.

```bash
sudo systemctl start cfwarp.service
sudo systemctl stop cfwarp.service
sudo systemctl restart cfwarp.service
sudo systemctl status cfwarp.service
sudo journalctl -u cfwarp.service -n 100 --no-pager
sudo /opt/cfwarp/cfwarp-healthcheck.sh --wait
sudo /opt/cfwarp/cfwarp-healthcheck.sh --format env
sudo /opt/cfwarp/cfwarp-doctor.sh
sudo /opt/cfwarp/cfwarp-doctor.sh --fix
```

`CFWARP_HEALTH_OK=1` means that request succeeded through SOCKS5 and the trace reported `warp=on` or `warp=plus`. `CFWARP_TOTAL_MS` measures trace request duration, not bandwidth. Add `--metrics-file /run/cfwarp/health.env` to save health results.

The watchdog checks approximately every five minutes by default, attempts recovery after repeated failures reach the threshold, and applies a restart cooldown. Normal watchdog operation respects a manually stopped service. See the [environment template](deploy/cfwarp.env.example) for settings.

`doctor` checks installation files, configuration permissions, service status, and applicable runtime state. `--fix` only repairs documented file permissions and runtime-directory issues. It is not a comprehensive security audit or performance test.

### 7. Endpoint selection and refresh

When unset, the endpoint comes from existing runtime configuration or a generated profile. Explicit `ENDPOINT_IP` is attempted first; `ENDPOINT_CANDIDATES` provides optional alternatives:

```text
ENDPOINT_IP=<host-or-ip>:<port>
ENDPOINT_CANDIDATES=<host-or-ip>:<port>,<host-or-ip>:<port>
```

Use `host:port` or `[ipv6]:port`. An IPv6 endpoint format does not imply IPv6 WARP egress support.

Daily refresh is disabled by default; add `--enable-refresh-timer` during installation to enable it. The default `CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip` skips refresh while the main service is active. The timer does not stop the service by default.

Only when interrupting the active service for evaluation is intended, set:

```text
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=stop-and-probe
```

Probes reuse one WireGuard identity and run sequentially to avoid interfering with each other. Candidates have bounded execution time; shutdown stops probing before cleaning resources. When the current endpoint is healthy, switching requires the improvement threshold to be met. When it is unavailable, a verified working candidate may be selected. If service recovery fails, refresh attempts to restore the old configuration. Measurements compare candidates at that time; they do not establish long-term bandwidth or reliability.

If switch verification, configuration restoration, or probe cleanup fails, originals, logs, and `RECOVERY.txt` remain in `recovery/endpoint-refresh-*` under the data directory (default `/var/lib/cfwarp/recovery`). Directories use mode 0700 and files mode 0600; logs identify the specific path. Incomplete configuration restoration prevents automatic restart. Follow the instructions and verify recovery before deleting that run's directory. Backups contain credentials; do not publish or source them as Shell code.

Trigger manually and inspect logs:

```bash
sudo systemctl start cfwarp-endpoint-refresh.service
sudo journalctl -u cfwarp-endpoint-refresh.service -n 100 --no-pager
```

### 8. Upgrade and cleanup

Back up private configuration and account data, then run the installer from the new source checkout:

```bash
sudo cp -a /etc/cfwarp /root/cfwarp-config-backup
sudo cp -a /var/lib/cfwarp /root/cfwarp-data-backup
sudo ./install.sh --start
```

An existing valid data-directory setting is preserved. Explicitly changing `--data-dir` does not migrate account files. For custom installations, back up the corresponding paths and repeat the installation options.

Remove generated runtime files, binaries, and systemd units:

```bash
sudo systemctl stop cfwarp.service
sudo ./install.sh --clean-generated
```

Private configuration and WARP data remain available for recovery or separate handling. Resolve any shutdown failure before cleaning files: deleting runtime files does not prove kernel network resources were removed.

Without `--force`, an active main, watchdog, or endpoint-refresh service causes cleanup to be refused while preserving service and timer state. Checks repeat after acquiring the installation lock to detect changes while waiting.
