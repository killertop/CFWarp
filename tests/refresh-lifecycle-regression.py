#!/usr/bin/env python3
"""Real flock/process coordination; --live also exercises disposable systemd units.

Network and probe workers are fixtures. No WARP account or kernel route is used.
"""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
LIVE = "--live" in sys.argv
sys.argv = [arg for arg in sys.argv if arg != "--live"]
SUPPORTED = sys.platform.startswith("linux") and all(shutil.which(x) for x in ("flock", "setsid", "timeout"))


@unittest.skipUnless(SUPPORTED, "requires Linux flock, setsid and timeout")
class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cfwarp-lifecycle-")
        self.base = Path(self.temp.name)
        self.project = self.base / "project"
        self.bin = self.base / "bin"
        self.data = self.base / "data"
        for path in (self.project / "lib", self.bin, self.data):
            path.mkdir(parents=True)
        for script in ("cfwarp-start.sh", "cfwarp-stop.sh", "cfwarp-refresh-endpoint.sh", "lib/cfwarp-common.sh"):
            shutil.copy2(ROOT / script, self.project / script)
        self.env_file = self.base / "cfwarp.env"
        self.env_file.write_text(f'CFWARP_DATA_DIR="{self.data}"\nENDPOINT_IP=192.0.2.10:2408\n')
        (self.data / "wg0.conf").write_text("[Peer]\nEndpoint = 192.0.2.10:2408\n")
        self.env = {**os.environ, "CASE_ROOT": str(self.base), "CFWARP_ENV_FILE": str(self.env_file),
                    "CFWARP_ENDPOINT_REFRESH_STATE_ROOT": str(self.base / "run"),
                    "CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE": "stop-and-probe",
                    "ENDPOINT_CANDIDATES": "192.0.2.20:2408", "PATH": f"{self.bin}:{os.environ['PATH']}"}
        for key in ("CFWARP_ENV_LOADED", "CFWARP_DATA_DIR", "WG_CONF", "ENDPOINT_IP", "CFWARP_MODE"):
            self.env.pop(key, None)
        self.processes = []
        self.unit = None
        self.write(self.project / "entrypoint.sh", r'''#!/bin/sh
set -eu
if [ "${CFWARP_PREPARE_ONLY:-0}" = 1 ]; then exit 0; fi
if [ "${CFWARP_PROBE_MODE:-0}" = 1 ]; then
    touch "$CASE_ROOT/probe-active"
    trap 'rm -f "$CASE_ROOT/probe-active"' EXIT
    trap 'exit 143' TERM
    while [ -e "$CASE_ROOT/hold-probe" ]; do sleep 0.1; done
    score=10
    [ "$ENDPOINT_IP" != 192.0.2.20:2408 ] || score=1
    printf 'SELECTED_ENDPOINT=%s\nRUNTIME_ENDPOINT=%s\nSCORE=%s\n' "$ENDPOINT_IP" "$ENDPOINT_IP" "$score" > "$CFWARP_PROBE_METRICS_FILE"
else
    printf '%s\n' "${ENDPOINT_IP:-}" > "$CASE_ROOT/main-active"
    trap 'rm -f "$CASE_ROOT/main-active"' EXIT
    trap 'exit 143' TERM
    while :; do sleep 0.1; done
fi
''')
        self.write(self.project / "cfwarp-netns.sh", r'''#!/bin/sh
set -eu
kind=main
case "${NETNS_NAME:-}" in cfpr*) kind=probe ;; esac
printf '%s-%s\n' "$kind" "$1" >> "$CASE_ROOT/network-events"
case "$1" in
    up)
        touch "$CASE_ROOT/$kind-kernel"
        if [ "$kind" = probe ]; then rm -f "$CASE_ROOT/hold-post"; fi
        ;;
    down)
        if [ "$kind" = main ] && [ -e "$CASE_ROOT/fail-main-cleanup" ]; then exit 1; fi
        if [ "$kind" = probe ] && [ -e "$CASE_ROOT/fail-cleanup" ]; then exit 1; fi
        rm -f "$CASE_ROOT/$kind-kernel"
        ;;
esac
''')
        self.write(self.project / "cfwarp-healthcheck.sh", "#!/bin/sh\nexit 0\n")
        self.write(self.bin / "ip", '#!/bin/sh\nshift 3\nexec "$@"\n')
        self.write(self.bin / "systemctl", '#!/bin/sh\ncase "$1" in show) echo inactive ;; *) exit 1 ;; esac\n')
        # Deliberately report inactive even if a manually launched main is live:
        # only the real shared lock can close this check/start race.
        refresh = self.project / "cfwarp-refresh-endpoint.sh"
        refresh.write_text(refresh.read_text().replace("[ -d /run/systemd/system ]", "true"))

    def write(self, path, content):
        path.write_text(content)
        path.chmod(0o700)

    def run_script(self, name, **extra):
        return subprocess.run(["sh", str(self.project / name)], env={**self.env, **extra},
                              capture_output=True, text=True, timeout=30)

    def launch(self, name):
        log = open(self.base / f"process-{len(self.processes)}.log", "w")
        process = subprocess.Popen(["sh", str(self.project / name)], env=self.env,
                                   stdout=log, stderr=log, start_new_session=True)
        log.close()
        self.processes.append(process)
        return process

    def wait_for(self, predicate):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("timed out waiting for fixture state")

    def stop(self, process):
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=15)

    def tearDown(self):
        for process in reversed(self.processes):
            self.stop(process)
        if self.unit:
            subprocess.run(["systemctl", "stop", self.unit], capture_output=True)
            subprocess.run(["systemctl", "disable", self.unit], capture_output=True)
            (Path("/etc/systemd/system") / self.unit).unlink(missing_ok=True)
            subprocess.run(["systemctl", "daemon-reload"], check=True)
            subprocess.run(["systemctl", "reset-failed", self.unit], capture_output=True)
        self.temp.cleanup()

    def test_live_main_wins_even_when_service_state_says_inactive(self):
        main = self.launch("cfwarp-start.sh")
        self.wait_for(lambda: (self.base / "main-active").exists())
        result = self.run_script("cfwarp-refresh-endpoint.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.base / "probe-kernel").exists())
        self.assertNotEqual(self.run_script("cfwarp-stop.sh").returncode, 0)
        self.assertTrue((self.base / "main-kernel").exists())
        self.stop(main)

    def test_probe_wins_and_next_start_reads_committed_config(self):
        (self.base / "hold-probe").touch()
        refresh = self.launch("cfwarp-refresh-endpoint.sh")
        self.wait_for(lambda: (self.base / "probe-active").exists())
        self.assertNotEqual(self.run_script("cfwarp-start.sh").returncode, 0)
        self.assertNotEqual(self.run_script("cfwarp-stop.sh").returncode, 0)
        self.assertTrue((self.base / "probe-kernel").exists())
        (self.base / "hold-probe").unlink()
        self.assertEqual(refresh.wait(timeout=15), 0)
        self.assertFalse((self.data / ".refresh-pending").exists())
        main = self.launch("cfwarp-start.sh")
        self.wait_for(lambda: (self.base / "main-active").exists())
        self.assertEqual((self.base / "main-active").read_text().strip(), "192.0.2.20:2408")
        self.stop(main)

    def test_failed_cleanup_blocks_later_processes_until_manual_recovery(self):
        (self.base / "fail-cleanup").touch()
        result = self.run_script("cfwarp-refresh-endpoint.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.base / "probe-kernel").exists())
        self.assertTrue((self.data / ".refresh-pending").exists())
        self.assertNotEqual(self.run_script("cfwarp-start.sh").returncode, 0)
        events = (self.base / "network-events").read_text()
        self.assertNotEqual(self.run_script("cfwarp-refresh-endpoint.sh").returncode, 0)
        self.assertEqual((self.base / "network-events").read_text(), events)
        (self.base / "probe-kernel").unlink()
        (self.base / "fail-cleanup").unlink()
        (self.data / ".refresh-pending").unlink()
        main = self.launch("cfwarp-start.sh")
        self.wait_for(lambda: (self.base / "main-active").exists())
        self.stop(main)

    def test_cancelled_probe_is_cleaned_before_unlock(self):
        (self.base / "hold-probe").touch()
        refresh = self.launch("cfwarp-refresh-endpoint.sh")
        self.wait_for(lambda: (self.base / "probe-active").exists())
        self.stop(refresh)
        self.assertFalse((self.base / "probe-kernel").exists())
        self.assertFalse((self.data / ".refresh-pending").exists())
        main = self.launch("cfwarp-start.sh")
        self.wait_for(lambda: (self.base / "main-active").exists())
        self.stop(main)

    def test_failed_main_cleanup_blocks_probe_identity_reuse(self):
        (self.base / "main-kernel").touch()
        (self.base / "fail-main-cleanup").touch()
        result = self.run_script("cfwarp-refresh-endpoint.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "probe-kernel").exists())
        self.assertTrue((self.base / "main-kernel").exists())
        self.assertTrue((self.data / ".refresh-pending").exists())

    @unittest.skipUnless(LIVE, "--live enables real systemd transitions")
    def test_systemd_activating_stop_restore_and_failed_cleanup(self):
        self.assertEqual(os.geteuid(), 0, "--live needs root in a disposable VM")
        (self.bin / "systemctl").unlink()
        self.unit = f"cfwarp-lifecycle-{os.getpid()}.service"
        self.env["CFWARP_SERVICE_NAME"] = self.unit
        self.write(self.base / "post.sh", '#!/bin/sh\nwhile [ -e "$CASE_ROOT/hold-post" ] || [ ! -e "$CASE_ROOT/main-active" ]; do sleep 0.1; done\n')
        unit_path = self.base / self.unit
        unit_path.write_text(f'''[Unit]
StartLimitIntervalSec=0
[Service]
Type=simple
Environment=CFWARP_ENV_FILE={self.env_file}
Environment=CASE_ROOT={self.base}
Environment=PATH={self.env['PATH']}
ExecStart=/bin/sh {self.project}/cfwarp-start.sh
ExecStartPost=/bin/sh {self.base}/post.sh
ExecStopPost=/bin/sh {self.project}/cfwarp-stop.sh
TimeoutStartSec=30
TimeoutStopSec=20
SuccessExitStatus=143
''')
        subprocess.run(["systemctl", "link", str(unit_path)], check=True, capture_output=True)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        def state():
            return subprocess.check_output(["systemctl", "show", "-p", "ActiveState", "--value", self.unit], text=True).strip()
        (self.base / "hold-post").touch()
        subprocess.run(["systemctl", "start", "--no-block", self.unit], check=True)
        self.wait_for(lambda: state() == "activating" and (self.base / "main-active").exists())
        result = self.run_script("cfwarp-refresh-endpoint.sh", CFWARP_ENDPOINT_REFRESH_ACTIVE_MODE="skip")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state(), "activating")
        self.assertFalse((self.base / "probe-kernel").exists())
        result = self.run_script("cfwarp-refresh-endpoint.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state(), "active")
        (self.base / "fail-cleanup").touch()
        result = self.run_script("cfwarp-refresh-endpoint.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state(), "inactive")
        self.assertTrue((self.base / "probe-kernel").exists())
        self.assertTrue((self.data / ".refresh-pending").exists())
        result = subprocess.run(["systemctl", "start", self.unit], capture_output=True)
        self.wait_for(lambda: state() == "failed")
        self.assertFalse((self.base / "main-active").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
