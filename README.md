# CFWarp — Cloudflare WARP SOCKS5 Proxy for Linux

**Linux 服务器上的 Cloudflare WARP SOCKS5 代理：按应用选择 WARP 出口，默认保留宿主机路由。**

**Route selected Linux applications through Cloudflare WARP with a TCP SOCKS5 proxy, WireGuard, and an isolated network namespace. Preserve the host default route by default.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/killertop/CFWarp/actions/workflows/ci.yml/badge.svg)](https://github.com/killertop/CFWarp/actions/workflows/ci.yml)

[中文](#中文) · [English](#english) · [使用说明 / Usage](USAGE.md) · [架构 / Architecture](docs/architecture.md) · [验证记录 / Validation](docs/validation-refresh-2026-09-10.md)

## 中文

### Linux 上的 Cloudflare WARP SOCKS5 代理

CFWarp 将 Cloudflare WARP 封装为 Linux 服务器上的 **TCP SOCKS5 出站代理**。默认模式把 WARP 隧道和代理放进独立的 network namespace（网络命名空间）；只有配置了代理的应用，或通过 `cfwarp-exec` 启动的命令，使用这条出口。

适合希望为某个后端服务、脚本或下载任务配置 WARP 出口，同时保留服务器原有默认出口的用户。无需为此给整台服务器切换 VPN，也不需要容器运行时。

```text
指定应用 → SOCKS5 → 独立 network namespace → WireGuard → Cloudflare WARP → Internet
其他宿主机应用 → 原有默认出口
```

### 适合哪些使用场景

- **Linux VPS 按应用代理**：让指定后端服务使用 WARP 出口，其他宿主机应用继续使用原有默认出口。
- **命令行与脚本联网**：为支持 SOCKS5 的 curl 请求、下载工具和自动化脚本配置代理，并通过 `socks5h` 在代理端解析域名。
- **不支持代理配置的程序**：通过 `cfwarp-exec` 在 WARP 网络命名空间内启动命令，需要 root 权限。
- **长期运行的服务器服务**：使用 systemd、健康检查和 watchdog 管理代理及隧道状态。

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

#### 如何只让一个 Linux 应用使用 Cloudflare WARP？

在默认 `netns-proxy` 模式下，将该应用的 SOCKS5 代理配置为 `169.254.240.2:1080`。对于支持 URL 形式代理的客户端，使用 `socks5h://169.254.240.2:1080` 可将目标域名交给代理端解析。完整示例见 [按应用使用 WARP](USAGE.md#3-默认模式按应用使用)。

#### CFWarp 会修改服务器默认路由吗？

默认模式保留宿主机默认路由，在独立网络命名空间中配置 WARP 路由；安装仍会创建 veth 和转发/NAT 规则。可选 `host-global` 模式会修改宿主机 IPv4 路由，详见 [全局出口配置](USAGE.md#5-可选模式宿主机全局出口)。

#### 支持 UDP、IPv6 出站或 Docker 部署吗？

当前支持 TCP SOCKS5 和 IPv4 WARP 出站，不提供 UDP 代理或 IPv6 WARP 出站。部署使用 Linux 与 systemd，无需 Docker；项目目前不提供 Docker/Compose 镜像。完整边界见 [项目范围](PROJECT.md#中文)。

## English

### Cloudflare WARP as a Linux SOCKS5 proxy

CFWarp exposes Cloudflare WARP as a **TCP SOCKS5 egress proxy for Linux servers**. By default, the WARP tunnel and proxy run inside a separate network namespace. Applications use this egress when configured to use the proxy, or when launched through `cfwarp-exec`.

Use it to give a backend service, script, or download job a WARP connection while keeping the server's existing default egress. It requires no container runtime or host-wide VPN switch.

```text
Selected app → SOCKS5 → separate network namespace → WireGuard → Cloudflare WARP → Internet
Other host apps → existing default egress
```

### Use cases

- **Per-app proxy on a Linux VPS:** send a selected backend service through WARP while other host applications retain their existing default egress.
- **Command-line tools and scripts:** configure SOCKS5 for curl requests, compatible download tools, and automation scripts; use `socks5h` for proxy-side DNS resolution.
- **Programs without proxy settings:** launch commands inside the WARP network namespace with `cfwarp-exec`, which requires root.
- **Long-running server services:** manage the proxy and tunnel with systemd, health checks, and a recovery watchdog.

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
