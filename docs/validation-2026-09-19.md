# 2026-09-19 验证记录 / Validation record

## 中文

基于 `629b15917efcdae14ae4288aeb895ded0097de15`，结合 6 Pro 源码审查和本地故障复现，检查安装、刷新、namespace 归属、配置加载及 watchdog。审查建议不等同于运行证据；下列结果来自本地 Ubuntu 24.04.4 ARM64 隔离虚拟机。

### 修复与复现

| 问题 | 修复前证据 | 修复后保护 |
| --- | --- | --- |
| 停服回执掩盖清理失败 | 真实 systemd unit 的 `ExecStopPost=/bin/false`：`stop` 返回 0、状态为 `failed`；旧安装器放行 | 安装与强制清理拒绝 `failed`，停止后再次确认状态 |
| 直接刷新与安装并发 | 独立进程持真实刷新/生命周期锁时，旧安装器仍修改或清理运行文件 | 发布区同时锁住旧、新配置对应的刷新和生命周期目录，保留安装锁；启动前释放运行锁 |
| 不同数据目录接管同名 namespace | 真实 namespace 测试中，第二个数据目录的 `up` 清除了第一个实例的状态 | v3 状态校验规范化数据目录；覆盖 `up`、`down` 和失败启动的退出清理 |
| 配置缺失静默回退 | 基线提交接受不存在的显式环境文件和丢失的安装配置 | 启动、刷新、进入 namespace 要求指定配置可读；诊断和既有进程快照保持可用 |
| watchdog 撤销手动停服 | 控制健康检查期间的状态切换，旧代码把 `inactive`、`deactivating` 再次启动 | 条件重启及不替换排队停止任务；另测 failed/enabled、disabled 和冷却期 |
| `wg-quick` 校验发生在停服后 | 缺失或语法错误的候选文件导致先停服，再失败 | 停服前暂存、校验，发布经过校验的同一份文件 |

6 Pro 最终复审另指出条件重启后把所有非 active 状态视为主动停服的问题。新增测试在修复前复现 4 个失败断言；修复后仅 inactive/deactivating 正常退出，failed、未知状态和读取失败均报告失败并保留冷却时间。

### 已执行

- `make test`：通过，包括配置、运行、转发引用、安装拒绝/升级、刷新恢复及生命周期回归。新增锁回归共 10 项，watchdog 共 11 项；非 live 模式明确跳过 systemd 专项。
- `shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh`：通过。
- `sudo sh tests/network-regression.sh --live`：通过，包括不同数据目录的直接操作与失败控制器退出均保留原 namespace。
- `sudo python3 tests/network-egress-regression.py --live`：通过，使用受控 WireGuard 对端验证 IPv4/IPv6/UDP 基线、隧道接口/路由丢失后的 TCP 直连阻断及 namespace 名称复用。
- `sudo python3 tests/install-preflight-regression.py --live`：通过，包括真实 systemd 停止后清理失败的判定。
- `sudo python3 tests/refresh-lifecycle-regression.py --live`：6 项通过，包括真实 systemd 启动/停止过渡状态；结束后 namespace 列表为空。
- `git diff --check`：通过。

### 边界

- 完整 `tests/install-regression.sh --live` 检测到虚拟机已有 `cfwarp.service` 后主动拒绝运行；保留既有安装，未将此项记作通过。因此没有声称完整 `make integration` 通过。
- 本轮没有重新执行真实 Cloudflare WARP 公网测速或生产服务器升级。受控 WireGuard 测试不等于公网 WARP 验收。
- 锁回归运行真实 `flock` 和独立安装器进程，但替换了依赖安装、服务管理与文件发布副作用；不等同于完整 systemd 安装交错测试。
- 发布阶段互斥不提供多文件事务回滚、任意管理员配置变更隔离，或释放锁到服务启动之间的原子移交。失败后保留恢复工具，按使用说明处理并重试。
- 状态格式升级为 v3；使用安装器让旧运行版本先清理 v2 状态，不直接覆盖活动安装。

## English

Starting from `629b15917efcdae14ae4288aeb895ded0097de15`, a 6 Pro source review was followed by local fault reproduction and fixes. Review suggestions are distinct from execution evidence. Validation used an isolated Ubuntu 24.04.4 ARM64 VM.

The changes reject failed systemd cleanup; gate installer publication against direct refresh and both old/new lifecycle paths; bind namespace ownership to the canonical data directory; reject missing required runtime configuration; respect manual stops during watchdog health checks; and stage/validate `wg-quick` before stopping services.

`make test`, warning-level ShellCheck, live namespace/ownership tests, controlled WireGuard egress tests, live installer preflight/systemd cleanup validation, all six live refresh lifecycle cases, and diff whitespace checks passed. No named namespaces remained after the checks. The dedicated real-lock fixture has 10 cases and the watchdog suite has 11 cases. Existing failed/enabled recovery and cooldown behavior remain covered. Final 6 Pro review identified a false-success branch after conditional restart; four failing assertions reproduced it before correction. Only inactive/deactivating now count as a respected stop; failed, unknown, or unreadable states report failure while retaining cooldown.

The full installation integration test refused to run because the VM already contains `cfwarp.service`; the existing installation was preserved. Full `make integration`, production upgrades, and a fresh public Cloudflare WARP acceptance test are not claimed. Lock tests use real locks and separate processes but stub installation/service side effects. Publication is not a multi-file transaction or an atomic handoff to service startup. v2 namespace state must be cleaned by the previous runtime before upgrading to v3.
