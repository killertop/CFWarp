# CFwarp Usage

这份文档面向“其他程序/自动化脚本如何调用 CFwarp”。
默认假设你已经通过 `install.sh` 完成裸机安装，且使用默认配置。
当前仓库只维护裸机部署，不再提供 Docker 部署入口。

## 1. 默认安装产物

- systemd 服务名：`cfwarp.service`
- Endpoint 刷新服务：`cfwarp-endpoint-refresh.service`
- Endpoint 刷新定时器：`cfwarp-endpoint-refresh.timer`
- 运行根目录：`/opt/web/CFwarp`
- 环境文件：`/opt/web/CFwarp/deploy/local/cfwarp.env`
- 持久化状态目录：`/opt/web/CFwarp/var`
- 命令执行助手：`/opt/web/CFwarp/bin/cfwarp-exec`
- systemd 单元文件：`/opt/web/CFwarp/deploy/systemd/cfwarp.service`
- systemd 链接：`/etc/systemd/system/cfwarp.service`
- 兼容入口：`microwarp.service`、`microwarp-exec`、`microwarp.env`

## 2. 默认运行模式

默认模式是 `netns-proxy`，不是宿主机全局模式。

含义：

- WARP 只在独立的 Linux network namespace 中生效
- 宿主机默认路由不会被 CFwarp 改写
- 宿主机上的项目需要显式连接 CFwarp 提供的 SOCKS5 代理

默认 `cfwarp.env` 中的关键值：

- `CFWARP_MODE=netns-proxy`
- `NETNS_PEER_HOST=169.254.240.2`
- `BIND_PORT=1080`

额外约束：

- `NETNS_HOST_IF` 和 `NETNS_NS_IF` 这两个 veth 接口名必须不超过 15 个字符，这是 Linux 内核限制

因此，宿主机项目默认应连接：

```text
169.254.240.2:1080
```

如果启用了认证，则使用：

```text
SOCKS5 host: 169.254.240.2
SOCKS5 port: 1080
username: <SOCKS_USER>
password: <SOCKS_PASS>
```

## 3. 推荐调用方式

### 方式 A：程序直接使用 SOCKS5

适用于支持代理配置的程序。

推荐优先使用：

```text
socks5h://169.254.240.2:1080
```

如果启用了认证：

```text
socks5h://<user>:<pass>@169.254.240.2:1080
```

说明：

- `socks5h://` 表示域名解析也走 SOCKS5 服务端，避免宿主机本地 DNS 泄漏
- 如果你的客户端库只支持 `socks5://`，也可以使用，但 DNS 可能先在宿主机解析

常见环境变量写法：

```bash
ALL_PROXY=socks5h://169.254.240.2:1080
all_proxy=socks5h://169.254.240.2:1080
```

启用认证时：

```bash
ALL_PROXY=socks5h://user:pass@169.254.240.2:1080
```

### 方式 B：程序不支持 SOCKS5，直接进 namespace 执行

适用于没有代理配置能力、但可以通过命令行启动的程序。

使用：

```bash
cfwarp-exec <command> [args...]
```

示例：

```bash
cfwarp-exec curl -s https://1.1.1.1/cdn-cgi/trace
cfwarp-exec python your_script.py
cfwarp-exec /path/to/program --flag value
```

说明：

- `cfwarp-exec` 会把目标命令放进 CFwarp 使用的同一个 network namespace
- 进入该 namespace 后，程序默认出站就会经过 WARP
- 如果 `cfwarp.service` 没启动，`cfwarp-exec` 会直接报错退出

## 4. 服务控制

启动：

```bash
systemctl start cfwarp.service
```

停止：

```bash
systemctl stop cfwarp.service
```

查看状态：

```bash
systemctl status cfwarp.service
```

查看日志：

```bash
journalctl -u cfwarp.service -n 100 --no-pager
```

手动执行一次最佳 Endpoint 选择：

```bash
systemctl start cfwarp-endpoint-refresh.service
```

查看自动选择日志：

```bash
journalctl -u cfwarp-endpoint-refresh.service -n 100 --no-pager
```

## 5. 给程序接入时应遵守的约定

建议其他程序按下面的优先级接入：

1. 优先使用显式 SOCKS5 代理地址 `169.254.240.2:1080`
2. 如果程序不支持 SOCKS5，再使用 `cfwarp-exec`
3. 不要假设宿主机已经被全局 WARP 接管

程序在接入时不应假设以下行为：

- 不应假设 `127.0.0.1:1080` 一定可用
- 不应假设宿主机所有请求都会自动走 WARP
- 不应假设 `host-global` 模式是默认模式

## 6. 何时会变成宿主机全局模式

只有在 `/opt/web/CFwarp/deploy/local/cfwarp.env` 中显式设置：

```text
CFWARP_MODE=host-global
```

此时：

- 宿主机主网络空间会被 WARP 接管
- `cfwarp-exec` 不再适用
- 这种模式不适合作为“某个项目单独走 WARP”的默认方案

## 7. 最小联通性检查

如果你只是想确认代理是否可用，可在宿主机执行：

```bash
curl -x socks5h://169.254.240.2:1080 https://1.1.1.1/cdn-cgi/trace
```

启用认证时：

```bash
curl -x socks5h://user:pass@169.254.240.2:1080 https://1.1.1.1/cdn-cgi/trace
```

如果你想确认 namespace 模式本身可用，可执行：

```bash
cfwarp-exec curl -s https://1.1.1.1/cdn-cgi/trace
```

## 8. 连通性调优参数

如果你所在机房对默认 WARP Endpoint 不稳定，或者握手比较慢，可直接在 `/opt/web/CFwarp/deploy/local/cfwarp.env` 中加入这些参数：

```text
ENDPOINT_IP=162.159.192.1:4500
ENDPOINT_CANDIDATES=162.159.192.1:2408,162.159.192.1:4500,188.114.96.7:2408
WARP_READY_ATTEMPTS=6
WARP_READY_DELAY_SECONDS=2
WARP_HEALTHCHECK_CONNECT_TIMEOUT=4
WARP_HEALTHCHECK_TOTAL_TIMEOUT=8
WARP_HEALTHCHECK_TRACE_URL=https://1.1.1.1/cdn-cgi/trace
WARP_HEALTHCHECK_TEST_URL=https://www.gstatic.com/generate_204
```

说明：

- `ENDPOINT_IP` 用于指定单个优选 Endpoint
- `ENDPOINT_CANDIDATES` 用逗号分隔多个候选 Endpoint，CFwarp 会依次尝试
- `WARP_READY_*` 和 `WARP_HEALTHCHECK_*` 用于控制握手等待和可用性检测
- 在默认的 `netns-proxy` 模式下，这些参数会被传入独立 namespace 内实际运行的 WARP 进程
- `cfwarp-endpoint-refresh.timer` 会每天运行一次，在 `ENDPOINT_IP + ENDPOINT_CANDIDATES` 中选一个当前更优的 Endpoint，并回写 `ENDPOINT_IP`
- `CFWARP_ENDPOINT_PROBE_SAMPLES` 用于控制每日自动选择时的探测样本数
- `CFWARP_ENDPOINT_PROBE_URL` 用于指定每日自动选择时的探测 URL
- `CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip` 是默认安全值，表示当 `cfwarp.service` 正在运行时直接跳过刷新，避免为探测停掉现网代理
- 如确实接受短时停服探测，再显式设置 `CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=stop-and-probe`

## 9. 供程序直接读取的关键结论

可直接把下面几条当作接入规则：

```text
default_mode=netns-proxy
default_socks5_host=169.254.240.2
default_socks5_port=1080
preferred_proxy_scheme=socks5h
non_proxy_program_runner=cfwarp-exec
global_host_routing=false
```
