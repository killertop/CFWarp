# 架构决定与验证范围 / Architecture decisions and validation scope

日期 / Date: 2026-09-10

## 中文

### 架构与语言决定

CFWarp 的控制层负责安装、配置、进程、网络资源和恢复；数据面由 Linux 内核 WireGuard 和 MicroSOCKS 处理。systemd 管理服务，`wgcf` 负责账户和 profile 初始化，`ip`、`wg-quick`、`iptables` 和 `sysctl` 提供 Linux 网络配置能力。

本轮评估后保留 POSIX Shell。当前缺陷集中在配置优先级、状态转换、资源所有权与失败回滚；改成 Rust 仍须重新设计并验证这些契约，也仍依赖 Linux 网络机制。数据流量已经由内核和原生程序处理，当前没有性能测量证明重写控制脚本能改善吞吐或资源占用。

只为解析 trace 增加 Rust helper 会新增构建和分发边界。全量改写则需同时解决双架构构建、依赖校验、安装升级和旧配置兼容。当前更有价值的工作是直接修正已有控制流程，并补充可重复的行为测试。

如果未来控制层的复杂度、长驻调度或可观测性需求明显增加，合理的 Rust 边界是完整控制器：类型化配置与状态、资源句柄、文件锁、进程组取消、单调计时与结构化诊断。届时可以保留安装脚本、systemd 和现有数据面。应以兼容性和 Linux 验证作为迁移门槛，而不是以语言名称作为性能证明。

### 控制层契约

| 范围 | 预期行为 |
| --- | --- |
| 配置 | 以数据解析单行赋值，不执行配置或网络响应；CLI 与调用者已导出环境优先，安装记录统一路径，子进程继承解析结果。 |
| Endpoint | 显式选择优先；probe 只能评估指定候选，结果与候选身份一致。 |
| 隧道生命周期 | 启动与停止使用同一完整 WireGuard 配置路径；失败要进入可检查的清理路径。 |
| 资源归属 | 创建前检测名称碰撞，清理只处理已确认归属本项目的 namespace、veth、DNS 文件与规则；拒绝路径越界名称。 |
| IPv4 转发 | 引用状态与内核值在同一锁内转换；失败回滚与最后一个引用释放不能关闭其他活动实例所需的转发。 |
| 探测与退出 | 同一 WireGuard 身份串行探测；超时和信号覆盖子进程，先终止并等待再清理资源。 |
| DNS | namespace 默认使用明确的公共解析器 `1.1.1.1`、`1.0.0.1`，不自动复制宿主机私网 DNS。 |
| 诊断和扫描 | 安装态检查真实运行文件；重试参数不被旧配置覆盖；扫描异常属于失败。 |

配置目录、数据目录和安装记录应由 root 控制。资源归属检查防止意外接管和清理，不构成对恶意 root 的安全隔离。namespace 隔离代理流量，默认模式仍需要本项目的 host veth、NAT/转发规则及 forwarding 状态；“不改宿主机默认路由”不等于“完全不改变宿主机网络状态”。

### 故障时阻止直连

默认 namespace 在 veth 或默认路由可用前，对 IPv4 和 IPv6 的 OUTPUT/FORWARD 设置默认拒绝。只放行 loopback、经 WireGuard 接口的流量、经 veth 且带匹配 WireGuard fwmark 的 UDP 加密传输，以及 SOCKS 监听端口上 conntrack 判定为 REPLY 的已建立 TCP 返回流量。不提供通用 ESTABLISHED 放行或直连 DNS 例外；接口消失、路由丢失或退出清理时保护仍生效。

`cfwarp-start.sh` 先在宿主机运行仅准备阶段，初始化账户/profile 并解析候选，随后把原候选与数字地址映射传给 namespace 中的入口。首次 `wg-quick up` 使用已解析的候选，所以无效旧域名不会阻止备用 IP 被尝试。准备阶段和运行阶段都受进程组监督。`CFWARP_WG_FWMARK` 默认 51820，在 namespace/probe 配置和防火墙中保持一致。

`cfwarp-exec` 检查资源归属、出口规则、fwmark、近期握手与路由后再执行命令；检查后的持续保护由内核规则承担。此保护适用于受管理的 namespace，不能防止具有 root/网络管理能力的程序主动改变规则或标记流量；`host-global` 没有加入宿主机全局出口阻断。

Endpoint 刷新开始前把原配置放入数据目录下独立、受限权限的持久恢复目录。部署验证、回滚或资源清理失败时保留；恢复写入失败不会继续启动部分恢复的配置。安装清理在锁前和锁后都执行只读拒绝检查，明确允许后才停止服务和定时器。

### systemd 与升级边界

主服务、健康守护和 Endpoint 刷新必须与宿主机上的 `cfwarp-exec` 看到同一组 `/run/netns` 命名空间挂载。因此服务显式使用 `PrivateTmp=false` 和 `ProtectHome=false`，避免这些文件系统沙箱选项创建独立 mount namespace，导致一个命令创建的网络 namespace 对其他命令不可见。仍保留 `NoNewPrivileges` 等不改变该挂载可见性的限制。服务以 root 运行；这一取舍应连同网络权限一起审查，不能将这些 unit 描述为完整的文件系统隔离沙箱。

systemd unit 只传入 `CFWARP_ENV_FILE` 的路径，由所有入口共用的数据解析器加载内容；unit 不再通过 `EnvironmentFile` 额外解析同一文件，从而避免 CLI 与服务对引号、行尾注释和优先级产生不同理解。

新版 namespace 状态使用 `VERSION=2`，记录 namespace inode、veth ifindex、DNS 文件 inode 和已取得的 forwarding 引用。host-global 另外记录接口 ifindex、公钥和完整配置路径，并通过接口操作锁协调启动与停止。这些运行状态是判断清理归属的依据，不能用修改版本号或删除状态文件的方式绕过校验。

升级前应保留旧版本及私有配置备份。安装器先停止正在运行的定时任务和服务，让旧版本自己的清理代码执行，再替换运行文件并按原运行状态恢复服务。旧版状态若无法由新版安全识别，新版会拒绝按资源名称清理；应使用创建该状态的版本完成停服，并核查 namespace、接口、规则和 forwarding 的恢复情况。安装文件更新成功不代表旧资源已清理，已有旧状态也不会被无条件认领或迁移。

转发引用的跨文件更新使用全局锁内的 `ip_forward.pending` 日志，记录目标引用总数、原内核值、实例状态路径和 namespace 身份。所有引用操作先完成未提交事务，以绝对目标值重放，避免状态写入失败后的重试再次增减引用。普通状态写入也在同一锁内同步已提交的引用标记；日志只修改该标记，保留最新 DNS 和规则归属字段。日志提交失败会保留现场并阻止后续引用操作越过它。这针对可重试的写入/系统调用失败，不承诺断电后的持久事务恢复。

升级先停止定时器，再停止并等待包括 `activating` oneshot 在内的辅助服务，随后重新读取并停止主服务，避免取消刷新时恢复的主服务被遗漏。MicroSOCKS 提前编译到暂存文件，停服完成后才发布。安装锁位于专属的 0700 目录，保留系统 `/run/lock` 权限；不再按接口名称补偿清理 host-global 资源。

### 修复验证说明

`make test` 运行无特权检查与回归；`make integration` 在专用 Linux 测试机运行需要 root 的内核网络验证。

这份文档描述验收范围，不把“完成实现”当作“已经通过测试”。发布前应记录实际测试环境、命令、结果和未覆盖项：

| 层次 | 应核对的行为 | 可以证明什么 |
| --- | --- | --- |
| 静态检查 | Shell 语法、ShellCheck、diff、敏感信息扫描 | 语法、可静态识别的错误与扫描覆盖范围。 |
| 无特权回归 | 响应解析、配置优先级、自定义目录、指定 Endpoint、重试、扫描失败 | 给定输入和故障条件下的脚本行为。 |
| Linux 隔离集成 | namespace/veth/iptables/sysctl、重复 up/down、资源碰撞、失败回滚、信号退出 | 当前 Linux 环境中的真实内核资源与清理行为。 |
| systemd 集成 | 主服务、启动后检查、停止后清理、watchdog、刷新和宿主命令的 namespace 可见性 | 当前 systemd 配置和 mount namespace 边界的兼容性。 |
| 真实 WARP | 账户初始化、握手、`warp=on/plus`、代理域名请求、实际应用访问 | 被测服务器和时间窗口内的外部网络连通性。 |

mock 通过不能替代内核验证；内核验证不能替代实际 WARP 请求。单次 trace 耗时不能证明带宽、长期稳定性或其他服务器表现。本轮发布的实际验证回执应与提交版本一同记录，尚未执行或不可达的项目明确标为未验证。

## English

### Architecture and language decision

The CFWarp control layer manages installation, configuration, processes, network resources, and recovery. Linux in-kernel WireGuard and MicroSOCKS handle traffic. systemd manages services, `wgcf` initializes accounts and profiles, and `ip`, `wg-quick`, `iptables`, and `sysctl` provide Linux network configuration.

This revision retains POSIX Shell after evaluating Rust. The identified defects concern configuration precedence, state transitions, resource ownership, and rollback. A Rust rewrite would still require those contracts to be designed and tested, and would still depend on Linux networking. Traffic already runs through the kernel and native programs; no measurements establish a throughput or resource-use benefit from rewriting the control scripts.

A Rust helper solely for trace parsing would add a build and distribution boundary. Replacing the entire controller would also require builds for both supported architectures, dependency verification, installation and upgrade handling, and configuration compatibility. Correcting the existing lifecycle and adding reproducible behavior tests provides more immediate value.

If control-layer complexity, persistent scheduling, or observability needs grow, a complete Rust controller is a reasonable future boundary: typed configuration and state, resource handles, file locks, process-group cancellation, monotonic timing, and structured diagnostics. The installer, systemd integration, and current data plane can remain. Compatibility and Linux validation should determine readiness; the implementation language alone is not performance evidence.

### Control-layer contracts

| Area | Expected behavior |
| --- | --- |
| Configuration | Parse single-line assignments as data without executing configuration or network responses; explicit CLI options and exported caller values take precedence, installation records provide consistent paths, and children inherit resolved settings. |
| Endpoints | Prefer explicit selection; probe only the requested candidate and verify the result matches it. |
| Tunnel lifecycle | Use the same complete WireGuard configuration path for startup and shutdown; failures enter an observable cleanup path. |
| Resource ownership | Detect name collisions before creation; clean only namespaces, veth devices, DNS files, and rules confirmed as project-owned; reject traversal names. |
| IPv4 forwarding | Change reference state and the kernel setting under one lock; rollback and final-reference release must not disable forwarding needed by another active instance. |
| Probing and shutdown | Probe sequentially when sharing one WireGuard identity; timeout and signal handling cover child processes, stopping and waiting before resource cleanup. |
| DNS | Default namespace resolvers are explicitly `1.1.1.1` and `1.0.0.1`; do not automatically copy private host DNS. |
| Diagnostics and scans | Check the actual installed runtime files; preserve retry overrides; treat scanner errors as failures. |

Root must control configuration, data, and installation records. Ownership checks prevent accidental takeover and cleanup; they are not a security boundary against malicious root. The namespace isolates proxy traffic, but default setup still requires host veth devices, project-owned NAT/forwarding rules, and forwarding state. Preserving the host default route does not mean making no changes to host networking.

### Blocking direct fallback on failure

Before veth connectivity or a default route is available, default namespace mode sets IPv4 and IPv6 OUTPUT/FORWARD policies to DROP. Exceptions cover loopback, traffic through the WireGuard interface, encrypted UDP transport over veth carrying the matching WireGuard fwmark, and established TCP replies from the SOCKS listening port whose conntrack direction is REPLY. There is no general ESTABLISHED allowance or direct DNS exception. Protection remains effective when interfaces or routes disappear and during cleanup.

`cfwarp-start.sh` first runs a host preparation phase to initialize the account/profile and resolve candidates, then passes original-candidate/literal-address mappings to the namespace entry point. The first `wg-quick up` uses a resolved candidate, so an invalid old hostname cannot prevent backup IP candidates from being tried. Process-group supervision covers both preparation and runtime. `CFWARP_WG_FWMARK` defaults to 51820 and is kept consistent between namespace/probe configuration and firewall rules.

`cfwarp-exec` checks ownership, egress rules, fwmark, recent handshakes, and routing before executing a command. Kernel rules provide continuous protection after those checks. This applies to managed namespaces; programs with root/network-management capabilities can deliberately alter rules or mark traffic. No host-wide kill switch is added to `host-global`.

Endpoint refresh saves originals in a separate persistent recovery directory with restricted permissions before making changes. Deployment verification, rollback, or resource-cleanup failure retains that directory; failed restoration does not start a partially restored configuration. Installation cleanup performs read-only refusal checks both before and after the lock, stopping services and timers only after those checks permit cleanup.

### systemd and upgrade boundaries

The main service, watchdog, endpoint refresh, and host-side `cfwarp-exec` must see the same named namespace mounts under `/run/netns`. Services therefore explicitly use `PrivateTmp=false` and `ProtectHome=false`: these filesystem sandbox options can create a separate mount namespace, hiding network namespace mounts from other commands. Restrictions such as `NoNewPrivileges` remain where they do not change mount visibility. Services run as root; review this tradeoff together with their network privileges, rather than describing the units as complete filesystem-isolation sandboxes.

Units pass only the `CFWARP_ENV_FILE` path. Every entry point uses the shared data parser; units no longer parse the same file through `EnvironmentFile`. This prevents CLI/service differences in quoting, trailing comments, and precedence.

The new namespace state uses `VERSION=2`, recording the namespace inode, veth ifindex, DNS-file inode, and held forwarding reference. Host-global mode separately records the interface ifindex, public key, and full configuration path, coordinating startup and shutdown with an interface operation lock. These records establish cleanup ownership. Editing a version field or deleting a state file is not a valid way to bypass ownership checks.

Keep the previous version and private configuration backups before upgrading. The installer first stops active timers and services so the previous version's own cleanup code runs, then replaces runtime files and restores the prior running state. If the new version cannot safely interpret old state, it refuses cleanup based only on resource names. Use the version that created that state to stop the service, then verify namespaces, interfaces, rules, and forwarding restoration. Successfully replacing installation files does not establish that old resources were removed; old state is not automatically claimed or migrated.

Cross-file forwarding updates use an `ip_forward.pending` journal under the global lock, recording absolute target references, the original kernel setting, the instance state path, and namespace identity. Every reference operation first completes pending work by replaying target values, preventing retries after failed state writes from incrementing or decrementing twice. Ordinary state writes synchronize the committed membership flag under the same lock; journal replay changes only that flag, preserving newer DNS/rule ownership fields. Failed commits retain the journal and block later reference operations from bypassing it. This handles retryable write/system-call failures and does not promise durable recovery after power loss.

Upgrades stop timers, then stop and wait for helper services including `activating` oneshots, then reread and stop the main service so refresh cancellation cannot restore it unnoticed. MicroSOCKS is built into a staged file and published only after shutdown. The installation lock uses a dedicated 0700 directory without changing system `/run/lock` permissions; host-global resources are no longer cleaned through interface-name compensation.

### Validation scope

`make test` runs unprivileged checks and regressions. `make integration` runs root-required kernel networking checks on a dedicated Linux test machine.

This document defines acceptance coverage; implementation completion does not imply passing tests. Before publishing, record the actual environment, commands, results, and missing coverage:

| Layer | Behavior to check | Evidence provided |
| --- | --- | --- |
| Static checks | Shell syntax, ShellCheck, diff checks, sensitive-material scans | Syntax, statically detectable defects, and the scanner's coverage. |
| Unprivileged regressions | Response parsing, configuration precedence, custom paths, explicit endpoints, retries, scanner failure | Script behavior under controlled inputs and faults. |
| Isolated Linux integration | namespace/veth/iptables/sysctl, repeated up/down, collisions, rollback, signal shutdown | Real kernel resources and cleanup on the tested Linux environment. |
| systemd integration | Main service, post-start checks, post-stop cleanup, watchdog, refresh, and host command namespace visibility | Compatibility with the tested service and mount-namespace boundaries. |
| Real WARP | Account initialization, handshake, `warp=on/plus`, proxy DNS requests, and application access | External connectivity on the tested server and time window. |

Mocked tests do not replace kernel tests; kernel tests do not replace real WARP requests. A trace request duration does not establish bandwidth, long-term stability, or behavior on other servers. Record the actual release validation receipt alongside the commit and explicitly identify checks that were not run or could not reach their external dependency.
