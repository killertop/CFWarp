# Changelog

## Unreleased

- Prepared an independent Linux bare-metal release of CFwarp.
- Removed server-specific paths, runtime state, private environment files, and
  service-specific checks from the public source tree.
- Pinned and checksum-validated the default `wgcf` download.
- Added conservative namespace teardown, ref-counted IPv4 forwarding, health
  checks, watchdog cooldowns, endpoint rollback, and release smoke tests.
