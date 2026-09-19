#!/usr/bin/env python3
"""Real flock contention around installer publication, with private fixtures."""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("flock"), "requires Linux flock")
class PublicationLocks(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="cfwarp-install-lock-")
        self.base = Path(self.work.name)
        self.source = self.base / "source"
        self.runtime = self.base / "runtime"
        for name in ("source/lib", "source/deploy", "runtime/lib", "runtime/deploy",
                     "runtime/bin", "env", "old-data", "new-data", "refresh", "units"):
            (self.base / name).mkdir(parents=True)
        for name in ("lib/cfwarp-common.sh", "deploy/cfwarp.env.example", "cfwarp-exec"):
            (self.source / name).write_text((ROOT / name).read_text())
        (self.runtime / "lib/cfwarp-common.sh").write_text((ROOT / "lib/cfwarp-common.sh").read_text())
        self.config = self.base / "env/cfwarp.env"
        self.config.write_text(f"CFWARP_DATA_DIR='{self.base / 'old-data'}'\n"
                               f"CFWARP_ENDPOINT_REFRESH_STATE_ROOT='{self.base / 'refresh'}'\n")
        (self.runtime / "deploy/installation.env").write_text(f"CFWARP_ENV_FILE='{self.config}'\n")
        self.old_runtime = self.runtime / "entrypoint.sh"
        self.old_runtime.write_text("old runtime\n")
        (self.runtime / "bin/wg-quick").write_text("#!/bin/bash\nexit 0\n")
        (self.base / "candidate").write_text("#!/bin/bash\nexit 0\n")
        source = (ROOT / "install.sh").read_text().replace("reload_and_enable() {", "production_reload_and_enable() {").replace("/run/cfwarp-install", str(self.base / "install-lock"))
        marker = source.index('\nif [ "$RUN_DOCTOR" = "1" ]; then')
        overrides = """
require_root() { :; }
install_deps() { :; }
systemd_available() { [ "${SYSTEMD_RELOAD_TEST:-0}" = 1 ]; }
systemctl() {
    case "$1" in
        enable)
            if [ "${2:-}" = --now ]; then
                flock -n "$FIXTURE/old-data/.service-probe.lock" true || return 91
                flock -n "$FIXTURE/new-data/.service-probe.lock" true || return 92
                flock -n "$FIXTURE/refresh/refresh.lock" true || return 93
            fi ;;
    esac
    return 0
}
build_microsocks() { :; }
install_runtime_files() {
    touch "$FIXTURE/publishing"
    if [ "${PAUSE_PUBLICATION:-0}" = 1 ]; then
        while [ ! -e "$FIXTURE/release" ]; do sleep 0.05; done
    fi
    printf 'new runtime\\n' > "$INSTALL_PREFIX/entrypoint.sh"
}
reload_and_enable() {
    SYSTEMD_RELOAD_TEST=1
    production_reload_and_enable
}
print_summary() { :; }
"""
        self.installer = self.source / "install.sh"
        self.installer.write_text(source[:marker] + overrides + source[marker:])
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CFWARP_", "WG_QUICK_", "PAUSE_PUBLICATION"))}
        self.env.update(FIXTURE=str(self.base), WG_QUICK_SRC=str(self.base / "candidate"))

    def tearDown(self):
        self.work.cleanup()

    def command(self, *extra):
        return ["sh", str(self.installer), "--prefix", str(self.runtime),
                "--env-dir", str(self.base / "env"), "--data-dir", str(self.base / "new-data"),
                "--systemd-dir", str(self.base / "units"), *extra]

    def assert_busy_preserves_runtime(self, lock, *action):
        with (self.base / lock).open("a") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(self.command(*action), env=self.env, text=True,
                                    capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.old_runtime.read_text(), "old runtime\n")
            self.assertTrue((self.runtime / "lib/cfwarp-common.sh").exists())

    def test_busy_refresh_blocks_upgrade(self):
        self.assert_busy_preserves_runtime("refresh/refresh.lock")

    def test_busy_refresh_blocks_forced_cleanup(self):
        self.assert_busy_preserves_runtime("refresh/refresh.lock", "--clean-generated", "--force")

    def test_busy_old_lifecycle_blocks_upgrade(self):
        self.assert_busy_preserves_runtime("old-data/.service-probe.lock")

    def test_busy_old_lifecycle_blocks_forced_cleanup(self):
        self.assert_busy_preserves_runtime("old-data/.service-probe.lock", "--clean-generated", "--force")

    def test_busy_new_lifecycle_blocks_upgrade(self):
        self.assert_busy_preserves_runtime("new-data/.service-probe.lock")

    def test_recorded_old_config_and_new_refresh_are_both_locked(self):
        old_config = self.base / "recorded-old.env"
        old_config.write_text(self.config.read_text())
        (self.runtime / "deploy/installation.env").write_text(f"CFWARP_ENV_FILE='{old_config}'\n")
        (self.base / "new-refresh").mkdir()
        self.config.write_text(f"CFWARP_ENDPOINT_REFRESH_STATE_ROOT='{self.base / 'new-refresh'}'\n")
        self.assert_busy_preserves_runtime("refresh/refresh.lock")
        self.assert_busy_preserves_runtime("new-refresh/refresh.lock")

    def test_hardlinked_lifecycle_files_do_not_self_conflict(self):
        (self.base / "old-data/.service-probe.lock").touch()
        os.link(self.base / "old-data/.service-probe.lock", self.base / "new-data/.service-probe.lock")
        result = subprocess.run(self.command(), env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pending_old_recovery_blocks_publication(self):
        (self.base / "old-data/.refresh-pending").write_text("fixture recovery\n")
        result = subprocess.run(self.command(), env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.old_runtime.read_text(), "old runtime\n")

    def test_pending_new_recovery_blocks_publication(self):
        (self.base / "new-data/.refresh-pending").write_text("fixture recovery\n")
        result = subprocess.run(self.command(), env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.old_runtime.read_text(), "old runtime\n")

    def test_publication_holds_locks_and_releases_before_start(self):
        process = subprocess.Popen(self.command(), env=self.env | {"PAUSE_PUBLICATION": "1"},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not (self.base / "publishing").exists():
                self.assertIsNone(process.poll(), "installer exited before publication")
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.02)
            for lock in ("refresh/refresh.lock", "old-data/.service-probe.lock", "new-data/.service-probe.lock",
                         "install-lock/install.lock"):
                with self.subTest(lock=lock), (self.base / lock).open("a") as contender:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.base / "release").touch()
            output, errors = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, output + errors)
        finally:
            (self.base / "release").touch()
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=10)


if __name__ == "__main__":
    unittest.main(verbosity=2)
