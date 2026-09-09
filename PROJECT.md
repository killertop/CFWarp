# CFWarp 项目范围 / Project scope

## 中文

CFWarp 为 Linux 服务器上的指定应用提供 Cloudflare WARP 出站。公开维护路径是 `systemd + network namespace + TCP SOCKS5`，默认不替换宿主机默认路由。

### 当前范围

- Linux 内核 WireGuard、network namespace、veth、iptables 与 systemd。
- IPv4 WARP 出站和 TCP SOCKS5；`socks5h` 代理端域名解析。
- `cfwarp-exec` 用于将命令放入已运行的 namespace，需要 root 权限。
- 显式选择的 `host-global` 模式，可改变宿主机 IPv4 路由。
- 本机私有配置、账户及运行状态；健康检查、watchdog 和可选 Endpoint 刷新。
- 按配置加载、资源归属、进程退出及回滚契约维护 Shell 控制层。语言评估见 [架构决定](docs/architecture.md)。

### 非目标

- UDP、HTTP 或透明代理；IPv6 WARP 出站；桌面或移动 VPN 客户端。
- Docker/Compose 镜像、GHCR 发布或 Kubernetes 控制器。
- 某台服务器、域名或第三方 API 专用的访问逻辑。
- 保证匿名性、固定出口地区、带宽、内存占用或某个网站的可访问性。

### 维护约定

配置、私钥、账户、令牌、生产日志和编译产物不进入版本库。修改路由、防火墙、namespace 或 sysctl 时，应有可识别的资源归属、失败处理与清理路径；不能按名称擅自接管其他程序的资源。涉及系统行为的修复需要 Linux 验证；静态检查、mock 回归和真实 WARP 测试分别记录，不互相替代。

## English

CFWarp provides Cloudflare WARP egress for selected applications on Linux servers. The maintained deployment is `systemd + network namespace + TCP SOCKS5`, preserving the host default route by default.

### Current scope

- In-kernel Linux WireGuard, network namespaces, veth, iptables, and systemd.
- IPv4 WARP egress and TCP SOCKS5, with proxy-side DNS through `socks5h`.
- `cfwarp-exec` to enter an existing namespace; root access is required.
- Explicitly selected `host-global` mode, which can change host IPv4 routing.
- Local private configuration, accounts, and runtime state; health checks, a watchdog, and optional endpoint refresh.
- A Shell control layer maintained around configuration, ownership, process shutdown, and rollback contracts. See the [architecture decision](docs/architecture.md).

### Non-goals

- UDP, HTTP, or transparent proxying; IPv6 WARP egress; desktop or mobile VPN clients.
- Docker/Compose images, GHCR publishing, or Kubernetes controllers.
- Access logic specific to one server, domain, or third-party API.
- Guarantees of anonymity, egress location, bandwidth, memory use, or website access.

### Maintenance rules

Keep configuration, private keys, accounts, tokens, production logs, and compiled artifacts out of version control. Route, firewall, namespace, and sysctl changes require identifiable ownership, failure handling, and cleanup. Do not take over resources belonging to another program based on names alone. Validate system behavior on Linux and report static checks, mocked regressions, and real WARP tests separately.
