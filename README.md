# CFwarp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

CFwarp 是面向 Linux 裸机的 Cloudflare WARP 出站代理。它使用内核态
WireGuard 和轻量级 TCP SOCKS5 服务，在默认的独立 network namespace 中为
指定程序提供 WARP 出口，不改写宿主机默认路由。

本项目源自 [MicroWARP](https://github.com/ccbkkb/MicroWARP)，保留其 MIT
许可证与署名，当前代码按独立的 CFwarp 裸机发行方式维护。详见
[NOTICE.md](NOTICE.md) 和 [PROJECT.md](PROJECT.md)。

> 请遵守适用的法律法规及服务条款。CFwarp 不提供匿名性或合规性保证。

## 特性与边界

- Linux + systemd 裸机部署；不包含 Docker 镜像或 Compose 流程。
- 默认 `netns-proxy`：WARP 仅在独立 namespace 中运行，宿主机路由保持不变。
- 可选 `host-global`：只有显式配置时才接管宿主机 WireGuard 路由。
- 提供 TCP SOCKS5；不实现 UDP 转发。
- 使用固定版本的 `wgcf`，默认架构带内置 SHA256 校验。
- 可选 Endpoint 评估；默认不在现网服务运行时停机探测。
- 自带健康检查、保守的 watchdog 和只读优先的 doctor 工具。

## 快速开始

```bash
git clone https://github.com/killertop/CFWarp.git
cd CFWarp
sudo ./install.sh
sudo editor /etc/cfwarp/cfwarp.env
sudo systemctl enable --now cfwarp.service
```

安装器默认使用以下路径：

| 内容 | 默认路径 |
| --- | --- |
| 运行脚本 | `/opt/cfwarp` |
| 私有环境文件 | `/etc/cfwarp/cfwarp.env`，权限 0600 |
| WARP 账户和 WireGuard 状态 | `/var/lib/cfwarp`，权限 0700 |
| systemd units | `/etc/systemd/system` |

首次启动时，CFwarp 会下载并校验固定版本的 `wgcf`，生成 WARP 账户和
WireGuard 配置。账户文件、私钥、密码和运行日志都不应提交到 Git。

## 最小配置

安装器会从 [deploy/cfwarp.env.example](deploy/cfwarp.env.example) 创建私有
环境文件。默认配置会在 namespace 内监听 `169.254.240.2:1080`，宿主机程序
使用：

```text
socks5h://169.254.240.2:1080
```

如果需要认证，同时设置 `SOCKS_USER` 和 `SOCKS_PASS`，并确保环境文件权限为
0600。`host-global` 模式下禁止无认证监听通配地址；生产环境也不建议把
无认证 SOCKS5 暴露到公网。

常用配置示例：

```text
CFWARP_MODE=netns-proxy
BIND_ADDR=169.254.240.2
BIND_PORT=1080
# SOCKS_USER=<private-user>
# SOCKS_PASS=<private-password>
# ENDPOINT_IP=<host-or-ip>:<port>
# ENDPOINT_CANDIDATES=<host-or-ip>:<port>,<host-or-ip>:<port>
```

完整参数与接入示例见 [USAGE.md](USAGE.md)。

## 服务管理与诊断

```bash
sudo systemctl status cfwarp.service
sudo journalctl -u cfwarp.service -n 100 --no-pager
sudo /opt/cfwarp/cfwarp-healthcheck.sh --wait
sudo /opt/cfwarp/cfwarp-doctor.sh
```

健康检查会同时确认 SOCKS5 可达、WARP trace 状态和测试请求。doctor 默认只
检查；`--fix` 仅处理脚本/目录权限和可恢复的运行目录问题，不会修改其他项目
的防火墙、路由或代理配置：

```bash
sudo /opt/cfwarp/cfwarp-doctor.sh --fix
```

watchdog 默认每 5 分钟运行一次，连续失败后才重启 CFwarp，并带有冷却时间。
手动停止服务时不会自动拉起。Endpoint 刷新定时器默认不启用；如需启用，先
阅读 [USAGE.md](USAGE.md) 中关于短暂停机探测的说明。

## 安全与升级

- 只把 `deploy/cfwarp.env.example` 提交到仓库；不要提交 `cfwarp.env`、WARP
  账户、WireGuard 私钥、运行目录或本地二进制。
- 默认 `wgcf` 版本不使用 `latest`。自定义版本应同时提供并核对
  `WGCF_SHA256`。
- 通过 `--prefix` 或 `--data-dir` 自定义路径时，应使用 root 可控且不在用户
  home 下的目录，以便匹配 systemd 沙箱策略。
- 升级前先备份 `/etc/cfwarp/cfwarp.env` 和 `/var/lib/cfwarp`，然后重新运行
  安装器；安装器会复用已有账户和配置。
- 删除安装生成物：

  ```bash
  sudo systemctl stop cfwarp.service
  sudo ./install.sh --clean-generated
  ```

  该命令不会删除私有环境文件或 WARP 数据。

## 开发检查

本仓库不包含运行时账户或编译产物。提交前运行：

```bash
make test
```

发布流程还会执行 shell 语法检查、差异空白检查和敏感信息扫描。贡献方式见
[CONTRIBUTING.md](CONTRIBUTING.md)，安全问题请见 [SECURITY.md](SECURITY.md)。
