# MicroSOCKS used by CFWarp

Source: <https://github.com/rofl0r/microsocks>

Upstream commit: `98421a21c4adc4c77c0cf3a5d650cc28ad3e0107`.
The upstream MIT license and copyright are retained in [COPYING](COPYING).
The install helper retains its original license notice.

CFWarp changes in `sockssrv.c`:

- Read complete SOCKS5 greeting, authentication and CONNECT frames across TCP
  segments. Read only the required bytes so pipelined application data survives.
- Give the entire handshake a monotonic deadline, default 10 seconds. A client
  cannot reset the deadline by sending occasional bytes.
- Limit simultaneous clients to 128, including clients that have not authenticated.
  Reject excess connections before allocating a worker thread.
- Synchronize worker completion and close/free clients when thread creation fails.

The installer builds these bundled sources in a temporary directory, without
downloading a different MicroSOCKS implementation. `MICROSOCKS_REPO` and
`MICROSOCKS_COMMIT` overrides must match the provenance above. `--skip-build`
retains the existing binary; it does not apply these fixes to that binary.

For deliberate capacity changes, `MICROSOCKS_CFLAGS` can define
`CFWARP_MAX_CLIENTS` (1–65535) and `CFWARP_HANDSHAKE_TIMEOUT_SECONDS` (1–3600).
The timeout covers protocol reception; blocked target DNS/connect operations
remain subject to the total client limit. It does not change the existing
15-minute idle timeout for established proxy traffic.

`python3 tests/microsocks-regression.py` compiles isolated copies and tests real
loopback connections, fragmented/coalesced frames, authentication, timeout and
capacity recovery. Run it from the CFWarp repository root, or use `make test`.
