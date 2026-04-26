# CFwarp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> 请严格遵守你所在国家和地区的法律法规。任何因违法违规使用本项目而引发的法律纠纷或后果，均与本项目及作者无关。  
> Please comply with the laws and regulations of your jurisdiction. Any legal issues caused by illegal use are the user's own responsibility.

[English](#english) | [中文说明](#chinese)

CFwarp 是一个面向 Linux 服务器的 Cloudflare WARP 出站代理项目。  
它使用内核态 WireGuard 和 `microsocks` 提供低资源占用的 WARP 出口，并以 `systemd + netns` 作为默认部署模型。

当前仓库只维护 Linux 裸机部署路径，不再提供 Docker 部署能力。

---

<a name="english"></a>
## English

CFwarp is a lightweight Cloudflare WARP egress proxy for Linux hosts.
It combines kernel WireGuard with `microsocks` and defaults to a dedicated network namespace instead of rewriting the host's main routing table.

### What It Provides

1. Low-overhead WARP egress for selected applications
2. A local SOCKS5 endpoint for host-side programs
3. A `cfwarp-exec` helper for programs that cannot speak SOCKS
4. Optional `host-global` mode when you explicitly want host-wide takeover
5. An optional daily Endpoint refresh timer for unstable datacenter networks

### Deployment Model

CFwarp now supports bare-metal Linux only.

Requirements:

1. `systemd`
2. `wireguard-tools`
3. `iproute2`
4. `iptables`
5. a Linux kernel that supports network namespaces and WireGuard

Quick start:

```bash
chmod +x install.sh
sudo ./install.sh
sudo systemctl start cfwarp.service
```

The installer will:

1. install required system packages
2. build and install `microsocks`
3. reuse the repository directory as the runtime root
4. store persistent WARP state under `<repo>/var`
5. generate `<repo>/deploy/local/cfwarp.env`
6. generate `<repo>/deploy/systemd/cfwarp.service`
7. generate `<repo>/deploy/systemd/cfwarp-endpoint-refresh.service`
8. generate `<repo>/deploy/systemd/cfwarp-endpoint-refresh.timer`
9. link these units into `/etc/systemd/system`

### Default Runtime Behavior

Default mode is `CFWARP_MODE=netns-proxy`:

1. WARP only lives inside a dedicated Linux network namespace
2. the host default route is not rewritten
3. host applications connect to `${NETNS_PEER_HOST}:${BIND_PORT}`
4. programs without SOCKS support can be launched with `cfwarp-exec <command...>`

If you explicitly need host-wide takeover, set `CFWARP_MODE=host-global` in `<repo>/deploy/local/cfwarp.env`.

The daily refresh timer is not enabled by default. If you enable it manually, the safe default is `CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip`, which skips refresh while `cfwarp.service` is active instead of causing downtime.

For application integration and the default SOCKS5 endpoint, see [USAGE.md](./USAGE.md).

### Advanced Configuration

These keys are commonly adjusted in `<repo>/deploy/local/cfwarp.env`:

```text
BIND_ADDR=0.0.0.0
BIND_PORT=1080
SOCKS_USER=
SOCKS_PASS=
GH_PROXY=
ENDPOINT_IP=162.159.192.1:4500
ENDPOINT_CANDIDATES=162.159.192.1:2408,162.159.192.1:4500,188.114.96.7:2408
WARP_READY_ATTEMPTS=6
WARP_READY_DELAY_SECONDS=2
WARP_HEALTHCHECK_CONNECT_TIMEOUT=4
WARP_HEALTHCHECK_TOTAL_TIMEOUT=8
WARP_HEALTHCHECK_TRACE_URL=https://1.1.1.1/cdn-cgi/trace
WARP_HEALTHCHECK_TEST_URL=https://www.gstatic.com/generate_204
CFWARP_ENDPOINT_PROBE_SAMPLES=2
CFWARP_ENDPOINT_PROBE_URL=https://1.1.1.1/cdn-cgi/trace
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip
```

### HTTP Proxy Conversion

CFwarp only ships a SOCKS5 endpoint. If you need HTTP proxy compatibility, add a separate converter such as `gost`:

```bash
nohup gost -F=socks5://169.254.240.2:1080 -L=http://127.0.0.1:8081 > /dev/null 2>&1 &
```

---

<a name="chinese"></a>
## 中文说明

CFwarp 是一个面向 Linux 服务器的 Cloudflare WARP 出站代理。  
它基于内核态 WireGuard 和 `microsocks`，默认通过独立 network namespace 为指定程序提供 WARP 出口，而不是直接接管宿主机全局流量。

### 项目定位

当前仓库只维护 Linux 裸机部署路径，不再提供 Docker 部署功能。

它主要解决这几件事：

1. 给指定项目提供低资源占用的 WARP 出口
2. 给宿主机程序提供本地 SOCKS5 入口
3. 给不支持代理的程序提供 `cfwarp-exec`
4. 在需要时支持显式切换到 `host-global`
5. 通过可选的每日 Endpoint 刷新缓解机房链路波动

### 部署要求

需要：

1. `systemd`
2. `wireguard-tools`
3. `iproute2`
4. `iptables`
5. 支持 network namespace 和 WireGuard 的 Linux 内核

快速安装：

```bash
chmod +x install.sh
sudo ./install.sh
sudo systemctl start cfwarp.service
```

安装脚本会完成这些事：

1. 安装系统依赖
2. 编译并安装 `microsocks`
3. 复用仓库目录本身作为运行根目录
4. 将 WARP 持久化状态放到 `<repo>/var`
5. 生成 `<repo>/deploy/local/cfwarp.env`
6. 生成 `<repo>/deploy/systemd/cfwarp.service`
7. 生成 `<repo>/deploy/systemd/cfwarp-endpoint-refresh.service`
8. 生成 `<repo>/deploy/systemd/cfwarp-endpoint-refresh.timer`
9. 在 `/etc/systemd/system` 下建立链接

### 默认运行方式

默认模式是 `CFWARP_MODE=netns-proxy`：

1. WARP 只在独立的 Linux network namespace 中生效
2. 宿主机默认路由不会被改写
3. 宿主机上的项目应连接 `${NETNS_PEER_HOST}:${BIND_PORT}`
4. 不支持 SOCKS 的程序可使用 `cfwarp-exec <command...>`

如果你明确需要宿主机全局模式，再把 `<repo>/deploy/local/cfwarp.env` 中的 `CFWARP_MODE` 改成 `host-global`。

每日自动刷新默认不会自动启用；如果你手动启用，安全默认值 `CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip` 会在服务运行中直接跳过刷新，避免为探测停掉现网代理。

程序接入方式、默认 SOCKS5 地址和 `cfwarp-exec` 的使用方式，见 [USAGE.md](./USAGE.md)。

### 常用配置项

这些配置通常直接写到 `<repo>/deploy/local/cfwarp.env`：

```text
BIND_ADDR=0.0.0.0
BIND_PORT=1080
SOCKS_USER=
SOCKS_PASS=
GH_PROXY=
ENDPOINT_IP=162.159.192.1:4500
ENDPOINT_CANDIDATES=162.159.192.1:2408,162.159.192.1:4500,188.114.96.7:2408
WARP_READY_ATTEMPTS=6
WARP_READY_DELAY_SECONDS=2
WARP_HEALTHCHECK_CONNECT_TIMEOUT=4
WARP_HEALTHCHECK_TOTAL_TIMEOUT=8
WARP_HEALTHCHECK_TRACE_URL=https://1.1.1.1/cdn-cgi/trace
WARP_HEALTHCHECK_TEST_URL=https://www.gstatic.com/generate_204
CFWARP_ENDPOINT_PROBE_SAMPLES=2
CFWARP_ENDPOINT_PROBE_URL=https://1.1.1.1/cdn-cgi/trace
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip
```

### 转成 HTTP 代理

CFwarp 只提供 SOCKS5。若你需要 HTTP 代理兼容层，可以额外用 `gost` 做转换：

```bash
nohup gost -F=socks5://169.254.240.2:1080 -L=http://127.0.0.1:8081 > /dev/null 2>&1 &
```

---

## Star History

<a href="https://star-history.com/#ccbkkb/MicroWARP&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=ccbkkb/MicroWARP&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=ccbkkb/MicroWARP&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=ccbkkb/MicroWARP&type=Date" />
  </picture>
</a>
