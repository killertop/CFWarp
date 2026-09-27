# 2026-09-28 验证记录 / Validation record

## 中文

基线：`cb0d32df81b3aab3a39d7ed4e3e2fd32b94ffc10`。GitHub 的 [AMD64/ARM64 CI](https://github.com/killertop/CFWarp/actions/runs/35460266901) 均在完整安装回归失败：测试用 oneshot 等待进程被正常停止后成为 failed，新安装器因此拒绝继续。

排查同时确认生产 unit 存在相同的退出状态问题，并发现清理期间重复停止信号可以中断恢复流程。此次未放宽安装器对 failed 或恢复标记的保护。

| 问题 | 修复前复现 | 修复与验证 |
| --- | --- | --- |
| 正常取消被记为失败 | 使用正式 unit 模板运行真实刷新/watchdog 脚本，正常停止均得到 failed | 声明清理完成后的退出码 143 为正常；取消后 inactive，清理/恢复错误仍 failed |
| 清理被停止信号中断 | 在 probe 清理期间再次向进程组发 TERM，刷新直接以信号 -15 退出；systemd 整组停止也曾得到错误的正常结束 | 刷新 unit 使用 KillMode=mixed，先通知控制器；清理忽略重复 HUP/INT/TERM；验证错误返回 1、保留阻断标记和恢复日志。180 秒停止超时仍允许 systemd 强制结束整个组 |
| 安装测试残留与隔离不足 | 原退出处理依赖已拒绝 failed 的安装器，随后直接删除临时目录；只检查主 unit 是否存在 | 检查全部五个服务/定时器；只撤销本次目录拥有的 unit 链接；失败保留日志。注入退出码 71 验证原错误不被吞掉、无运行 unit/残留链接 |

验证环境：新建专用 Ubuntu 24.04 ARM64 虚拟机，源码仅复制 Git 跟踪文件，不包含本地未跟踪草稿、账户或 WARP 凭据。原有虚拟机与安装保持不变。

已通过：

- 完整 `make integration`，包含 `make test`、真实 namespace/WireGuard 出站保护、完整安装/升级/清理回归、11 项生命周期测试及 6 项安装预检测试。
- `shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh`。
- 安装测试中途故障注入后的 unit 清理与退出码检查。
- `git diff --check`。

此前因既有服务未执行的完整安装测试，本次已在干净环境完成。没有执行公网 Cloudflare WARP 验收或升级用户生产服务；受控 WireGuard 对端测试不能替代公网验收。旧模板安装可能已经保留 failed，仍须检查日志、恢复标记并完成旧资源清理后再重试，不能盲目 reset-failed。

## English

Baseline: `cb0d32d`. Both CI architectures failed the full installation regression because a cancelled oneshot sleep fixture was classified as failed. The installer correctly refused to continue. Rendering the shipped refresh/watchdog templates reproduced the same classification problem with the real scripts.

The helper units now accept cancellation exit code 143 after shell cleanup. Actual cleanup or recovery errors remain failures. Refresh uses `KillMode=mixed` to signal its supervising controller first, ignores repeated stop signals during rollback, and retains a 180-second systemd stop timeout. A deterministic second-TERM regression verifies exit code 1, retained recovery markers, and a completed failure journal when cleanup fails.

The installation test now protects all five pre-existing services/timers and removes only links owned by its temporary installation. An injected failure preserved exit code 71 and diagnostic files while leaving no running units or dangling links.

A fresh Ubuntu 24.04 ARM64 VM passed full `make integration`, warning-level ShellCheck, the injected test-cleanup failure scenario, and whitespace checks. This closes the previous local full-installation validation gap. It does not claim public Cloudflare WARP acceptance or production-server upgrades. Existing failed helpers installed with old templates still require log/recovery inspection and safe cleanup before retrying.

For the underlying distinction between numeric success statuses and oneshot signal exits, see the [systemd service reference](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml).
