# MicroWARP 🚀

[![Docker Pulls](https://img.shields.io/badge/docker-ready-blue.svg)](https://github.com/ccbkkb/MicroWARP/packages)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> *请严格遵守您所在国家和地区的法律法规。任何因违法违规使用本项目而引发的法律纠纷或后果，均与本项目及作者无关。*
> 
> *Please strictly comply with the laws and regulations of your country and region. Any legal disputes or consequences arising from illegal use of this project have nothing to do with this project and its authors.*

[English](#english) |[中文说明](#chinese)

### 📊 Performance Comparison

Here is a real-world performance test on a 1C1G (1 vCPU, 1GB RAM) VPS, comparing MicroWARP with the widely used `caomingjun/warp`.

以下是在 1C1G 服务器上的真实运行数据截图对比：

| Metric (指标) | `caomingjun/warp` (Official Daemon) | 🚀 `MicroWARP` (Pure C + Kernel approach) | Improvement (提升) |
| :--- | :--- | :--- | :--- |
| **Image Size**<br>(Docker 镜像体积) | 201 MB | **9.08 MB** | 📉 **-95%** |
| **RAM Usage**<br>(日常内存占用) | ~150 MB | **800 KiB** (< 1MB) | 📉 **-99.4%** |
| **CPU Overhead**<br>(高并发 CPU 损耗) | High (Userspace App) | **~0.25%** (Kernel Space) | ⚡ **Near Zero** |
| **Core Engine**<br>(底层核心引擎) | Cloudflare `warp-cli` (Rust) | Linux `wg0` + Pure C `microsocks` | 🛠️ **Minimalist** |

> **🔥 Real `docker stats` output:**
> ```text
> CONTAINER ID   NAME       CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O
> 2fa58f84c517   warp       0.25%     800KiB / 967.4MiB     0.08%     48.8MB / 39.1MB   238kB / 36.9kB
> ```
> *Yes, you read that right. It processed ~90MB of traffic using only **800 KB** of RAM!* *是的，你没看错。它仅使用了 **800 KB** 的内存，就处理了约 90 MB 的流量！*

---

<a name="english"></a>
## 🇬🇧 English

A minimalist, high-performance Cloudflare WARP SOCKS5 proxy in Docker. 
Designed as a lightweight drop-in replacement for standard WARP proxy images (e.g., `caomingjun/warp`).

### 🌟 Why MicroWARP?

Many popular WARP Docker images rely on the official Cloudflare `warp-cli` daemon. This approach typically results in significant memory usage (often **150MB+**) and potential process overhead under high concurrency.

**MicroWARP** is built differently:
1. **Kernel-Level WireGuard**: Instead of the userspace client, it leverages the native Linux `wg0` interface for near-zero CPU overhead.
2. **MicroSOCKS Engine**: Uses a pure C-based `microsocks` server to minimize resource consumption.
3. **Minimal Memory Footprint**: Runs smoothly on **< 5MB RAM** (often ~800KB). Highly optimized for resource-constrained environments (e.g., 1C1G VPS).
4. **Seamless Tailscale Integration**: Natively resolves asymmetric routing blackholes, fully compatible with Tailnet inbound connections.
5. **Multi-Arch**: Native support for `amd64` and `arm64`.

### 🎯 Use Cases
*   **API Routing**: Route crawlers or AI API gateways (like Grok, ChatGPT) through MicroWARP to leverage high-trust Cloudflare IPs.
*   **Outbound Privacy**: Obfuscate your server's real IP by using WARP as your default egress network to prevent direct traceback.
*   **Sidecar Proxy**: Perfectly designed as an ultra-lightweight Docker Sidecar network gateway.

### 📦 Quick Start

Map port `1080` and grant `NET_ADMIN` privileges. Create a `docker-compose.yml`:

```yaml
services:
  microwarp:
    image: ghcr.io/ccbkkb/microwarp:latest
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - warp-data:/etc/wireguard # Keep account data to avoid rate limits

volumes:
  warp-data:
```

Run the container:
```bash
docker compose up -d
```

### 🖥 Bare-Metal Deploy

If you prefer running MicroWARP directly on a Linux host without Docker, the repository now includes an installer:

```bash
chmod +x install.sh
sudo ./install.sh
```

This installer will:
1. Install system dependencies (`wireguard-tools`, `iproute`, `iptables`, compiler toolchain, etc.)
2. Build and install `microsocks`
3. Copy the runtime files to `/opt/microwarp`
4. Reuse or create persistent WARP state under `/var/lib/microwarp`
5. Generate `/etc/microwarp/microwarp.env`
6. Generate a `systemd` service named `microwarp.service`

Bare-metal now defaults to `netns-proxy` mode:
1. WARP only takes over a dedicated Linux network namespace instead of the host default route
2. Your host projects connect to `${NETNS_PEER_HOST}:${BIND_PORT}` as a local-only SOCKS5 endpoint
3. For programs that cannot speak SOCKS directly, use `microwarp-exec <command...>` to run them inside the same namespace

If you explicitly want the old host-wide behavior, set `MICROWARP_MODE=host-global` in `/etc/microwarp/microwarp.env`.

For programmatic integration details, default SOCKS5 endpoint, and `microwarp-exec` usage, see [USAGE.md](./USAGE.md).

### ⚙️ Advanced Configurations

MicroWARP supports environment variables to customize your setup while keeping the memory footprint at 800KB:

```yaml
    environment:
      - BIND_ADDR=0.0.0.0     # Bind address
      - BIND_PORT=1080        # Custom SOCKS5 port
      - SOCKS_USER=admin      # Enable authentication
      - SOCKS_PASS=123456     # Auth password
      
      # ⚠️ Port Hopping (Mitigating Datacenter QoS):
      # If your VPS is in a datacenter (e.g., DMIT, AWS) where UDP 2408 is throttled or blocked,
      # use port 4500 (standard IPsec NAT-T) to bypass restrictive firewall rules.
      - ENDPOINT_IP=162.159.192.1:4500 
      - ENDPOINT_CANDIDATES=162.159.192.1:2408,162.159.192.1:4500,188.114.96.7:2408

      # Health-check tuning for slow or unstable networks:
      - WARP_READY_ATTEMPTS=6
      - WARP_READY_DELAY_SECONDS=2
      - WARP_HEALTHCHECK_CONNECT_TIMEOUT=4
      - WARP_HEALTHCHECK_TOTAL_TIMEOUT=8
      - WARP_HEALTHCHECK_TRACE_URL=https://1.1.1.1/cdn-cgi/trace
      - WARP_HEALTHCHECK_TEST_URL=https://www.gstatic.com/generate_204
```

These connectivity tuning variables can also be placed in `/etc/microwarp/microwarp.env` for bare-metal `netns-proxy` deployments; they are forwarded into the namespace where WARP actually runs.

---

<a name="chinese"></a>
## 🇨🇳 中文说明

一个极简、高性能的 Cloudflare WARP SOCKS5 Docker 代理。
致力于为服务器提供极低资源占用的出口网络解耦方案。

### 🌟 为什么选择 MicroWARP？

市面上大多数 WARP 镜像（例如 `caomingjun/warp`）依赖于 Cloudflare 官方的 `warp-cli` 守护进程。这种方式通常会导致较高的内存占用（约 **150MB+**），且在高并发场景下存在一定的性能瓶颈。

**MicroWARP** 采用了不同的底层架构：
1. **内核级 WireGuard**：采用 Linux 原生内核态的 `wg0` 接口接管流量，CPU 损耗近乎为零。
2. **MicroSOCKS 引擎**：使用纯 C 语言编写的 `microsocks` 服务器，极大降低资源消耗。
3. **极低内存占用**：高并发下内存占用依然 **< 5MB**（实测常驻 800KB 左右），专为资源受限的云服务器环境打造。
4. **原生兼容 Tailscale**：智能保留回程路由，解决全局接管导致的非对称路由黑洞，兼容异地组网直连。
5. **多架构支持**：原生支持 `amd64` 和 `arm64`（兼容 ARM 架构机器）。

### 🎯 典型应用场景
**⚠️ 声明：本项目专为服务端 (Server-side) 设计，并非个人电脑本地代理软件。**

1. **API 网络路由**：为服务器上的爬虫或大模型 API 网关（如 Grok / ChatGPT）提供稳定的 Cloudflare 出口 IP。
2. **服务端出口隐私**：挂载 MicroWARP 作为服务器的出站网关，隐藏 VPS 真实 IP，降低遭到溯源扫描的风险。
3. **微服务 Sidecar**：极低的资源占用使其非常适合作为 Docker Sidecar 容器，为特定的后端服务提供独立的网络出口。

### 📦 快速开始

只需映射 `1080` 端口并赋予容器 `NET_ADMIN` 权限。新建一个 `docker-compose.yml`：

```yaml
services:
  microwarp:
    image: ghcr.io/ccbkkb/microwarp:latest
    container_name: microwarp
    restart: always
    ports:
      - "127.0.0.1:1080:1080" # 默认无密码 SOCKS5 端口，仅监听本机
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - warp-data:/etc/wireguard # 持久化保存账号凭证

volumes:
  warp-data:
```

启动容器：
```bash
docker compose up -d
```

### 🖥 裸机部署

如果你不想依赖 Docker，现在仓库已经自带裸机安装脚本：

```bash
chmod +x install.sh
sudo ./install.sh
```

安装脚本会自动完成这些事：
1. 安装 `wireguard-tools`、`iproute`、`iptables`、编译工具链等系统依赖
2. 编译并安装 `microsocks`
3. 将运行文件安装到 `/opt/microwarp`
4. 复用或创建 `/var/lib/microwarp` 下的 WARP 持久化状态
5. 生成环境文件 `/etc/microwarp/microwarp.env`
6. 生成 `systemd` 服务 `microwarp.service`

裸机模式现在默认使用 `netns-proxy`：
1. WARP 只接管独立的 Linux network namespace，不再默认改宿主机主路由
2. 宿主机上的项目直接连接 `${NETNS_PEER_HOST}:${BIND_PORT}` 作为本地 SOCKS5 入口
3. 对于不支持 SOCKS 的程序，可以使用 `microwarp-exec <command...>` 把它直接放进同一个 namespace 里运行

如果你明确需要旧的宿主机全局模式，再把 `/etc/microwarp/microwarp.env` 里的 `MICROWARP_MODE` 改成 `host-global`。

如果你需要给其他程序接入默认 SOCKS5 地址、了解 `microwarp-exec` 的调用方式，见 [USAGE.md](./USAGE.md)。

### ⚙️ 进阶配置：认证与网络连通性优化

MicroWARP 支持通过环境变量进行参数定制：

```yaml
    environment:
      - BIND_ADDR=0.0.0.0     # 监听地址 (默认 0.0.0.0)
      - BIND_PORT=1080        # 监听端口 (默认 1080)
      - SOCKS_USER=admin      # SOCKS5 认证用户名 (留空则为无密码模式)
      - SOCKS_PASS=123456     # SOCKS5 认证密码
      - GH_PROXY=https://github.ednovas.xyz # 代理 wgcf 二进制下载地址
      
      # ⚠️ 网络连通性优化 (Port Hopping)
      # 针对部分对 UDP 2408 端口存在 QoS 限制的机房（如 DMIT、搬瓦工等）。
      # 可将端口修改为 4500 (标准 IPsec NAT-T 端口) 规避审查特征，提升连通率。
      - ENDPOINT_IP=162.159.192.1:4500
      - ENDPOINT_CANDIDATES=162.159.192.1:2408,162.159.192.1:4500,188.114.96.7:2408

      # WARP 就绪检查与重试参数
      - WARP_READY_ATTEMPTS=6
      - WARP_READY_DELAY_SECONDS=2
      - WARP_HEALTHCHECK_CONNECT_TIMEOUT=4
      - WARP_HEALTHCHECK_TOTAL_TIMEOUT=8
      - WARP_HEALTHCHECK_TRACE_URL=https://1.1.1.1/cdn-cgi/trace
      - WARP_HEALTHCHECK_TEST_URL=https://www.gstatic.com/generate_204
```

以上这些连通性调优参数，在裸机 `netns-proxy` 模式下同样可以直接写入 `/etc/microwarp/microwarp.env`，会被透传到独立 namespace 内实际运行的 WARP 进程。

### 🚀 扩展用法：转换为 HTTP 代理

基于 Unix 哲学，底层镜像未内置 HTTP 解析引擎以维持极限轻量化。如需 HTTP 代理，推荐使用 `gost` 进行本地转换：
```bash
nohup gost -F=socks5://admin:123456@127.0.0.1:1080 -L=http://127.0.0.1:8081 > /dev/null 2>&1 &
```
*注：请务必使用 `socks5://`（而非 `socks5h://`）以由宿主机处理 DNS 解析，避免启动时的解析超时问题。*

---

*特别鸣谢 __LinuxDo__ 社区* ❤️

---

## 📈 Star History

<a href="https://star-history.com/#ccbkkb/MicroWARP&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=ccbkkb/MicroWARP&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=ccbkkb/MicroWARP&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=ccbkkb/MicroWARP&type=Date" />
  </picture>
</a>
