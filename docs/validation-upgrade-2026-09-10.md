# 升级与转发事务复查 / Upgrade and forwarding transaction review

日期 / Date: 2026-09-10

运行代码 / Runtime: [`5280b4e`](https://github.com/killertop/CFWarp/commit/5280b4e)

## 中文

再次独立 review 发现此前 `095681b` 的验证遗漏了升级中的 oneshot 状态、转发引用的跨文件提交失败，以及非法 IPv6 Endpoint。已修复以下问题，并由未编写相应修复的 reviewer 交叉检查。

| 问题 | 修复与证据 |
| --- | --- |
| 升级忽略 `activating` helper，取消刷新可能恢复主服务 | 根据 ActiveState 停止并等待定时器和 helper，再重新读取、停止主服务。真实 systemd oneshot 的取消清理会恢复无害主服务；测试确认它再次停止后才发布。 |
| 构建阶段过早覆盖 MicroSOCKS | 先构建暂存文件，停服成功后发布；停止失败保留旧二进制并清除暂存文件。 |
| 升级按接口名称补偿清理 host-global | 删除绕过归属记录的补偿，依赖旧服务自身的归属清理；同名外部接口回归通过。 |
| 安装锁改变 `/run/lock` 权限 | 锁移到 root 私有的 `/run/cfwarp-install`，不操作系统 `/run/lock`；拒绝符号链接和不安全的锁目录。 |
| 引用计数写入后实例状态失败，重试重复增减 | 全局锁内保存绝对目标值的事务日志；后续操作先重放，普通状态写入同步已提交标记。52 个提交前后故障点、跨实例、EXIT 清理和后续进程重试通过。 |
| 非法 IPv6 地址或额外端口片段阻断备用候选 | 完整校验 IPv6 及 `[地址]:端口` 结构；解析和实际入口回归确认跳过非法候选并使用有效备用。 |

### 实际验证

- macOS：完整无特权回归通过；Linux 专属项明确跳过。
- 专用 Ubuntu 24.04.4 ARM64 VM，Linux 6.8.0-117-generic、systemd 255：独立 Git 克隆执行 `make integration` 全部通过。最终 Endpoint 补修后重新运行 `make test` 和 ShellCheck，全部通过。
- 真实内核测试包含两实例及并发转发引用、获取/释放状态写入失败、重复新进程清理、WireGuard 对照通信、接口/路由消失后的出口阻断、安装清理与 systemd 升级顺序。
- ShellCheck 使用 `--severity=warning`；动态提取的安装函数输入有局部注释，检查通过。`git diff --check` 和项目敏感信息扫描通过。
- 独立解析对照额外覆盖 1,106 个 IPv6 地址及 128 个 Endpoint 外层格式组合，全部一致；旧版阻断备用候选的复现与修复后的入口测试均完成。
- 真实 WARP：从活动的 `095681b` 升级到本次运行代码，实际编译固定版本 MicroSOCKS，确认 PID 更新与安装文件一致；健康检查、IP 和域名 SOCKS5h 请求、`cfwarp-exec` 域名请求及 doctor 通过。停止后 namespace/veth 消失，引用/日志清除，转发、默认路由和防火墙恢复。

首次额外域名请求在 5 秒连接上限内超时。后续验收明确代理路径、使用 15 秒连接上限并完整重跑后通过；首次失败未计为通过，不据此推断网络延迟或稳定性。私有 WARP 证据保留在专用 VM，未进入仓库。

### 范围

事务日志针对可重试的写入和系统调用失败；没有验证真实断电、磁盘损坏或持久 fsync 恢复。内核/systemd 验证不能代表所有 Linux 发行版。保留 Shell 控制层的原因见[架构说明](architecture.md)；没有声称 Rust 改写能改善未经测量的吞吐。

此前的[出口阻断和恢复记录](validation-2026-09-10.md)保留为历史证据，其“无剩余已知阻断项”仅代表当时的覆盖范围。

## English

Another independent review found gaps in `095681b` covering activating oneshots during upgrade, cross-file forwarding commits, and malformed IPv6 endpoints. The fixes were cross-reviewed by reviewers who did not author the corresponding changes.

| Finding | Fix and evidence |
| --- | --- |
| Upgrade misses activating helpers; cancelling refresh can restore main | Stop and wait for timers/helpers using ActiveState, then reread and stop main. A real systemd cancellation fixture restores a harmless main service; publication waits for its subsequent shutdown. |
| Build replaces MicroSOCKS too early | Build a staged binary and publish after shutdown. Failed stop preserves the old binary and removes staging. |
| Host-global upgrade cleanup relies on interface names | Remove compensation that bypasses ownership records and rely on the previous service's owned-resource cleanup. Foreign same-name interface regression passes. |
| Installation lock changes `/run/lock` permissions | Use root-private `/run/cfwarp-install` without modifying `/run/lock`; reject symlinks and unsafe lock directories. |
| State-write failure allows reference changes to be applied twice | Journal absolute target values under the global lock; reconcile before later operations and synchronize committed membership during ordinary state writes. Tests cover 52 before/after commit faults, other instances, EXIT cleanup, and fresh-process retries. |
| Invalid IPv6 or trailing port fragments block fallback candidates | Validate both IPv6 and the complete `[address]:port` structure. Parser and actual entrypoint regressions skip malformed candidates and use a valid backup. |

### Observed validation

- macOS: full unprivileged regressions pass, with Linux-only checks explicitly skipped.
- Dedicated Ubuntu 24.04.4 ARM64 VM, Linux 6.8.0-117-generic, systemd 255: `make integration` passes in an independent Git clone. `make test` and ShellCheck pass again after the final endpoint fix.
- Real kernel tests cover two-instance and concurrent reference updates, acquire/release state-write failure, repeated fresh-process cleanup, controlled WireGuard traffic, egress blocking after interface/route loss, installation cleanup, and systemd upgrade ordering.
- ShellCheck passes at `--severity=warning`, with narrow annotations for inputs to dynamically extracted installer functions. `git diff --check` and the project private-material scan pass.
- Independent parser checks also cover 1,106 IPv6 addresses and 128 outer endpoint formats with matching results. Both the old fallback failure and the corrected entrypoint behavior were reproduced.
- Live WARP: upgrade an active `095681b` installation to this runtime while actually building the pinned MicroSOCKS version; verify the changed PID and installed files. Health, literal-IP/domain SOCKS5h requests, domain requests through `cfwarp-exec`, and doctor pass. Stop removes namespace/veth devices and reference/journal files, restoring forwarding, default routes, and firewall state.

The first extra domain request timed out with a five-second connection limit. A complete rerun with explicit proxy handling and a fifteen-second connection limit passed. The first failure was not counted as success, and no latency or stability conclusion is inferred. Private WARP receipts remain in the dedicated VM and are excluded from the repository.

### Limits

The journal handles retryable write and system-call failures; real power loss, disk corruption, and durable fsync recovery were not tested. Kernel/systemd results do not establish compatibility with every distribution. See the [architecture decision](architecture.md) for retaining Shell; no unmeasured throughput benefit is claimed for a Rust rewrite.

The [previous egress and recovery record](validation-2026-09-10.md) remains historical evidence. Its statement of no remaining known blockers applies only to the coverage available at that time.
