# 贡献指南 / Contributing

## 中文

修改应聚焦 [项目范围](PROJECT.md)，并同时更新中英文用户说明。不要提交运行中的 WARP 状态、私钥、账户、访问令牌、私有环境文件、完整生产日志或编译产物。

开发检查需要 Python 3、`ripgrep` 和 ShellCheck；网络集成测试还需要项目的 Linux 网络依赖。提交前先运行：

```bash
make test
git diff --check
```

在专用 Linux 测试机执行真实内核网络验证，该命令需要 root 并创建临时网络资源：

```bash
make integration
```

还应运行 CI 中定义的 ShellCheck 和敏感信息扫描。扫描器缺失或执行失败属于检查失败，不能当作“没有检出问题”。

修复应带有能证明行为的回归用例，例如配置优先级、失败清理或资源名称碰撞，而不仅是语法检查。涉及 namespace、WireGuard、iptables、sysctl、systemd 沙箱或信号处理的改动，需在隔离 Linux 环境检查启动、停止、失败恢复和资源残留。真实 WARP 连通性测试与 mock 测试应分别标注；没有验证的部署环境或性能指标应明确写出。

PR 请说明触发条件、修改后的行为、验证命令与结果，以及已知限制。涉及停止服务或改变宿主机路由的操作必须在用户文档中说明。保留 [LICENSE](LICENSE) 与 [NOTICE.md](NOTICE.md) 中的法律声明。

## English

Keep changes focused on the [project scope](PROJECT.md), and update both Chinese and English user documentation. Do not commit runtime WARP state, private keys, accounts, access tokens, private environment files, complete production logs, or compiled artifacts.

Development checks require Python 3, `ripgrep`, and ShellCheck; network integration also needs the project's Linux networking dependencies. Before submitting, run:

```bash
make test
git diff --check
```

On a dedicated Linux test machine, run kernel-network integration checks. This requires root and creates temporary network resources:

```bash
make integration
```

Also run the ShellCheck and private-material scanning steps defined in CI. A missing or failed scanner is a failed check, not evidence that no sensitive material was found.

Add regressions that verify behavior, such as configuration precedence, failure cleanup, or resource-name collisions. Syntax checks alone are insufficient. Changes affecting namespaces, WireGuard, iptables, sysctl, systemd sandboxing, or signal handling require startup, shutdown, failure-recovery, and leftover-resource checks in an isolated Linux environment. Report real WARP connectivity separately from mocked tests, and identify unverified environments or performance claims.

Describe the trigger, resulting behavior, validation commands and outcomes, and known limitations in the PR. Document operations that stop the service or change host routing. Preserve the legal notices in [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
