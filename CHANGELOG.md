# 更新记录 / Changelog

## 2026-09-09

### 中文

本次围绕 Linux WARP 出站代理的配置、安全解析和网络生命周期修复；保留 Shell 控制层，语言评估见 [架构说明](docs/architecture.md)，验收结果见 [验证记录](docs/validation.md)。

- 新增 `cfwarp` 管理入口，统一服务、日志、健康、自检、刷新与命令执行操作；`env` 只显示配置文件路径。
- 移除健康检查和 doctor 对响应内容的 `eval`，以数据解析 trace 和指标。
- 统一配置加载、调用者优先级与安装路径记录，接通自定义环境/二进制目录，保留升级时合法的带引号数据目录。
- 修正显式 Endpoint 的优先级与候选身份检查，使用同一 WireGuard 身份的探测改为串行，并完善超时、退出和恢复路径。
- 启动、停止与失败清理使用一致的完整 WireGuard 配置路径。
- 将 IPv4 forwarding 引用与内核状态变更放在同一锁内，完善资源归属、名称和清理边界。
- 为 namespace 设置明确的公共 DNS 默认值，支持通过 `NETNS_DNS_SERVERS` 配置。
- 修正安装态 doctor 检查、watchdog 重试覆盖，以及扫描器失败仍放行的问题。
- 增加对应行为回归与 Linux 隔离验证路径；实际执行结果与未验证项在发布回执中单独记录。
- 重写中英文项目介绍和使用说明，明确按应用 WARP 出站的价值、TCP/IPv4 范围、权限要求和 `host-global` 的路由影响，移除未经测量的性能承诺。

### English

This revision focuses on configuration, safe parsing, and the network lifecycle of the Linux WARP egress proxy. The Shell control layer is retained; see the [architecture decision](docs/architecture.md) and [validation record](docs/validation.md).

- Add the `cfwarp` command for service control, logs, health, diagnostics, refresh, and namespace execution; `env` shows only the configuration path.
- Remove response-driven `eval` from health checks and doctor; parse trace and metrics as data.
- Unify configuration loading, caller precedence, and installation path records; support custom environment/binary directories and preserve valid quoted data-directory settings during upgrades.
- Fix explicit endpoint precedence and candidate identity checks; probe sequentially when using one WireGuard identity and improve timeout, shutdown, and recovery paths.
- Use the same complete WireGuard configuration path for startup, shutdown, and failure cleanup.
- Update IPv4 forwarding references and kernel state under one lock; strengthen resource ownership, name validation, and cleanup boundaries.
- Set explicit public DNS defaults for namespaces, configurable through `NETNS_DNS_SERVERS`.
- Correct installed-layout doctor checks, watchdog retry overrides, and scanner errors being treated as successful scans.
- Add behavioral regression coverage and isolated Linux validation paths; actual outcomes and unverified checks are reported separately in the release receipt.
- Rewrite Chinese and English introductions and usage guidance, explaining per-application WARP egress, TCP/IPv4 scope, permissions, and `host-global` routing effects; remove unmeasured performance promises.
