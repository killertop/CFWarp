# CFwarp 使用说明

本文假设已在 Linux 裸机上运行 `install.sh`。默认安装根目录为
`/opt/cfwarp`，私有环境文件为 `/etc/cfwarp/cfwarp.env`，WARP 状态目录为
`/var/lib/cfwarp`。

## 1. 运行模式

### `netns-proxy`（默认）

CFwarp 创建独立 network namespace、veth 和 WARP WireGuard 接口。宿主机默认
路由不会被修改；宿主机程序通过 veth 对端访问 SOCKS5：

```text
地址：169.254.240.2
端口：1080
URL：socks5h://169.254.240.2:1080
```

`socks5h` 会让域名解析也通过代理完成。若启用了认证，将用户名和密码配置
在支持 SOCKS5 认证的客户端中。veth 接口名最多 15 个字符，这是 Linux 的
接口名限制。

### `host-global`

只有在环境文件中显式设置以下值时才启用：

```text
CFWARP_MODE=host-global
BIND_ADDR=127.0.0.1
```

此模式让 `wg-quick` 在宿主机上处理 WireGuard 路由。若把 SOCKS5 绑定到
通配地址，必须同时设置 `SOCKS_USER` 和 `SOCKS_PASS`。除非你明确理解路由
和暴露面变化，否则使用默认的 `netns-proxy`。

## 2. 应用接入

支持 SOCKS5 的程序应配置：

```text
socks5h://169.254.240.2:1080
```

例如：

```bash
ALL_PROXY=socks5h://169.254.240.2:1080 curl -fsS https://1.1.1.1/cdn-cgi/trace
```

不支持 SOCKS5 但可以从命令行启动的程序，使用：

```bash
/opt/cfwarp/cfwarp-exec <command> [args...]
/opt/cfwarp/cfwarp-exec curl -fsS https://1.1.1.1/cdn-cgi/trace
```

`cfwarp-exec` 会把进程放入 CFwarp namespace。服务未启动或当前是
`host-global` 时，它会直接报错退出。CFwarp 自身只提供 TCP SOCKS5，不提供
UDP 代理。

## 3. 常用命令

```bash
sudo systemctl start cfwarp.service
sudo systemctl stop cfwarp.service
sudo systemctl restart cfwarp.service
sudo systemctl status cfwarp.service
sudo journalctl -u cfwarp.service -n 100 --no-pager
```

健康检查：

```bash
sudo /opt/cfwarp/cfwarp-healthcheck.sh
sudo /opt/cfwarp/cfwarp-healthcheck.sh --wait
sudo /opt/cfwarp/cfwarp-healthcheck.sh --format env
sudo /opt/cfwarp/cfwarp-healthcheck.sh --format env \
  --metrics-file /run/cfwarp/health.env
```

输出中的 `CFWARP_HEALTH_OK=1` 只在 SOCKS5 请求成功且 trace 显示 WARP
状态为 `on` 或 `plus` 时出现。`CFWARP_TOTAL_MS` 是一次 trace 请求的总耗时，
不等同于线路带宽。

自检：

```bash
sudo /opt/cfwarp/cfwarp-doctor.sh
sudo /opt/cfwarp/cfwarp-doctor.sh --fix
sudo /opt/cfwarp/cfwarp-doctor.sh --metrics-file /run/cfwarp/doctor.env
```

`--fix` 是保守操作，只修复 CFwarp 自身的权限和运行目录问题；不会自动改动
其他服务、防火墙规则或宿主机路由。

## 4. Endpoint 管理

默认情况下，CFwarp 采用 `wgcf` profile 中的 Endpoint。可在私有环境文件中
显式指定：

```text
ENDPOINT_IP=<host-or-ip>:<port>
ENDPOINT_CANDIDATES=<host-or-ip>:<port>,<host-or-ip>:<port>
```

Endpoint 必须使用 `host:port` 或 `[ipv6]:port` 格式。不要把未经验证的地址
批量写入生产配置。

自动评估默认关闭。如果启用每日定时器，推荐保留：

```text
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=skip
```

这会在 `cfwarp.service` 正常运行时跳过探测，避免定时任务主动中断代理。若
确实需要评估当前活动隧道，才使用：

```text
CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE=stop-and-probe
```

该模式会短暂停止服务，逐个探测候选，并仅在达到最小改善阈值时写入新
Endpoint。探测结束会尝试恢复服务；若恢复失败，会回滚环境文件中的旧值。

手动运行：

```bash
sudo systemctl start cfwarp-endpoint-refresh.service
sudo journalctl -u cfwarp-endpoint-refresh.service -n 100 --no-pager
```

## 5. 配置安全

环境文件是 shell 变量文件，只应由 root 创建和维护。至少保证：

```bash
sudo chmod 600 /etc/cfwarp/cfwarp.env
sudo chmod 700 /var/lib/cfwarp
```

不要在仓库、issue、日志或截图中公开 `SOCKS_PASS`、WARP account、私钥或
任何访问令牌。自定义安装目录应使用 root 可控路径；默认 systemd 单元启用
PrivateTmp、NoNewPrivileges、ProtectHome 和其他沙箱限制。

## 6. 故障排查

按以下顺序收集信息：

```bash
sudo systemctl status cfwarp.service --no-pager
sudo journalctl -u cfwarp.service -n 200 --no-pager
sudo /opt/cfwarp/cfwarp-healthcheck.sh --format env
sudo /opt/cfwarp/cfwarp-doctor.sh
```

常见原因包括 UDP 出口受限、Endpoint 不可达、namespace 或 veth 被外部脚本
删除、SOCKS 端口冲突，以及环境文件权限不正确。不要用单次 ping 或某个测速
站点把结果当作总带宽证明；先确认 WARP handshake、trace 和实际应用请求。

## 7. 升级与清理

升级前备份私有环境和数据，然后运行新版安装器：

```bash
sudo cp -a /etc/cfwarp /root/cfwarp-config-backup
sudo cp -a /var/lib/cfwarp /root/cfwarp-data-backup
sudo ./install.sh --start
```

`--clean-generated` 只删除安装生成的脚本、私有 `wg-quick`、`microsocks` 和
systemd units，不删除环境文件或 WARP 数据：

```bash
sudo systemctl stop cfwarp.service
sudo ./install.sh --clean-generated
```
