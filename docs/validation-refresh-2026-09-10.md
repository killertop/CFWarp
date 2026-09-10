# Endpoint 刷新生命周期验收 / Endpoint refresh lifecycle validation

日期 / Date: 2026-09-10

运行代码 / Runtime: [`44055d1`](https://github.com/killertop/CFWarp/commit/44055d1)

## 中文

外部复查在 `6b9b071` 指出两项此前遗漏的 P2：刷新漏判主服务 `activating`，以及探测清理失败后仍尝试启动主服务。使用原函数在 Bash、Dash 下分别复现后，本次修复并补充完整流程验证。

### 修改

- 用 ActiveState 判断运行和过渡状态。`skip` 安全跳过；`stop-and-probe` 停止并确认退出，未知状态或读取失败终止刷新。
- 启动、清理和刷新共用数据目录中的生命周期锁。取得锁后再次读取服务状态，清理主服务残留，再开始探测。主服务在锁内读取配置，避免使用刷新前的旧快照。
- 在探测前记录 `.refresh-pending`。探测清理失败不再被恢复分支覆盖；标记和恢复材料保留，后续启动和刷新也拒绝执行。
- 只有确认探测资源清理完成才解除阻断，释放锁后再请求 systemd 启动。失败回滚重新取得锁；`ExecStopPost` 不能越过另一个活动控制器的锁清理资源。

### 实际验证

使用独立 Git 克隆，在专用 Ubuntu 24.04.4 ARM64 VM（Linux 6.8.0-117-generic、systemd 255）顺序执行：

```sh
make integration
shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh
```

全部通过。除原有真实内核网络、WireGuard、出口阻断、安装与恢复回归外，新增/扩展测试包括：

- 启动、停止、重载状态下的 skip/stop-and-probe；状态读取失败、未知状态、停止失败、停止后仍 busy。
- 持续探测清理失败时零次主服务恢复，备份及阻断标记保留；后续启动被拒绝。
- 真实文件锁与独立进程：状态显示 inactive 但主控制器仍运行；探测期间并发启动/清理；取消探测后的清理与解锁；清理失败跨进程阻断；主服务网络清理失败阻止探测。
- 真实 systemd 单元：主进程已运行而 ExecStartPost 未完成时为 activating；skip 不停止它，stop-and-probe 完成停服、探测及恢复；探测清理失败后主服务保持停止，后续启动最终为 failed。

新增生命周期自动化测试使用网络/探测 worker 替身，真实文件锁、进程和 systemd 结果与下面的真实 WARP 验收分别记录。

### 真实 WARP 与残留接口故障

复用专用 VM 的既有私有 WireGuard 配置，安装同版本运行文件；未注册新账户。

1. 让真实 WARP 主服务完成健康检查后仍停留在 ExecStartPost，确认状态 activating。skip 刷新成功跳过，主服务和隧道继续运行。
2. 从同一 activating 状态执行实际 stop-and-probe，成功停止、探测、恢复，域名 SOCKS5h 请求返回 `warp=on/plus`。
3. 在真实探测 WireGuard 接口建立后终止该 namespace 中的探测进程，并在网络清理入口注入失败，使实际内核接口残留。刷新失败，主服务保持 inactive，阻断标记存在；另一次 systemd 启动也被标记拒绝，主 namespace 未创建，残留探测接口仍可确认。
4. 恢复原运行脚本，使用记录的资源归属清理探测 namespace，核对原配置未改变后移除阻断标记。主服务重新启动，WARP 健康和 doctor 通过。
5. 最终停服后 namespace/veth 移除，转发引用及事务日志清除，IPv4 forwarding、默认路由和防火墙恢复。配置与临时 systemd 测试覆盖已恢复，注入脚本与源码一致性已核对。

私有配置、完整 trace、日志和恢复目录仅保留在测试 VM；未提交到仓库。先前的[升级验收记录](validation-upgrade-2026-09-10.md)属于历史覆盖，不代表已覆盖本次新发现的分支。

### 范围

互斥适用于使用同一数据目录的受管理入口；不覆盖绕过入口启动或将同一身份复制到其他目录的程序。标记不会代替人工检查残留接口和配置；不能直接删除标记来强行启动。未进行掉电、所有发行版、长期稳定性或带宽测试。本次修复后复核未发现剩余的已知阻断项，这不构成不存在其他缺陷的保证。

## English

External review identified two P2 gaps in `6b9b071`: refresh missed an activating main service, and failed probe cleanup still allowed main restoration. Both were reproduced using original functions under Bash and Dash before repair.

### Changes

- Read ActiveState explicitly. Skip active/transitional services in skip mode; stop and confirm shutdown in stop-and-probe mode. Unknown states and failed reads abort refresh.
- Share a per-data-directory lifecycle lock between startup, cleanup, and refresh. Recheck state and finish residual main cleanup under the lock before probing. Main reads configuration under the lock to avoid stale snapshots.
- Write `.refresh-pending` before probing. Failed probe cleanup vetoes restoration, retaining recovery material and blocking later starts and refreshes.
- Clear the marker only after confirmed probe cleanup and release the lock before asking systemd to start main. Rollback reacquires the lock; ExecStopPost cannot clean resources held by another active controller.

### Observed validation

An independent Git clone passed `make integration` and ShellCheck at warning severity on a dedicated Ubuntu 24.04.4 ARM64 VM, Linux 6.8.0-117-generic, systemd 255. Tests ran sequentially.

Existing kernel-network, WireGuard, egress-blocking, installation, and recovery checks pass. Added coverage includes starting/stopping/reloading states, state-read and stop failures, persistent cleanup failure without restoration, and retained recovery markers. Real file locks and independent processes cover both sides of the startup/probe race, cancellation, later-process blocking, fresh configuration reads, and refusal to probe after failed main cleanup. Disposable real systemd units cover activating ExecStartPost, skip, stop/probe/restore, and failed later startup after cleanup failure. These automated lifecycle tests use network/probe fixtures; real WARP evidence is separate below.

### Live WARP and residual-interface failure

Matching runtime files reused existing private WireGuard configuration without registering a new account.

1. Hold a healthy real WARP service in ExecStartPost/activating; skip leaves it running.
2. Run actual stop-and-probe from that state; shutdown, probing, restoration, and a domain SOCKS5h request pass with `warp=on/plus`.
3. After a real probe WireGuard interface exists, terminate processes inside that namespace and inject failure before network cleanup. The kernel interface remains, refresh fails, main stays inactive, and the pending marker blocks another systemd startup without creating the main namespace.
4. Restore the original script, clean the probe using recorded ownership, verify unchanged configuration, and remove the marker. Main startup, WARP health, and doctor pass again.
5. Final shutdown removes namespace/veth devices and reference/journal files, restoring IPv4 forwarding, default routes, and firewall state. Original configuration and temporary systemd overrides are restored; runtime files match the source again.

Private configuration, complete traces, logs, and recovery folders remain only in the test VM. The [previous upgrade record](validation-upgrade-2026-09-10.md) describes historical coverage and did not cover these newly identified paths.

### Limits

The lock coordinates managed entry points sharing a data directory, not bypassed entry points or identities copied elsewhere. Inspect residual interfaces and configuration before clearing a pending marker; deleting it to force startup defeats recovery protection. Power loss, every distribution, long-term stability, and bandwidth were not tested. Review found no remaining known blockers in this revision; this does not guarantee the absence of other defects.
