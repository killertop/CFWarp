# CFwarp 项目范围

CFwarp 是从 MicroWARP 演进出的独立 Linux 裸机部署项目。当前仓库只维护
可审查、可重复安装的 `systemd + network namespace + SOCKS5` 路径。

## 当前范围

- 支持 Linux 内核 WireGuard、network namespace、veth、iptables 和 systemd。
- 默认不接管宿主机全局路由；`host-global` 只能由用户显式启用。
- 只提供 TCP SOCKS5，不承诺 UDP、HTTP 代理或透明代理功能。
- WARP 账户和运行状态在主机私有目录生成，不进入版本库。
- Endpoint 自动评估是可选功能，默认不因定时器停止活动服务。

## 不在范围内

- Docker/Compose 镜像和 GHCR 发布。
- 面向某一台服务器、某个域名、某个 sing-box 配置或某个第三方 API 的逻辑。
- 把真实环境变量、私钥、WARP account、日志或编译产物提交到仓库。

## 维护约定

- 依赖版本、下载校验和、权限边界与回滚行为必须在代码或文档中明确。
- 涉及路由、防火墙、namespace 和 sysctl 的修改必须可识别、可清理，且不能
  擅自刷新或删除其他程序的规则。
- 任何修复都应先通过 `make test`、shell 语法检查和敏感信息扫描。
- 上游改动只人工审查后按需移植，不直接合并未经审查的历史部署文件。
