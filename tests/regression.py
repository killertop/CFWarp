#!/usr/bin/env python3
"""Unprivileged regressions for configuration, installation layout and CLI."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
COMMON = ROOT / "lib/cfwarp-common.sh"


class Regression(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="cfwarp-regression-")
        self.base = Path(self.work.name)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.startswith(("CFWARP_", "NETNS_", "WG_", "SOCKS_", "BIND_")):
                self.env.pop(key)
        self.env["CFWARP_ENV_FILE"] = str(self.base / "absent.env")

    def tearDown(self):
        self.work.cleanup()

    def shell(self, script, *args, env=None):
        return subprocess.run(
            ["sh", "-c", '. "$1"; shift; ' + script, "test", str(COMMON), *map(str, args)],
            env=env or self.env, text=True, capture_output=True, timeout=15,
        )

    def test_name_and_integer_boundaries(self):
        for name in (".", "..", "-other", "../outside", "space name"):
            self.assertNotEqual(self.shell('cfwarp_validate_netns_name "$1"', name).returncode, 0)
        for value in ("999999999999999999999999999", "65536", "0", "-1", "1x"):
            self.assertNotEqual(self.shell('cfwarp_validate_port "$1"', value).returncode, 0)
        self.assertEqual(self.shell('cfwarp_validate_port 65535').returncode, 0)
        self.assertEqual(self.shell('cfwarp_validate_uint 9223372036854775807 inode 1 9223372036854775807').returncode, 0)
        self.assertNotEqual(self.shell('cfwarp_validate_uint 9223372036854775808 inode 1 9223372036854775807').returncode, 0)

    def test_env_literal_roundtrip(self):
        config = self.base / "config.env"
        config.write_text("# retained\nVALUE=old\nVALUE=duplicate\n")
        # Ordinary punctuation must remain data through the writer and reader.
        value = "spaces 'single' \"double\" $dollar `ticks` \\slash # hash = equal"
        r = self.shell('cfwarp_set_env_key VALUE "$1" "$2" && cfwarp_read_env_key VALUE "$2"', value, config)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.rstrip("\n"), value)
        self.assertEqual(config.read_text().count("VALUE="), 1)

    def test_env_rejects_non_assignments(self):
        config = self.base / "config.env"
        for text in ("this is not an assignment\n", "X='unterminated\n", "BAD-NAME=x\n", "X=a b\n"):
            config.write_text(text)
            self.assertNotEqual(self.shell('cfwarp_parse_env "$1"', config).returncode, 0)

    def test_crlf_blank_lines(self):
        config = self.base / "config.env"
        config.write_bytes(b"A=first\r\n\r\n# comment\r\nB=second\r\n")
        r = self.shell('cfwarp_parse_env "$1"', config)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "A=first\nB=second\n")

    def test_inherited_empty_and_watchdog_overrides(self):
        config = self.base / "config.env"
        config.write_text("BIND_ADDR=default\nCFWARP_HEALTH_RETRIES=2\nSOCKS_USER='from file'\n")
        env = self.env | {"CFWARP_ENV_FILE": str(config), "BIND_ADDR": "", "CFWARP_HEALTH_RETRIES": "3"}
        r = self.shell('cfwarp_load_env "$1" && printf "%s|%s|%s|%s" "$BIND_ADDR" "$CFWARP_HEALTH_RETRIES" "$SOCKS_USER" "$CFWARP_ENV_LOADED"', ROOT, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "|3|from file|1")

    def test_marker_config_and_process_precedence(self):
        (self.base / "deploy").mkdir()
        config = self.base / "private.env"
        config.write_text("WG_QUICK_BIN='/configured/bin/wg-quick'\n")
        (self.base / "deploy/installation.env").write_text(
            f"CFWARP_ENV_FILE='{config}'\nWG_QUICK_BIN='/installed/bin/wg-quick'\n"
        )
        env = self.env.copy()
        env.pop("CFWARP_ENV_FILE")
        r = self.shell('cfwarp_load_env "$1" && printf "%s|%s" "$CFWARP_ENV_FILE" "$WG_QUICK_BIN"', self.base, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, f"{config}|/configured/bin/wg-quick")

    def test_upgrade_preserves_quoted_data_dir(self):
        text = (ROOT / "install.sh").read_text()
        functions = text[text.index("validate_path() {"):text.index("systemd_available() {")]
        functions += text[text.index("ensure_env_file() {"):text.index("install_file() {")]
        helper = self.base / "installer-functions.sh"
        helper.write_text(functions)
        data = self.base / "existing-data"
        config = self.base / "cfwarp.env"
        config.write_text(f"CFWARP_DATA_DIR='{data}'\n")
        r = self.shell('. "$1"; ENV_FILE=$2; ENV_DIR=$3; DATA_DIR=$3/fallback; DATA_DIR_SET=0; ensure_env_file; cfwarp_read_env_key CFWARP_DATA_DIR "$ENV_FILE"', helper, config, self.base)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), str(data))
        self.assertFalse((self.base / "fallback").exists())

    def test_endpoint_resolution_preserves_identity_and_rejects_bad_answers(self):
        for endpoint in ("192.0.2.40:2408", "[2001:db8::40]:2408"):
            r = self.shell('cfwarp_resolve_endpoint "$1"', endpoint)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), endpoint)
        for endpoint in ("999.0.2.40:2408", "192.00.2.40:2408", "123:2408", "host:0"):
            self.assertNotEqual(self.shell('cfwarp_resolve_endpoint "$1"', endpoint).returncode, 0)
        bins = self.base / "bin"
        bins.mkdir()
        (bins / "timeout").write_text('#!/bin/sh\n[ "$1" = --kill-after=1 ] && [ "$2" = 5 ] || exit 99\nshift 2\nexec "$@"\n')
        (bins / "getent").write_text('#!/bin/sh\n[ "$1" = ahostsv4 ] || exit 99\ncase "$2" in valid.invalid) printf "192.0.2.41 STREAM valid.invalid\\n";; bad.invalid) printf "999.0.2.41 STREAM bad.invalid\\n";; *) exit 2;; esac\n')
        for tool in bins.iterdir():
            tool.chmod(0o755)
        env = dict(self.env, PATH=f"{bins}:{self.env['PATH']}")
        r = self.shell('cfwarp_resolve_endpoint "$1"', "valid.invalid:2408", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "192.0.2.41:2408\n")
        for endpoint in ("bad.invalid:2408", "missing.invalid:2408"):
            self.assertNotEqual(self.shell('cfwarp_resolve_endpoint "$1"', endpoint, env=env).returncode, 0)

    def test_installed_doctor_uses_runtime_manifest(self):
        installed = self.base / "installed"
        installed.mkdir()
        (installed / "lib").mkdir()
        for source in list(ROOT.glob("cfwarp-*.sh")) + [ROOT / "entrypoint.sh", ROOT / "cfwarp-exec"]:
            shutil.copy2(source, installed / source.name)
        shutil.copy2(COMMON, installed / "lib/cfwarp-common.sh")
        env = self.env | {"CFWARP_SERVICE_NAME": "cfwarp-regression-absent.service"}
        r = subprocess.run(["sh", str(installed / "cfwarp-doctor.sh")], env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("install.sh", r.stderr)

    def test_scanner_errors_fail_closed(self):
        mock = self.base / "bin"
        mock.mkdir()
        (mock / "rg").write_text("#!/bin/sh\nexit 2\n")
        (mock / "rg").chmod(0o755)
        env = self.env | {"PATH": str(mock) + os.pathsep + self.env["PATH"]}
        r = subprocess.run(["sh", str(ROOT / "tests/smoke.sh")], env=env, text=True, capture_output=True, timeout=20)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("source scan failed", r.stderr)

    def test_cli_rejects_missing_log_count(self):
        r = subprocess.run(["sh", str(ROOT / "cmd/cfwarp"), "logs", "-n"], env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(r.returncode, 2)
        self.assertIn("requires a number", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
