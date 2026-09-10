# 异常恢复与出口阻断验证 / Failure recovery and egress validation

日期 / Date: 2026-09-10

运行代码提交 / Tested runtime commit: [`836c5a6ec30f2cbab2cadc1424c85bdd5f40c3ac`](https://github.com/killertop/CFWarp/commit/836c5a6ec30f2cbab2cadc1424c85bdd5f40c3ac)

## 中文

补充审查确认上一版 `3d0624f` 有五类异常处理缺陷，上一轮测试没有覆盖这些分支。本次已修复并增加独立复现、故障注入和真实网络检查；[旧记录](validation.md) 保留为历史证据，并已标明覆盖缺口。

### 修复与证据

| 问题 | 修复及实际验证 |
| --- | --- |
| 转发锁超时后继续执行 | 显式失败返回并关闭 FD。条件调用故障注入、真实文件锁竞争均通过；失败时引用计数、原状态和内核值不变，清理状态保留，释放锁后重试成功。 |
| 隧道失效后可能直连 | 连网前安装双栈默认拒绝规则。受控 IPv4/IPv6 HTTP 与 UDP 在关闭保护的对照中成功，在开启保护后被阻断；已有直连 TCP 也不能借用代理返回流量的例外。真实 WireGuard peer 通信成功，删除隧道路由或接口后，新建及已有 TCP 被阻断。 |
| `cfwarp-exec` 启动窗口 | 在归属锁内检查规则、握手和路由，并持锁进入 namespace。未就绪时拒绝；已进入的长命令在停服、同名 namespace 被替换后仍留在原受保护 namespace，不会跟随新名称直连。 |
| 无效初始 Endpoint 阻止备用候选 | 账户初始化和候选 DNS 在宿主机准备。真实 WARP 验收中，初始域名为 `stale.invalid`、显式地址为空，仍通过数字 IP 备用候选完成启动；现有账户保持原样，正常服务保存验证成功的候选。 |
| 拒绝清理却停止守护 | 安装锁前后执行只读检查，识别 active、activating、deactivating 等状态。stub 与真实 systemd oneshot/定时器检查均通过；拒绝操作保留服务、定时器、文件和 enable 状态。 |
| 失败回滚删除原备份 | 刷新前在持久数据目录建立受限权限恢复目录。故障注入覆盖恢复写入失败、服务停止或健康失败、探测清理失败及后续成功运行；原件保留，半恢复配置不自动启动。真实刷新遇到 systemd 启动频率限制时，也实际保留了原配置及日志。 |
| 启动脚本备份读取失败清空配置 | 改用输入重定向，使备份读取错误直接失败；回归确认不会把空内容写入当前配置。 |

### 完整验收

使用该提交的独立 Git 克隆与同版本安装文件，在专用 Ubuntu 24.04.4 ARM64 虚拟机上执行；Linux `6.8.0-117-generic`、systemd 255、ShellCheck 0.9.0。网络测试顺序执行。

```bash
make integration
shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh
```

以上全部通过，包含 11 项 Python 基础回归、运行时与故障恢复回归、真实内核网络、真实 WireGuard、systemd 模板和自定义安装清理。macOS 的无特权测试也通过，Linux 专属项在 macOS 明确跳过。

同一版本的真实 WARP 验收通过：

- 复用现有账户重新生成 profile，宿主机初始化和 Endpoint 解析成功。
- SOCKS5h 域名请求、`cfwarp-exec` 域名请求返回 `warp=on`，安装态 doctor 通过。
- 分别删除 WireGuard 默认路由和接口后，代理进程仍存活，连续三次真实 SOCKS 请求全部失败，出口 DROP 计数增加，`cfwarp-exec` 拒绝执行；恢复路由后健康检查重新通过。
- 停止后 namespace/veth 移除、IPv4 forwarding 恢复、防火墙规则与策略恢复、服务为 `inactive` 且 `Result=success`。防火墙比对排除随流量正常变化的包/字节计数。
- 实际运行 `stop-and-probe` Endpoint 刷新，候选探测、服务恢复和 WARP 健康验证通过；watchdog 通过。
- 单独检查 `host-global` 在 `rp_filter=1` 时真实 WARP 连通，停止后接口移除、默认路由恢复。

连续独立测试会消耗 systemd 的启动频率额度；正常流程验收在独立场景之间重置测试计数，生产的启动频率策略保持不变。恢复失败现场与成功路径分别保留证据，未把受限重启当作成功。

GitHub CI 对 Ubuntu 24.04 AMD64 与 ARM64 执行同一套静态、行为、内核网络、出口阻断和安装检查。各提交状态见 [GitHub Actions](https://github.com/killertop/CFWarp/actions/workflows/ci.yml)。CI 使用本机受控 WireGuard peer，不注册 WARP 账户。

### 范围

默认 namespace 模式提供上述阻断，`host-global` 没有宿主机全局 kill switch。账户初始化和初始隧道 Endpoint DNS 使用宿主机网络；应用 DNS 通过隧道。IPv6 阻断测试不代表提供 IPv6 WARP 出站。拥有 root/网络管理能力的程序可以主动修改规则，此机制不隔离恶意 root。

真实 WARP 结果对应当前服务器和短时间窗口；没有进行长期稳定性、带宽基准、全部公网候选或所有 Linux 发行版测试。私钥、账户、完整 trace 和私有恢复目录不纳入仓库。独立复查报告的问题均已闭合，当前检查没有剩余已知阻断项；这不等于不存在任何缺陷。

## English

Follow-up review confirmed five categories of failure-path defects in `3d0624f` that the previous tests missed. This revision fixes them and adds independent reproductions, fault injection, and real networking checks. The [previous record](validation.md) remains as historical evidence with its coverage gaps explicitly identified.

### Fixes and evidence

| Finding | Fix and observed validation |
| --- | --- |
| Continuing after forwarding-lock timeout | Explicit failure return and FD closure. Conditional-call fault injection and real file-lock contention passed: references, original state, and kernel values remain unchanged; cleanup state survives and retry succeeds after lock release. |
| Direct fallback when the tunnel disappears | Install dual-stack default-deny rules before connectivity. Controlled IPv4/IPv6 HTTP and UDP succeed with protection disabled and are blocked when enabled; existing direct TCP cannot borrow the proxy-reply exemption. Real WireGuard peer traffic succeeds; route/interface deletion blocks new and existing TCP. |
| `cfwarp-exec` readiness window | Check rules, handshakes, and routing under the ownership lock, keeping it through namespace entry. Unready execution is refused. Long-running commands retain the protected original namespace after teardown and name reuse, without following its replacement. |
| Invalid initial endpoint prevents fallback | Prepare accounts and candidate DNS on the host. Live WARP startup recovered from `stale.invalid` with an empty explicit endpoint and a literal-IP backup candidate. The existing account stayed unchanged and the healthy candidate was saved. |
| Refused cleanup stops supervision | Read-only checks before and after the installation lock recognize active, activating, deactivating, and other busy states. Stub and real systemd oneshot/timer tests passed, preserving services, timers, files, and enablement after refusal. |
| Failed rollback deletes originals | Create a protected persistent recovery directory before refresh. Fault injection covers failed writes, service stop/health failure, probe cleanup failure, and subsequent successful runs. Originals survive and partially restored configuration is not automatically started. A real systemd start-limit failure also retained originals and logs. |
| Entrypoint backup-read failure truncates configuration | Use input redirection so backup-read errors fail directly; regression confirms the current configuration is not replaced with empty contents. |

### Acceptance

Tests used an independent clone of the runtime commit and matching installed files on a dedicated Ubuntu 24.04.4 ARM64 VM: Linux `6.8.0-117-generic`, systemd 255, ShellCheck 0.9.0. Networking tests ran sequentially.

```bash
make integration
shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh
```

All passed, including 11 base Python regressions, runtime and recovery tests, real kernel networking, real WireGuard, systemd templates, and custom installation/cleanup. Unprivileged macOS tests passed with Linux-specific checks explicitly skipped.

Live WARP acceptance on the same code passed:

- Host bootstrap generated a fresh profile from an existing unchanged account and resolved endpoints.
- SOCKS5h and `cfwarp-exec` domain requests returned `warp=on`; installed doctor passed.
- Separately deleting the WireGuard default route and interface left the proxy process alive but blocked three consecutive real SOCKS requests each time. Egress DROP counters increased and `cfwarp-exec` refused execution. Restoring the route restored health.
- Stop removed namespace/veth devices, restored IPv4 forwarding and firewall rules/policies, and ended `inactive` with `Result=success`. Firewall comparison excludes packet/byte counters that normally change with traffic.
- Actual `stop-and-probe` refresh passed candidate probing, service recovery, and WARP health verification; watchdog passed.
- Separate `host-global` checks passed live WARP with `rp_filter=1`, interface removal, and default-route restoration.

Repeated independent scenarios consume systemd's start-rate allowance. Normal-flow acceptance reset test counters between separate scenarios; production rate limits were unchanged. Failed-recovery evidence was kept separately from successful-path evidence and was not reported as a successful restart.

GitHub CI runs the same static, behavioral, kernel-networking, egress-blocking, and installation checks on Ubuntu 24.04 AMD64 and ARM64. See [GitHub Actions](https://github.com/killertop/CFWarp/actions/workflows/ci.yml) for each commit. CI uses controlled local WireGuard peers and does not register WARP accounts.

### Limits

Protection applies to default namespace mode; `host-global` has no host-wide kill switch. Account initialization and initial tunnel-endpoint DNS use the host network; application DNS uses the tunnel. IPv6 blocking tests do not imply IPv6 WARP egress support. Programs with root/network-management privileges can deliberately modify rules; this is not isolation from malicious root.

Live WARP results apply to the tested server and short time window. No long-term stability, bandwidth benchmarks, exhaustive public-candidate tests, or all-distribution validation were performed. Private keys, accounts, full traces, and private recovery directories are excluded from the repository. Independently reported findings are closed with no remaining known blockers in the current checks; this is not a guarantee that no defects exist.
