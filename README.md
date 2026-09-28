# CFWarp — Cloudflare WARP SOCKS5 Proxy for Linux VPS & AI Apps

**为 Linux VPS、机房服务器和 AI 应用提供可管理的 WARP 替代出口：按应用接入，断隧道阻止直连，默认保留宿主机路由。**

**Give Linux VPS workloads and AI applications an alternative Cloudflare WARP egress, with per-app SOCKS5 routing, fail-closed protection, and automatic recovery. Preserve the host default route by default.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/killertop/CFWarp/actions/workflows/ci.yml/badge.svg)](https://github.com/killertop/CFWarp/actions/workflows/ci.yml)

[中文](#中文) · [English](#english) · [使用说明 / Usage](USAGE.md) · [架构 / Architecture](docs/architecture.md) · [验证记录 / Validation](docs/validation-2026-09-28.md)

## 中文

### Linux 上的 Cloudflare WARP SOCKS5 代理

CFWarp 将 Cloudflare WARP 封装为 Linux 服务器上的 **TCP SOCKS5 出站代理**。默认模式把 WARP 隧道和代理放进独立的 network namespace（网络命名空间）；只有配置了代理的应用，或通过 `cfwarp-exec` 启动的命令，使用这条出口。

当原生机房 IP 或直连路径访问目标服务不理想时，CFWarp 为指定应用增加一条经 Cloudflare WARP 出站的路径，无需先迁移服务器。适合 AI API 客户端、Agent 后端、自动化脚本和下载任务；其他宿主机应用继续使用原有默认出口，无需切换整机 VPN，也不需要 Docker。

```text
指定应用 → SOCKS5 → 独立 network namespace → WireGuard → Cloudflare WARP → Internet
其他宿主机应用 → 原有默认出口
```

### 为什么在 VPS 和机房服务器上使用 CFWarp

| 需求 | CFWarp 带来的价值 |
| --- | --- |
| 原生机房出口访问不理想 | 为选定请求使用 WARP 出口，提供另一条可测试的访问路径；可能改善与原出口 IP 或路由有关的可达性问题。 |
| AI API、Agent 与模型工具联网 | 将支持 SOCKS5 的 AI 客户端、推理 API 请求和自动化任务接入同一代理，便于统一配置与排障。 |
| 一台服务器运行多种业务 | 只给需要的应用配置代理；SSH 管理、网站和其他未选中的宿主机应用保留原有默认路由。 |
| 避免隧道中断后暴露原生出口 | 默认 namespace 模式阻止应用直连回落，健康守护再按策略尝试恢复。 |
| 希望减少手动运维 | 使用 systemd、健康检查、日志和带冷却期的 watchdog 管理长期运行；可选 Endpoint 刷新评估候选。 |
| 不想增加容器部署层 | 直接部署在 Linux 上，兼容 TCP SOCKS5；没有代理设置的命令可用需要 root 的 `cfwarp-exec`。 |

这里的“机房出口优化”是为应用更换出站路径，**不会改变原机房 IP 的历史信誉，也不提供住宅 IP、固定地区或 AI 服务必定可用的保证**。目标服务仍可能限制 WARP 出口。以你的服务器、账号和真实请求实测结果为准。

### AI 服务访问与实际验证

CFWarp 可作为 AI 应用的网络出口层，适用于支持 SOCKS5 的 API 客户端、Agent、批处理任务和基于 HTTPS 的流式请求。OpenAI/ChatGPT、Claude、Gemini 等服务是可按需测试的目标示例，项目不包含其专用解锁逻辑，也不代表已逐一验证可用。账号、API 权限、服务支持地区及目标平台策略仍适用。

先确认 WARP 隧道，再使用自己的客户端完成一次已授权的实际业务请求；流式应用还应检查完整响应能否结束。`warp=on`、网页能打开或收到 HTTP 响应，都不能单独证明模型调用成功。接入与排障步骤见 [AI 应用与机房出口验证](USAGE.md#ai-应用与机房出口验证)。

### 核心功能：按应用路由、DNS 与故障出口保护

- **按应用选择出口**：默认不替换宿主机默认路由，便于在一台服务器上同时运行使用不同出口的服务。
- **故障时阻止直连回落**：默认 namespace 模式在隧道就绪前、接口或路由丢失时阻断应用直连；应用 DNS 也通过隧道发送。
- **使用已有代理接口**：支持 SOCKS5 的应用直接接入；`socks5h` 将目标域名交给代理端解析。没有代理选项的命令可以通过 `cfwarp-exec` 在 namespace 中运行。
- **便于运维**：systemd 管理启动、停止和重启；健康检查验证 SOCKS5 与 WARP 状态，watchdog 在连续失败后按冷却策略尝试恢复。
- **状态留在自己的服务器**：私有配置、WARP 账户和 WireGuard 配置保存在本机；依赖版本固定，并校验默认 `wgcf` 下载。

### 运行条件与范围

需要 Linux、systemd、root 权限，以及内核 WireGuard、network namespace、veth 和 iptables 支持。默认 `wgcf` 下载覆盖 `amd64` / `arm64`。安装器安装系统依赖并编译 MicroSOCKS。

当前提供 **IPv4 WARP 出站和 TCP SOCKS5**；不提供 UDP 代理、HTTP 代理、透明代理或桌面 VPN 客户端。默认模式仍会创建 veth、添加本项目的转发/NAT 规则并按需启用 IPv4 转发，区别在于不替换宿主机默认路由。

可选的 `host-global` 模式会改变宿主机 IPv4 路由，不提供 namespace 模式的故障出口阻断，仅在明确需要整机出口时启用。实际连通性、速度和出口位置取决于服务器网络、WARP 及目标服务；项目不保证某个服务可访问，也没有固定内存或性能承诺。

### 快速开始：安装 WARP SOCKS5 代理

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

缺少隧道配置时，CFWarp 通过 `wgcf` 生成配置；已有账户会被复用，账户也不存在时才注册新账户，该注册使用接受服务条款的选项。账户初始化和隧道 Endpoint 的初始域名解析使用宿主机网络，在应用 namespace 启用前完成。日常健康守护默认启用；每日 Endpoint 刷新默认关闭。

确认出口：

```bash
curl --proxy socks5h://169.254.240.2:1080 https://www.cloudflare.com/cdn-cgi/trace
sudo /opt/cfwarp/cfwarp-healthcheck.sh
```

trace 中的 `warp=on` 或 `warp=plus` 表示该次请求通过 WARP。其他应用只需配置相同 SOCKS5 地址；普通应用使用代理不需要 root。

不支持代理的命令可以这样运行；进入 namespace 需要 root：

```bash
sudo /opt/cfwarp/cfwarp-exec curl https://www.cloudflare.com/cdn-cgi/trace
```

| 内容 | 默认路径 |
| --- | --- |
| 运行文件 | `/opt/cfwarp` |
| 私有配置，权限 0600 | `/etc/cfwarp/cfwarp.env` |
| WARP 账户与隧道配置，目录权限 0700 | `/var/lib/cfwarp` |
| systemd units | `/etc/systemd/system` |

安装器提供统一管理命令，`env` 仅显示配置路径：

```bash
sudo /opt/cfwarp/bin/cfwarp status
sudo /opt/cfwarp/bin/cfwarp logs -n 100
sudo /opt/cfwarp/bin/cfwarp health
sudo /opt/cfwarp/bin/cfwarp doctor
sudo /opt/cfwarp/bin/cfwarp env
```

更多配置、DNS、认证、自定义路径、Endpoint 管理和清理步骤见 [使用说明](USAGE.md#中文)。语言选择及验证边界见 [架构说明](docs/architecture.md#中文)。

### 常见问题

#### 能让机房 IP 变得更可靠吗？

CFWarp 让选定应用通过 WARP 出站，减少对原生机房出口的依赖；路由变化可能改善某些访问问题。它的可靠性设计体现在隧道故障时阻止直连、健康检查和恢复流程，而不是提升原 IP 的信誉评分。WARP 出口同样可能受目标服务限制。

#### 能用于访问 AI 服务吗？

可以作为 AI API 客户端的 SOCKS5 出口使用，具体能否调用目标模型需要实测。客户端必须真正支持并使用该代理，账号和地区也需满足目标服务要求。Cloudflare 说明 WARP 使用其出口 IP，服务商也会维护各自的地区支持范围；参见 [WARP FAQ](https://developers.cloudflare.com/warp-client/known-issues-and-faq/) 和 [OpenAI 支持地区](https://help.openai.com/en/articles/7947663-chatgpt-supported-countries)。

#### 如何只让一个 Linux 应用使用 Cloudflare WARP？

在默认 `netns-proxy` 模式下，将该应用的 SOCKS5 代理配置为 `169.254.240.2:1080`。对于支持 URL 形式代理的客户端，使用 `socks5h://169.254.240.2:1080` 可将目标域名交给代理端解析。完整示例见 [按应用使用 WARP](USAGE.md#3-默认模式按应用使用)。

#### CFWarp 会修改服务器默认路由吗？

默认模式保留宿主机默认路由，在独立网络命名空间中配置 WARP 路由；安装仍会创建 veth 和转发/NAT 规则。可选 `host-global` 模式会修改宿主机 IPv4 路由，详见 [全局出口配置](USAGE.md#5-可选模式宿主机全局出口)。

#### 支持 UDP、IPv6 出站或 Docker 部署吗？

当前支持 TCP SOCKS5 和 IPv4 WARP 出站，不提供 UDP 代理或 IPv6 WARP 出站。部署使用 Linux 与 systemd，无需 Docker；项目目前不提供 Docker/Compose 镜像。完整边界见 [项目范围](PROJECT.md#中文)。

## English

### Cloudflare WARP as a Linux SOCKS5 proxy

CFWarp exposes Cloudflare WARP as a **TCP SOCKS5 egress proxy for Linux servers**. By default, the WARP tunnel and proxy run inside a separate network namespace. Applications use this egress when configured to use the proxy, or when launched through `cfwarp-exec`.

When a datacenter IP or direct route has trouble reaching a destination, CFWarp gives selected applications another egress path through Cloudflare WARP without first moving the server. Use it for AI API clients, agent backends, automation, and downloads while other host applications keep their existing default egress. No host-wide VPN switch or Docker runtime is required.

```text
Selected app → SOCKS5 → separate network namespace → WireGuard → Cloudflare WARP → Internet
Other host apps → existing default egress
```

### Why use CFWarp on a VPS or datacenter server?

| Need | What CFWarp provides |
| --- | --- |
| Unsuitable native datacenter egress | A WARP exit for selected requests and another path to test; it may improve reachability problems related to the original IP or route. |
| AI APIs, agents, and model tools | A shared proxy endpoint for SOCKS5-capable AI clients, inference requests, and automation, simplifying configuration and troubleshooting. |
| Several workloads on one server | Apply the proxy only where needed; SSH administration, websites, and other unselected host applications retain their existing default route. |
| Protection against direct fallback | Default namespace mode blocks direct application traffic when the tunnel fails, while the watchdog attempts recovery. |
| Less manual operation | systemd, health checks, logs, and recovery cooldowns support long-running services; optional endpoint refresh evaluates candidates. |
| No extra container layer | Deploy directly on Linux with TCP SOCKS5; commands without proxy settings can use root-required `cfwarp-exec`. |

“Datacenter egress improvement” means changing the application’s outbound path. **It does not repair the original IP’s reputation or supply residential IPs, a fixed region, or guaranteed AI access.** Destinations may also restrict WARP exits. Validate with your own server, account, and actual requests.

### AI service access and verification

CFWarp can serve as the network egress layer for SOCKS5-capable AI API clients, agents, batch jobs, and HTTPS streaming requests. OpenAI/ChatGPT, Claude, and Gemini are examples of destinations to evaluate, not a list of verified integrations or built-in unblocking features. Account eligibility, API permissions, supported regions, and provider policies still apply.

Verify the WARP tunnel, then complete an authorized application request with your own client. For streaming applications, check that the full response completes. `warp=on`, a loading web page, or an HTTP response alone does not establish successful model access. See [AI applications and datacenter egress validation](USAGE.md#ai-applications-and-datacenter-egress-validation).

### Features: per-app routing, DNS, and fail-closed egress

- **Choose egress per application.** The default mode preserves the host default route, allowing services with different egress requirements to share a server.
- **Block direct fallback on failure.** Default namespace mode blocks direct application egress before tunnel readiness and if its interface or routes disappear. Application DNS also uses the tunnel.
- **Use standard proxy settings.** SOCKS5-capable applications connect directly; `socks5h` delegates destination DNS resolution to the proxy. Commands without proxy support can run inside the namespace using `cfwarp-exec`.
- **Operate through familiar tools.** systemd manages the service. Health checks verify SOCKS5 connectivity and WARP status; the watchdog attempts recovery after repeated failures, with a restart cooldown.
- **Keep configuration on your server.** Private settings, the WARP account, and WireGuard configuration remain local. Dependencies are pinned, and the default `wgcf` download is checksum-verified.

### Requirements and scope

Requires Linux, systemd, root access, and support for in-kernel WireGuard, network namespaces, veth, and iptables. Default `wgcf` downloads cover `amd64` and `arm64`. The installer installs system dependencies and builds MicroSOCKS.

The current scope is **IPv4 WARP egress and TCP SOCKS5**. It does not include UDP proxying, an HTTP proxy, transparent proxying, or a desktop VPN client. Default setup creates veth devices and project-owned forwarding/NAT rules, and enables IPv4 forwarding when needed; it preserves the host default route.

The optional `host-global` mode changes host IPv4 routing and does not provide namespace mode's fail-closed egress protection. Enable it only when host-wide egress is intended. Connectivity, speed, and egress location depend on the server network, WARP, and the destination service. No fixed resource footprint, performance, or access to a particular service is guaranteed.

### Quick start: install the WARP SOCKS5 proxy

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

When the tunnel profile is missing, CFWarp generates it through `wgcf`, reusing an existing account. It registers a new account only if no account exists; registration uses the accept-terms option. Account initialization and initial tunnel-endpoint DNS resolution use the host network before the application namespace is started. The health watchdog is enabled by default; daily endpoint refresh is disabled by default.

Verify the egress:

```bash
curl --proxy socks5h://169.254.240.2:1080 https://www.cloudflare.com/cdn-cgi/trace
sudo /opt/cfwarp/cfwarp-healthcheck.sh
```

A trace value of `warp=on` or `warp=plus` confirms WARP for that request. Configure other applications with the same SOCKS5 address; clients using the proxy do not need root.

For commands without proxy support, entering the namespace requires root:

```bash
sudo /opt/cfwarp/cfwarp-exec curl https://www.cloudflare.com/cdn-cgi/trace
```

| Item | Default path |
| --- | --- |
| Runtime files | `/opt/cfwarp` |
| Private configuration, mode 0600 | `/etc/cfwarp/cfwarp.env` |
| WARP account and tunnel configuration, directory mode 0700 | `/var/lib/cfwarp` |
| systemd units | `/etc/systemd/system` |

The installer provides a unified management command; `env` only displays the configuration path:

```bash
sudo /opt/cfwarp/bin/cfwarp status
sudo /opt/cfwarp/bin/cfwarp logs -n 100
sudo /opt/cfwarp/bin/cfwarp health
sudo /opt/cfwarp/bin/cfwarp doctor
sudo /opt/cfwarp/bin/cfwarp env
```

See [Usage](USAGE.md#english) for DNS, authentication, custom paths, endpoint management, and cleanup. See [Architecture](docs/architecture.md#english) for the language decision and validation boundaries.

### Frequently asked questions

#### Does it make a datacenter IP more reliable?

CFWarp gives selected applications a WARP egress path, reducing their dependence on native datacenter egress; a different route may improve some access problems. Its reliability features are fail-closed traffic handling, health checks, and recovery, rather than an improvement to the original IP’s reputation score. Destinations can still restrict WARP exits.

#### Can I use it for AI services?

Yes, as a SOCKS5 egress for AI API clients, subject to actual tests against the desired model. The client must support and use the proxy, and the account and region must meet the provider’s requirements. Cloudflare documents WARP’s use of its exit IPs, and providers publish their own regional availability; see the [WARP FAQ](https://developers.cloudflare.com/warp-client/known-issues-and-faq/) and [OpenAI supported countries](https://help.openai.com/en/articles/7947663-chatgpt-supported-countries).

#### How do I use Cloudflare WARP for only one Linux application?

In default `netns-proxy` mode, set that application's SOCKS5 proxy to `169.254.240.2:1080`. Clients accepting proxy URLs can use `socks5h://169.254.240.2:1080` to resolve destination names at the proxy. See [per-application WARP configuration](USAGE.md#3-default-mode-per-application-egress) for examples.

#### Does CFWarp change the server's default route?

Default mode preserves the host default route and configures WARP routing inside an isolated network namespace. Setup still creates veth devices and forwarding/NAT rules. Optional `host-global` mode changes host IPv4 routing; see [host-wide egress configuration](USAGE.md#5-optional-host-wide-egress).

#### Does it support UDP, IPv6 egress, or Docker deployment?

CFWarp currently supports TCP SOCKS5 and IPv4 WARP egress, without UDP proxying or IPv6 WARP egress. Deployment uses Linux and systemd with no Docker requirement; the project does not currently provide Docker/Compose images. See [project scope](PROJECT.md#english) for details.

## License

[MIT](LICENSE) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

CFWarp is not an official Cloudflare product and is not affiliated with Cloudflare.

CFWarp 不是 Cloudflare 官方产品，与 Cloudflare 无隶属关系。
