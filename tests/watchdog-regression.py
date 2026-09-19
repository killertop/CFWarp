#!/usr/bin/env python3
"""Watchdog races with deterministic service-manager and healthcheck fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Watchdog(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="cfwarp-watchdog-")
        self.base = Path(self.work.name)
        (self.base / "lib").mkdir()
        (self.base / "bin").mkdir()
        (self.base / "systemd").mkdir()
        (self.base / "runtime.env").touch()
        (self.base / "lib/cfwarp-common.sh").write_text((ROOT / "lib/cfwarp-common.sh").read_text())
        # Only redirect the systemd-presence probe; execute the real watchdog.
        (self.base / "cfwarp-watchdog.sh").write_text(
            (ROOT / "cfwarp-watchdog.sh").read_text().replace(
                "/run/systemd/system", str(self.base / "systemd")))
        self.write_executable("bin/systemctl", """#!/bin/sh
set -eu
command=$1
shift
case "$command" in
    is-active) [ "$(cat "$FIXTURE/state")" = active ] ;;
    is-failed) [ "$(cat "$FIXTURE/state")" = failed ] ;;
    is-enabled) [ "${DISABLE_SERVICE:-0}" = 0 ] ;;
    show) [ "${SHOW_FAIL:-0}" = 0 ] || exit 1; cat "$FIXTURE/state" ;;
    restart|try-restart|start)
        printf '%s\\n' "$command" >> "$FIXTURE/actions"
        if [ -n "${RESTART_STATE:-}" ]; then
            printf '%s\\n' "$RESTART_STATE" > "$FIXTURE/state"
            exit "${RESTART_STATUS:-0}"
        fi
        if [ -n "${STOP_AT_RESTART:-}" ]; then
            printf '%s\\n' "$STOP_AT_RESTART" > "$FIXTURE/state"
            [ "$1" = --job-mode=fail ] || exit 98
            touch "$FIXTURE/job-mode-fail"
            # Model systemd rejecting a restart that conflicts with a stop job.
            if [ "$STOP_AT_RESTART" = deactivating ]; then exit 1; fi
        fi
        if [ "$command" != try-restart ] || [ "$(cat "$FIXTURE/state")" = active ]; then
            echo active > "$FIXTURE/state"
            touch "$FIXTURE/recovered"
        fi
        ;;
    *) exit 99 ;;
esac
""")
        self.write_executable("cfwarp-healthcheck.sh", """#!/bin/sh
set -eu
if [ -e "$FIXTURE/recovered" ]; then exit 0; fi
if [ -n "${STOP_DURING_HEALTH:-}" ]; then
    printf '%s\\n' "$STOP_DURING_HEALTH" > "$FIXTURE/state"
fi
exit 1
""")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CFWARP_", "STOP_DURING_HEALTH", "STOP_AT_RESTART"))}
        self.env.update(FIXTURE=str(self.base), PATH=f"{self.base / 'bin'}:{os.environ['PATH']}",
                        CFWARP_ENV_FILE=str(self.base / "runtime.env"),
                        CFWARP_WATCHDOG_STATE_FILE=str(self.base / "failures"),
                        CFWARP_WATCHDOG_RESTART_STATE_FILE=str(self.base / "last-restart"))
        (self.base / "state").write_text("active\n")
        (self.base / "failures").write_text("1\n")

    def tearDown(self):
        self.work.cleanup()

    def write_executable(self, name, text):
        path = self.base / name
        path.write_text(text)
        path.chmod(0o755)

    def run_watchdog(self, **overrides):
        return subprocess.run(["sh", str(self.base / "cfwarp-watchdog.sh")],
                              env=self.env | overrides, capture_output=True, text=True, timeout=10)

    def test_manual_stop_during_healthcheck_is_respected(self):
        result = self.run_watchdog(STOP_DURING_HEALTH="inactive")
        self.assertEqual((self.base / "state").read_text().strip(), "inactive", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / "recovered").exists())

    def test_stop_in_progress_during_healthcheck_is_respected(self):
        result = self.run_watchdog(STOP_DURING_HEALTH="deactivating")
        self.assertEqual((self.base / "state").read_text().strip(), "deactivating", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / "recovered").exists())

    def test_active_unhealthy_service_is_recovered(self):
        result = self.run_watchdog()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / "recovered").exists())

    def test_manual_stop_between_recheck_and_restart_is_respected(self):
        result = self.run_watchdog(STOP_AT_RESTART="inactive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "state").read_text().strip(), "inactive")
        self.assertTrue((self.base / "job-mode-fail").exists())
        self.assertFalse((self.base / "recovered").exists())

    def test_queued_stop_is_not_replaced_by_restart(self):
        result = self.run_watchdog(STOP_AT_RESTART="deactivating")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "state").read_text().strip(), "deactivating")
        self.assertTrue((self.base / "job-mode-fail").exists())
        self.assertFalse((self.base / "recovered").exists())

    def test_failed_restart_is_reported_and_keeps_cooldown(self):
        for status in ("0", "1"):
            with self.subTest(status=status):
                (self.base / "state").write_text("active\n")
                (self.base / "failures").write_text("1\n")
                result = self.run_watchdog(RESTART_STATE="failed", RESTART_STATUS=status,
                                          CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS="0")
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn("重启失败", result.stderr)
                self.assertTrue((self.base / "last-restart").exists())
                self.assertFalse((self.base / "recovered").exists())

    def test_unknown_or_unreadable_restart_state_is_not_success(self):
        for overrides in ({"RESTART_STATE": "activating"}, {"SHOW_FAIL": "1"}):
            with self.subTest(overrides=overrides):
                (self.base / "state").write_text("active\n")
                (self.base / "failures").write_text("1\n")
                result = self.run_watchdog(**overrides,
                                          CFWARP_WATCHDOG_RESTART_COOLDOWN_SECONDS="0")
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_already_stopped_service_stays_stopped(self):
        (self.base / "state").write_text("inactive\n")
        result = self.run_watchdog()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / "actions").exists())

    def test_failed_enabled_service_recovery_is_preserved(self):
        (self.base / "state").write_text("failed\n")
        result = self.run_watchdog()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "actions").read_text(), "start\n")

    def test_failed_disabled_service_is_not_started(self):
        (self.base / "state").write_text("failed\n")
        result = self.run_watchdog(DISABLE_SERVICE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.base / "actions").exists())

    def test_cooldown_blocks_active_and_failed_recovery(self):
        (self.base / "last-restart").write_text(str(int(time.time())))
        for state in ("active", "failed"):
            (self.base / "state").write_text(state + "\n")
            result = self.run_watchdog()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.base / "actions").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
