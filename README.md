# CFwarp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/killertop/CFWarp/actions/workflows/ci.yml/badge.svg)](https://github.com/killertop/CFWarp/actions/workflows/ci.yml)

[中文说明](#chinese) | [English](#english)

---

<a name="chinese"></a>
## 🇨🇳 中文说明

### 项目价值与核心优势
CFwarp 是一个专为 Linux 裸机服务器设计的轻量级 Cloudflare WARP 出站代理方案。它主要解决以下核心痛点：
1. **免污染宿主机路由**：默认采用独立 Linux network namespace，WARP 出口仅供给指定应用，不改写宿主机默认路由，不影响 VPS 原有网络拓扑与外部连通性。
2. **极低资源开销**：基于内核态 WireGuard 与轻量级 C 编写的 MicroSOCKS，常驻内存占用不足 10MB，CPU 消耗微乎其微。
3. **原生生态融合**：标准 TCP SOCKS5 入口（支持本地 DNS 防泄漏 `socks5h`），无需安装客户端即可对接任何支持代理的爬虫、服务或反向代理；针对不支持代理的命令行程序提供 `cfwarp-exec`。
4. **生产级健壮性**：内置自愈 Watchdog、版本哈希强校验、精确的 iptables 规则管理（绝不误删其他业务规则）、内核 IPv4 转发引用计数锁以及只读优先的 `cfwarp-doctor.sh` 诊断工具。

本项目源自 [MicroWARP](https://github.com/ccbkkb/MicroWARP)，保留其 MIT 许可证与署名，当前代码作为独立的 CFwarp 裸机发行版维护。详见 [NOTICE.md](NOTICE.md) 与 [PROJECT.md](PROJECT.md)。

> ⚠️ **合规声明**：请遵守适用的法律法规及服务条款。CFwarp 不提供匿名性或合规性保证。

### 架构特性
- **部署形态**：面向 Linux + systemd 裸机设计，摒弃容器化带来的额外网络层与特权容器复杂性。
- **双模式支持**：
  - `netns-proxy`（默认）：WARP 运行于隔离 namespace，宿主机通过 veth 连接 `169.254.240.2:1080`。
  - `host-global`（可选）：显式配置时接管宿主机全局 WireGuard 路由。
- **安全与沙箱**：systemd 服务默认启用 `ProtectHome=read-only`、`PrivateTmp`、`NoNewPrivileges`。
- **依赖固定**：默认固定 `wgcf 2.2.30` 并内置 `amd64` / `arm64` SHA256 校验；源码构建固定 commit 的 `microsocks`。

### 快速开始

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

| 内容 | 默认路径 |
| --- | --- |
| 运行脚本 | `/opt/cfwarp` |
| 私有环境文件 | `/etc/cfwarp/cfwarp.env`，权限 0600 |
| WARP 账户和 WireGuard 状态 | `/var/lib/cfwarp`，权限 0700 |
| systemd units | `/etc/systemd/system` |

### 接入与使用示例

**1. 应用程序直接使用 SOCKS5（推荐 `socks5h` 防止本地 DNS 泄漏）**：
```bash
ALL_PROXY=socks5h://169.254.240.2:1080 curl -fsS https://1.1.1.1/cdn-cgi/trace
```

**2. 针对不支持代理的命令行工具使用 `cfwarp-exec`**：
```bash
/opt/cfwarp/cfwarp-exec curl -fsS https://1.1.1.1/cdn-cgi/trace
```

### 服务管理与日常运维

```bash
# 检查运行状态与日志
sudo systemctl status cfwarp.service
sudo journalctl -u cfwarp.service -n 100 --no-pager

# 链路健康检查（检查 SOCKS5 连通性与 WARP Trace 状态）
sudo /opt/cfwarp/cfwarp-healthcheck.sh

# 系统自检（检查权限、iptables 规则、namespace 与服务健康度）
sudo /opt/cfwarp/cfwarp-doctor.sh

# 自动修复轻微权限与文件锁异常
sudo /opt/cfwarp/cfwarp-doctor.sh --fix
```

详细参数与高阶用法请参阅 [USAGE.md](USAGE.md)。

---

<a name="english"></a>
## 🌐 English Description

### Project Value & Key Advantages
CFwarp is an ultra-lightweight Cloudflare WARP egress proxy designed specifically for bare-metal Linux servers.
1. **Zero Host Route Pollution**: Operates in an isolated Linux network namespace by default. WARP is only accessible to designated apps without altering default host routes or VPS network topology.
2. **Minimal Resource Footprint**: Powered by in-kernel WireGuard and lightweight C-based MicroSOCKS. Memory consumption is typically < 10MB with negligible CPU overhead.
3. **Drop-in Ecosystem Integration**: Provides a standard TCP SOCKS5 endpoint (`socks5h://169.254.240.2:1080`) to prevent DNS leaks, plus a `cfwarp-exec` CLI wrapper for tools lacking native proxy capabilities.
4. **Production-grade Hardening**: Includes an auto-healing watchdog, strict checksum validation for binaries, precise iptables lifecycle management (never flushing foreign rules), ref-counted IPv4 forwarding locks, and a non-destructive doctor utility.

Derived from [MicroWARP](https://github.com/ccbkkb/MicroWARP) under the MIT License. See [NOTICE.md](NOTICE.md) and [PROJECT.md](PROJECT.md).

### Architecture & Features
- **Deployment Model**: Engineered for Linux + systemd bare-metal; eliminates container runtime overhead and privileged container security risks.
- **Dual Operation Modes**:
  - `netns-proxy` (Default): WARP runs in an isolated namespace. The host reaches SOCKS5 via veth pair at `169.254.240.2:1080`.
  - `host-global` (Optional): Explicitly takes over system-wide routing via WireGuard.
- **Security & Sandboxing**: systemd service unit enforces `ProtectHome=read-only`, `PrivateTmp`, and `NoNewPrivileges`.
- **Pinned Dependencies**: Bundles pinned `wgcf 2.2.30` with SHA256 integrity verification; builds `microsocks` from a fixed commit hash.

### Quick Start

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

| Item | Default Path |
| --- | --- |
| Runtime Scripts | `/opt/cfwarp` |
| Private Config | `/etc/cfwarp/cfwarp.env` (0600) |
| WARP Account & State | `/var/lib/cfwarp` (0700) |
| systemd Units | `/etc/systemd/system` |

### Integration Examples

**1. Direct SOCKS5 proxy usage (use `socks5h` to resolve domain remotely)**:
```bash
ALL_PROXY=socks5h://169.254.240.2:1080 curl -fsS https://1.1.1.1/cdn-cgi/trace
```

**2. Run arbitrary command inside WARP namespace**:
```bash
/opt/cfwarp/cfwarp-exec curl -fsS https://1.1.1.1/cdn-cgi/trace
```

### Service Control & Diagnostics

```bash
# Check status and journal logs
sudo systemctl status cfwarp.service
sudo journalctl -u cfwarp.service -n 100 --no-pager

# Validate end-to-end proxy connectivity & WARP status
sudo /opt/cfwarp/cfwarp-healthcheck.sh

# System diagnostic check (permissions, rules, namespace health)
sudo /opt/cfwarp/cfwarp-doctor.sh

# Safe autofix for permission / stale state issues
sudo /opt/cfwarp/cfwarp-doctor.sh --fix
```

For comprehensive parameters and advanced configurations, see [USAGE.md](USAGE.md).

---

## 📄 License & Community

- Licensed under the [MIT License](LICENSE).
- Contribution guidelines: [CONTRIBUTING.md](CONTRIBUTING.md).
- Security policy: [SECURITY.md](SECURITY.md).
