#!/usr/bin/env python3
"""Run the installer flow with service/dependency side effects replaced by fixtures."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIVE = "--live" in sys.argv
if LIVE:
    sys.argv.remove("--live")


class Preflight(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="cfwarp-preflight-")
        self.base = Path(self.work.name)
        for directory in ("lib", "deploy", "runtime/bin"):
            (self.base / directory).mkdir(parents=True)
        for name in ("lib/cfwarp-common.sh", "deploy/cfwarp.env.example", "cfwarp-exec"):
            (self.base / name).write_text((ROOT / name).read_text())
        source = (ROOT / "install.sh").read_text()
        # Keep the actual final call order and wg-quick staging/publication.
        # Simulate other installation operations without root or real services.
        marker = source.rindex("\nrequire_root\n")
        overrides = """
require_root() { :; }
install_deps() { :; }
acquire_install_lock() { :; }
acquire_install_runtime_locks() { :; }
release_install_runtime_locks() { :; }
build_microsocks() { :; }
stop_for_upgrade() {
    echo stop >> "$FIXTURE/events"
    if [ "${CHANGE_SOURCE_AFTER_PREPARE:-0}" = 1 ]; then
        printf '#!/bin/bash\\nif then\\n' > "$WG_QUICK_SRC"
    fi
}
publish_microsocks() { echo publish >> "$FIXTURE/events"; }
install_runtime_files() { echo runtime >> "$FIXTURE/events"; }
reload_and_enable() { echo start >> "$FIXTURE/events"; }
print_summary() { :; }
"""
        (self.base / "install.sh").write_text(source[:marker] + overrides + source[marker:])
        self.old = self.base / "runtime/bin/wg-quick"
        self.old.write_text("#!/bin/bash\necho old-working-copy\n")
        self.old.chmod(0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CFWARP_", "WG_QUICK_"))}
        self.env.update(FIXTURE=str(self.base), WG_QUICK_SRC=str(self.base / "candidate"))

    def tearDown(self):
        self.work.cleanup()

    def install(self):
        return subprocess.run(["sh", str(self.base / "install.sh"),
                               "--prefix", str(self.base / "runtime"),
                               "--data-dir", str(self.base / "data"),
                               "--env-dir", str(self.base / "env"),
                               "--systemd-dir", str(self.base / "units")],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def assert_preserved(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "events").exists(), result.stderr)
        self.assertEqual(self.old.read_text(), "#!/bin/bash\necho old-working-copy\n")
        self.assertEqual(list(self.old.parent.glob(".wg-quick.new.*")), [])

    def test_missing_wg_quick_fails_before_stop(self):
        self.assert_preserved(self.install())

    def test_invalid_wg_quick_fails_before_stop_without_overwriting_old_copy(self):
        (self.base / "candidate").write_text("#!/bin/bash\nif then\n")
        self.assert_preserved(self.install())

    def test_valid_wg_quick_is_published_and_service_restored(self):
        (self.base / "candidate").write_text("#!/bin/bash\necho new-copy\n")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.old.read_text(), "#!/bin/bash\necho new-copy\n")
        self.assertEqual((self.base / "events").read_text(), "stop\npublish\nruntime\nstart\n")

    def test_publication_uses_the_validated_snapshot(self):
        (self.base / "candidate").write_text("#!/bin/bash\necho checked-copy\n")
        self.env["CHANGE_SOURCE_AFTER_PREPARE"] = "1"
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.old.read_text(), "#!/bin/bash\necho checked-copy\n")

    def test_private_copy_can_be_used_as_the_source(self):
        self.env["WG_QUICK_SRC"] = str(self.old)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.old.read_text(), "#!/bin/bash\necho old-working-copy\n")


@unittest.skipUnless(LIVE, "--live enables real systemd stop-result validation")
class SystemdCleanup(unittest.TestCase):
    def test_successful_stop_with_failed_exec_stop_post_is_rejected(self):
        self.assertEqual(sys.platform, "linux")
        self.assertEqual(os.geteuid(), 0)
        unit = f"cfwarp-preflight-test-{os.getpid()}.service"
        try:
            subprocess.run(["systemd-run", "--unit=" + unit,
                            "--property=ExecStopPost=/bin/false", "/bin/sleep", "60"],
                           check=True, capture_output=True, timeout=15)
            stopped = subprocess.run(["systemctl", "stop", unit], capture_output=True, timeout=15)
            self.assertEqual(stopped.returncode, 0)
            state = subprocess.check_output(["systemctl", "show", "-p", "ActiveState", "--value", unit], text=True)
            self.assertEqual(state.strip(), "failed")
            source = (ROOT / "install.sh").read_text()
            helper = source[source.index("cleanup_read_unit_state() {"):source.index("cleanup_preflight() {")]
            result = subprocess.run(["sh", "-c", helper + '\ncleanup_read_unit_state "$1"', "test", unit],
                                    capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0, result.stderr)
        finally:
            subprocess.run(["systemctl", "stop", unit], capture_output=True, timeout=15)
            subprocess.run(["systemctl", "reset-failed", unit], capture_output=True, timeout=15)


if __name__ == "__main__":
    unittest.main(verbosity=2)
