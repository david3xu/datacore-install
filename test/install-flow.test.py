#!/usr/bin/env python3
"""Exercise installer and CI failure paths without Docker, network, or launchd."""

import os
from pathlib import Path
import pty
import re
import shlex
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALL = (REPO / "install.sh").read_text()
WORKFLOW = (REPO / ".github/workflows/install.yml").read_text()


def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{.*?^\}", INSTALL, re.M | re.S)
    if not match:
        raise AssertionError(f"installer function not found: {name}")
    return match.group(0)


def shell(code, home):
    env = {k: v for k, v in os.environ.items() if not k.startswith("DATACORE_")}
    env.update(HOME=str(home), TMPDIR=str(home))
    return subprocess.run(
        ["sh", "-c", "set -eu\n" + code], cwd=REPO, env=env,
        text=True, input="", capture_output=True,
    )


HEALTHY = "✓ OK   runtime:reachable\n· SKIP bridge_dispatch:launcher:muse\nsummary: 1 ok, 0 fail, 1 skip (2 total)\n"
MISSING_CLI = "✓ OK   runtime:reachable\n✗ FAIL bridge_dispatch:launcher:muse\nsummary: 1 ok, 1 fail, 0 skip (2 total)\n"
BLOCKING = "✗ FAIL runtime:reachable\nsummary: 0 ok, 1 fail, 0 skip (1 total)\n"


class InstallFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="datacore-install-flow-")
        self.home = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def report_ok(self, report, status=0, optional=True):
        log = self.home / "doctor.log"
        log.write_text(report)
        return shell(
            function("doctor_report_ok") + "\n" +
            f"doctor_report_ok {shlex.quote(str(log))} {status} {int(optional)}", self.home,
        )

    def test_complete_report_and_expected_exit_are_required(self):
        cases = [
            ("healthy", HEALTHY, 0, True),
            ("executable path check", HEALTHY.replace("runtime:reachable", "executor_command:/bin/sh"), 0, True),
            ("missing optional CLI", MISSING_CLI, 1, True),
            ("blocking failure", BLOCKING, 1, False),
            ("crash", "Runtime exception before checks\n", 37, False),
            ("empty", "", 0, False),
            ("truncated", "✓ OK   runtime:reachable\n", 0, False),
            ("no checks", "summary: 0 ok, 0 fail, 0 skip (0 total)\n", 0, False),
            ("wrong counts", HEALTHY.replace("1 ok", "2 ok"), 0, False),
            ("wrong total", HEALTHY.replace("2 total", "3 total"), 0, False),
            ("duplicate summary", HEALTHY + HEALTHY.splitlines()[-1] + "\n", 0, False),
            ("exception after summary", HEALTHY + "doctor crashed\n", 1, False),
            ("crash after complete report", HEALTHY, 37, False),
            ("nonzero without failures", HEALTHY, 1, False),
            ("zero despite failures", MISSING_CLI, 0, False),
        ]
        for name, report, status, expected in cases:
            with self.subTest(name=name):
                result = self.report_ok(report, status)
                self.assertEqual(result.returncode == 0, expected, result.stderr)
        self.assertNotEqual(self.report_ok(MISSING_CLI, 1, optional=False).returncode, 0)

    def test_installer_gate_rejects_crash_and_keeps_diagnostic_log(self):
        bundle = self.home / "bundle"
        bundle.mkdir()
        doctor = bundle / "doctor.sh"
        doctor.write_text("#!/bin/sh\necho 'Runtime exception before checks'\nexit 37\n")
        doctor.chmod(0o755)
        result = shell(
            "ok() { printf 'SUCCESS %s\\n' \"$*\"; }\n"
            "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n" +
            function("doctor_report_ok") + "\n" + function("gate_on_doctor") + "\n" +
            f"BUNDLE_DIR={shlex.quote(str(bundle))}\nBIN_DIR=$HOME/bin\ngate_on_doctor", self.home,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SUCCESS", result.stdout)
        self.assertIn("doctor exit 37", result.stderr)
        logs = list(self.home.glob("datacore-doctor.*.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn("Runtime exception before checks", logs[0].read_text())

    def test_mac_detection_reaches_login_helper_without_real_launchctl(self):
        bundle = self.home / "bundle"
        bundle.mkdir()
        helper = bundle / "install-macos-login-agent.sh"
        helper.write_text("#!/bin/sh\nprintf called > \"$HOME/login-called\"\n")
        helper.chmod(0o755)
        result = shell(
            "ok() { :; }; info() { :; }; warn() { :; }; die() { exit 1; }\n"
            "uname() { case \"$1\" in -s) echo Darwin ;; -m) echo arm64 ;; esac; }\n"
            "launchctl() { return 0; }\n" + function("detect_platform") + "\n" +
            function("install_login_agent") + "\n" +
            f"BUNDLE_DIR={shlex.quote(str(bundle))}\nBIN_DIR=$HOME/bin\n"
            "detect_platform\ninstall_login_agent", self.home,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / "login-called").exists())

    def test_piped_licence_prompt_fails_without_recording_acceptance(self):
        bundle = self.home / "bundle"
        bundle.mkdir()
        (bundle / "EULA.md").write_text("Synthetic rejection-only test terms.\n")
        result = shell(
            "ok() { :; }; say() { printf '%s\\n' \"$*\"; }\n"
            "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n" +
            function("record_eula_acceptance") + "\n" + function("accept_eula") + "\n" +
            f"BUNDLE_DIR={shlex.quote(str(bundle))}\nINSTALL_ROOT=$HOME/install\naccept_eula", self.home,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot prompt", result.stderr)
        self.assertFalse((self.home / "install/.eula-accepted").exists())

    def test_downloaded_script_can_prompt_and_honours_rejection(self):
        bundle = self.home / "bundle"
        bundle.mkdir()
        (bundle / "EULA.md").write_text("Synthetic rejection-only test terms.\n")
        code = (
            "set -eu\nok() { :; }; say() { printf '%s\\n' \"$*\"; }\n"
            "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n" +
            function("record_eula_acceptance") + "\n" + function("accept_eula") + "\n" +
            f"BUNDLE_DIR={shlex.quote(str(bundle))}\nINSTALL_ROOT=$HOME/install\naccept_eula"
        )
        script = self.home / "installer-fixture.sh"
        script.write_text(code)
        env = {k: v for k, v in os.environ.items() if not k.startswith("DATACORE_")}
        env.update(HOME=str(self.home), TMPDIR=str(self.home))
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                ["sh", str(script)], stdin=slave, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, env=env,
            )
            os.write(master, b"n\n")
            stdout, stderr = process.communicate(timeout=5)
        finally:
            os.close(master)
            os.close(slave)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Accept these terms?", stdout)
        self.assertIn("Licence not accepted", stderr)
        self.assertNotIn("Cannot prompt", stderr)
        self.assertFalse((self.home / "install/.eula-accepted").exists())

    def test_ci_checks_every_captured_doctor_report_with_production_rule(self):
        capture = re.compile(
            r"          doctor_status=0\n"
            r"          ~/.datacore/bin/datacore doctor > (\S+) 2>&1 \|\| doctor_status=\$\?\n"
            r"          eval .*\n"
            r"          doctor_report_ok .*\n"
        )
        blocks = list(capture.finditer(WORKFLOW))
        self.assertEqual(len(blocks), 8, "every captured doctor call must validate its output")
        fake = self.home / ".datacore/bin/datacore"
        fake.parent.mkdir(parents=True)
        fake.write_text("#!/bin/sh\necho 'Runtime exception before checks'\nexit 37\n")
        fake.chmod(0o755)
        for block in blocks:
            with self.subTest(log=block.group(1)):
                code = "\n".join(line[10:] for line in block.group(0).splitlines())
                code = code.replace(block.group(1), shlex.quote(str(self.home / block.group(1))))
                result = shell(code, self.home)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("complete, healthy report", result.stdout)

    def test_documented_worker_failure_is_not_repaired_before_assertion(self):
        start = WORKFLOW.index("      - name: Install a CLI, then `worker add`")
        end = WORKFLOW.index("      - name:", start + 10)
        step = WORKFLOW[start:end]
        command = "          ~/.datacore/bin/datacore worker add claude"
        command_start = step.index(command)
        assertion_end = step.index("          ~/.datacore/bin/datacore worker list", command_start)
        code = "\n".join(line[10:] for line in step[command_start:assertion_end].splitlines())
        fake = self.home / ".datacore/bin/datacore"
        fake.parent.mkdir(parents=True)
        fake.write_text(
            "#!/bin/sh\ncase \"$*\" in\n"
            "'worker add claude') echo 'runtime connection failure' >&2; exit 55 ;;\n"
            "'worker add claude-worker') touch \"$HOME/repaired\"; exit 0 ;;\nesac\nexit 99\n"
        )
        fake.chmod(0o755)
        result = shell(code, self.home)
        self.assertEqual(result.returncode, 55)
        self.assertFalse((self.home / "repaired").exists())

    def run_worker_install_step(self, helper_code):
        helper = self.home / "bin/lib/worker.sh"
        helper.parent.mkdir(parents=True)
        if helper_code is not None:
            helper.write_text("#!/bin/sh\n" + helper_code)
        return shell(
            "info() { printf '%s\\n' \"$*\"; }\n"
            "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n" +
            function("lean_workers") + "\n" +
            "BIN_DIR=$HOME/bin\nINSTALL_ROOT=$HOME/install\nDATA_HOME=$HOME/data\n"
            "PATH=$HOME/bin:$PATH\nexport PATH\n"
            "lean_workers\nprintf 'SUMMARY %s\\n' \"$WORKERS_SUMMARY\"", self.home,
        )

    def test_worker_choice_failure_stops_install_and_preserves_diagnostic(self):
        result = self.run_worker_install_step(
            "case \"$1\" in\n"
            "prune) echo 'Worker state is invalid; preserve and repair worker-state.json' >&2; exit 7 ;;\n"
            "sync) touch \"$HOME/sync-called\"; exit 0 ;;\nesac\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not apply your worker choices", result.stderr)
        self.assertIn("Worker state is invalid", result.stderr)
        self.assertNotIn("SUMMARY", result.stdout)
        self.assertFalse((self.home / "sync-called").exists())

    def test_worker_sync_failure_stops_install_and_preserves_diagnostic(self):
        result = self.run_worker_install_step(
            "case \"$1\" in\n"
            "prune) echo '  2 worker(s) enabled of 4 the bundle minted'; exit 0 ;;\n"
            "sync) echo 'cannot write executor profiles' >&2; exit 1 ;;\nesac\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not sync the worker configuration", result.stderr)
        self.assertIn("cannot write executor profiles", result.stderr)
        self.assertNotIn("SUMMARY", result.stdout)

    def test_successful_worker_configuration_reports_enabled_count(self):
        result = self.run_worker_install_step(
            "case \"$1\" in\n"
            "prune) echo '  2 worker(s) enabled of 4 the bundle minted'; exit 0 ;;\n"
            "sync) echo 'worker configuration synced'; exit 0 ;;\nesac\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("worker configuration synced", result.stdout)
        self.assertIn("SUMMARY 2 enabled", result.stdout)

    def test_missing_worker_helper_stops_install(self):
        result = self.run_worker_install_step(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("worker helper is missing", result.stderr)
        self.assertNotIn("SUMMARY", result.stdout)

    def test_disabled_workers_do_not_claim_the_installed_cli_is_missing(self):
        binary = self.home / "bin/codex"
        binary.parent.mkdir()
        binary.write_text("#!/bin/sh\nexit 0\n")
        binary.chmod(0o755)
        result = self.run_worker_install_step(
            "case \"$1\" in\n"
            "prune) echo '  0 worker(s) enabled of 4 the bundle minted'; exit 0 ;;\n"
            "sync) exit 0 ;;\nesac\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SUMMARY none enabled", result.stdout)
        self.assertIn("datacore worker add", result.stdout)
        self.assertNotIn("no worker CLI installed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
