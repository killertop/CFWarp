# Contributing

Keep changes focused on the documented Linux bare-metal scope. Do not add
runtime WARP state, private environment files, compiled binaries, or machine-
specific endpoints to the repository.

Before opening a pull request, run:

```bash
make test
```

Changes to namespace, WireGuard, iptables, sysctl, service sandboxing, or
credential handling should include a rollback path and a short explanation of
the security impact. Keep user-visible defaults conservative and document any
intentional downtime or host-wide routing change.
