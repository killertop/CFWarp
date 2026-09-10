# 更新记录 / Changelog

## 2026-09-10

### 刷新生命周期修复 / Refresh lifecycle fixes

- 刷新识别主服务启动/停止等过渡状态，停止后再次确认；状态未知时拒绝探测。
- 主服务、清理入口与刷新使用同一生命周期锁，关闭检查之后的并发启动窗口。
- 探测清理失败禁止恢复主服务，并保留阻断标记和恢复材料；后续进程也必须先完成恢复。
- Refresh recognizes starting/stopping and other transitional states, confirms shutdown, and refuses probing when state cannot be read.
- Main startup, cleanup, and refresh share a lifecycle lock to prevent starts racing a prior service-state check.
- Failed probe cleanup blocks main restoration and retains a startup-blocking marker and recovery material for later processes.

### 发布前再次审查 / Additional pre-publish review

- 修复升级漏停启动中的 oneshot：等待辅助服务退出后重新检查主服务，停服完成后才发布 MicroSOCKS；取消按接口名清理的升级补偿。
- 安装锁使用专属受限目录，避免改变系统 `/run/lock` 权限。
- 转发引用改为全局锁内的可重放事务，避免写入失败、跨实例操作和后续重试导致引用重复增减。
- 严格验证 IPv6 Endpoint，跳过非法字面量，使有效备用候选仍能被尝试。
- Fix upgrades missing activating oneshots: wait for helpers, reread the main service, and publish MicroSOCKS only after shutdown; remove name-only interface cleanup compensation.
- Use a restricted installation-lock directory without changing system `/run/lock` permissions.
- Journal forwarding-reference changes under the global lock so write failures, other instances, and retries cannot apply increments/decrements twice.
- Validate IPv6 endpoints strictly and skip malformed literals so valid fallback candidates remain usable.

### 中文

补充异常分支审查后，修复上一版测试未覆盖的锁失败、出口回落和恢复问题。

- 明确传播转发锁失败；在锁超时后保留引用计数、原始状态和内核转发设置。
- 在 namespace 连网前启用 IPv4/IPv6 出口默认拒绝，阻止隧道接口或路由消失时应用回落直连；`cfwarp-exec` 在归属锁内检查就绪并进入同一 namespace。
- 将账户初始化和初始 Endpoint DNS 放在宿主机，使用数字地址启动隧道，使旧域名失效时仍能尝试备用 IP；namespace 内应用 DNS 不设直连例外。
- 清理前识别活动及启动/停止中的 systemd 服务，在安装锁前后检查；拒绝时保留服务、定时器和运行文件。
- 刷新失败时保留持久、受限权限的原配置与恢复说明，避免启动部分恢复的配置；修复启动脚本读取备份失败可能清空配置的问题。
- 增加故障注入、真实锁竞争、网络阻断及 systemd 异常状态回归；保留 Shell 控制层，中英文文档同步说明使用边界。

### English

Follow-up failure-path review fixed locking, direct-egress fallback, and recovery gaps missed by the previous test coverage.

- Propagate forwarding-lock failure explicitly, preserving reference counts, original state, and kernel forwarding settings on timeout.
- Install IPv4/IPv6 default-deny egress before namespace connectivity, blocking direct fallback if tunnel interfaces or routes disappear. `cfwarp-exec` checks readiness and enters the same namespace under its ownership lock.
- Initialize accounts and resolve initial endpoint DNS on the host, starting the tunnel with literal addresses so backup IPs remain usable when an old hostname fails. Application DNS has no direct-egress exception.
- Check active and transitioning systemd services before and after the installation lock; refused cleanup preserves services, timers, and runtime files.
- Retain persistent, permission-restricted originals and recovery instructions after refresh failure, and avoid starting partially restored configuration. Fix entrypoint backup-read failure potentially truncating configuration.
- Add fault injection, real lock contention, egress-blocking, and systemd failure-state regressions; retain the Shell control layer and update bilingual usage boundaries.

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
