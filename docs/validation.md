# 验证记录 / Validation record

日期 / Date: 2026-09-09

运行代码提交 / Tested runtime commit: [`988e896f967325709a7b3b7276e4ee2ed379a017`](https://github.com/killertop/CFWarp/commit/988e896f967325709a7b3b7276e4ee2ed379a017)

## 中文

### 环境与结果

本次验收使用该提交的独立 Git 克隆，安装并运行同一份代码。专用测试虚拟机为 Ubuntu 24.04.4 ARM64，Linux `6.8.0-117-generic`、systemd 255、ShellCheck 0.9.0、wireguard-tools 1.0.20210914。网络测试顺序执行，避免并行修改宿主机转发状态影响结果。

| 检查 | 结果与范围 |
| --- | --- |
| `make integration` | 通过：Shell 语法、源码扫描、10 项 Python 回归、运行时回归、真实内核网络与 systemd 集成、自定义安装和清理。 |
| ShellCheck | 全部项目 Shell 文件在 `--severity=warning` 下通过。 |
| 配置和错误路径 | 覆盖字面量配置解析、环境优先级、Endpoint 身份、响应注入、重试、超时、子进程退出、回滚和扫描器失败。 |
| 资源归属与并发 | 覆盖外部 namespace/veth 保留、状态缺失或身份不符、DNS、双实例转发引用、锁内内核变更、防火墙查询失败及清理重试。 |
| systemd 与安装 | 三类服务模板均通过真实 namespace 挂载可见性检查；自定义路径安装、升级和清理通过。 |
| 默认 netns 模式真实 WARP | SOCKS5h 域名请求、`cfwarp exec` 域名请求均返回 `warp=on`；安装态 doctor、watchdog、默认跳过的 Endpoint 刷新、重启和停止通过。宿主机默认路由保留，停服后 forwarding 与防火墙恢复，namespace/veth 移除，服务为 `inactive` 且 `Result=success`。 |
| host-global 模式真实 WARP | 启用严格反向路径过滤 `rp_filter=1` 时健康检查通过；停服后已归属接口移除、默认路由恢复、WARP 策略路由清理。 |
| 独立代码复查 | 多轮复查发现的问题均已修复。最终锁竞争复验确认：等待锁超时不会覆盖持锁者更新后的 Endpoint，不创建旧备份，也不执行网络操作。最终复查无剩余阻断项。 |

复现本地检查（网络集成需要专用 Linux 环境及 root）：

```bash
make integration
shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh
```

GitHub CI 对 Ubuntu 24.04 AMD64 和 ARM64 运行静态、行为、内核网络、systemd 及安装回归。每次提交的实际状态见 [GitHub Actions](https://github.com/killertop/CFWarp/actions/workflows/ci.yml)。CI 不注册 WARP 账户，也不代替上述单独执行的真实 WARP 验收。

### 边界

这份记录对应上述运行代码提交；后续仅补充说明文档。真实 WARP 检查证明被测服务器在验收时段内的连通性与恢复行为，未进行带宽基准、长期稳定性测试或所有 Linux 发行版验证。Endpoint 刷新的候选切换、失败恢复和进程清理由回归测试覆盖；真实联网验收只执行默认关闭刷新时的跳过路径，未对全部公网候选进行实测。

固定版本 MicroSOCKS 编译成功，其源码产生两条 GCC `write` 返回值未使用警告；这不属于项目 ShellCheck 检查结果。测试账户、WireGuard 私钥、完整 trace 和机器地址未纳入仓库。通过当前检查表示没有已知发布阻断项，不构成不存在任何缺陷的保证。

## English

### Environment and results

Acceptance used an independent Git clone of the runtime commit above, with the same code installed for live checks. The dedicated VM ran Ubuntu 24.04.4 ARM64, Linux `6.8.0-117-generic`, systemd 255, ShellCheck 0.9.0, and wireguard-tools 1.0.20210914. Networking tests ran sequentially to avoid interference from concurrent changes to host forwarding.

| Check | Result and coverage |
| --- | --- |
| `make integration` | Passed: Shell syntax, source scan, 10 Python regressions, runtime regressions, real kernel networking and systemd integration, custom installation and cleanup. |
| ShellCheck | All project Shell files passed at `--severity=warning`. |
| Configuration and failure paths | Covered literal configuration parsing, environment precedence, endpoint identity, response injection, retries, timeouts, child-process shutdown, rollback, and scanner failures. |
| Ownership and concurrency | Covered preservation of foreign namespaces/veth devices, missing or mismatched state, DNS, forwarding references across two instances, locked kernel mutations, firewall query failures, and cleanup retries. |
| systemd and installation | All three service templates passed real namespace mount-visibility checks; custom-path installation, upgrade, and cleanup passed. |
| Live WARP in default netns mode | SOCKS5h and `cfwarp exec` domain requests returned `warp=on`. Installed doctor, watchdog, default endpoint-refresh skip, restart, and stop passed. Host default routes were preserved; forwarding and firewall state were restored on stop, namespaces/veth devices were removed, and the service ended `inactive` with `Result=success`. |
| Live WARP in host-global mode | Health passed with strict reverse-path filtering (`rp_filter=1`). Stop removed the owned interface, restored default routes, and cleaned WARP policy routing. |
| Independent code review | Findings from multiple review rounds were fixed. Final contention testing confirmed that lock timeout preserves the owner's updated endpoint, creates no stale backup, and invokes no networking operations. No blockers remained in the final review. |

Reproduce local checks on a dedicated Linux machine with root available for networking integration:

```bash
make integration
shellcheck --severity=warning *.sh cfwarp-exec cmd/cfwarp lib/cfwarp-common.sh tests/*.sh
```

GitHub CI runs static, behavioral, kernel-networking, systemd, and installation regressions on Ubuntu 24.04 AMD64 and ARM64. See [GitHub Actions](https://github.com/killertop/CFWarp/actions/workflows/ci.yml) for each commit's actual status. CI does not register WARP accounts or replace the separately performed live WARP acceptance above.

### Limits

This record identifies the tested runtime commit; subsequent additions only document the results. Live WARP checks establish connectivity and recovery on the tested server during the acceptance window. They are not bandwidth benchmarks, long-term stability tests, or validation of every Linux distribution. Regression tests cover endpoint-refresh candidate switching, failure recovery, and process cleanup; live acceptance exercised only the default disabled-refresh skip path, without testing every public endpoint candidate.

The pinned MicroSOCKS build succeeded with two GCC warnings about unused `write` return values in its source; these are separate from the project's ShellCheck results. Test accounts, WireGuard private keys, full traces, and machine addresses are excluded from the repository. Passing the current checks means no known release blockers remain, not a guarantee that no defects exist.
