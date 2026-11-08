#!/usr/bin/env python3
"""Exercise installer and CI failure paths without Docker, network, or launchd."""

import hashlib
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

HEALTHY_NEW = "✓ OK   runtime:reachable\n· SKIP bridge_dispatch:launcher:muse\nsummary: 1 ok, 0 fail, 0 warn, 1 skip (2 total)\n"
WARNED_NEW = (
    "✓ OK   runtime:reachable\n"
    "! WARN bridge:bind\n"
    "· SKIP bridge_dispatch:launcher:muse\n"
    "summary: 1 ok, 0 fail, 1 warn, 1 skip (3 total)\n"
)
MISSING_CLI_NEW = (
    "✓ OK   runtime:reachable\n"
    "✗ FAIL bridge_dispatch:launcher:muse\n"
    "summary: 1 ok, 1 fail, 0 warn, 0 skip (2 total)\n"
)
BLOCKING_NEW = "✗ FAIL runtime:reachable\nsummary: 0 ok, 1 fail, 0 warn, 0 skip (1 total)\n"


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
            ("healthy new format with 0 warn", HEALTHY_NEW, 0, True),
            ("healthy new format with warn > 0", WARNED_NEW, 0, True),
            ("nonzero with warnings but no failures", WARNED_NEW, 1, False),
            ("missing optional CLI new format", MISSING_CLI_NEW, 1, True),
            ("missing optional CLI new format zero exit", MISSING_CLI_NEW, 0, False),
            ("blocking failure new format", BLOCKING_NEW, 1, False),
            ("blocking failure new format zero exit", BLOCKING_NEW, 0, False),
            ("warn count mismatch: check without summary count",
             "✓ OK   runtime:reachable\n! WARN bridge:bind\nsummary: 1 ok, 0 fail, 0 warn, 0 skip (1 total)\n", 0, False),
            ("warn count mismatch: summary count without check",
             "✓ OK   runtime:reachable\nsummary: 1 ok, 0 fail, 1 warn, 0 skip (2 total)\n", 0, False),
            ("warn count mismatch: count differs", WARNED_NEW.replace("1 warn", "2 warn"), 0, False),
            ("malformed summary missing parens",
             "✓ OK   runtime:reachable\nsummary: 1 ok, 0 fail, 0 warn, 0 skip 1 total\n", 0, False),
            ("malformed summary missing fields", "✓ OK   runtime:reachable\nsummary: 1 ok, 0 fail, 0 warn\n", 0, False),
            ("malformed summary non-numeric count",
             "✓ OK   runtime:reachable\nsummary: one ok, 0 fail, 0 warn, 0 skip (1 total)\n", 0, False),
            ("malformed summary wrong total",
             "✓ OK   runtime:reachable\nsummary: 1 ok, 0 fail, 0 warn, 0 skip (2 total)\n", 0, False),
            ("malformed summary trailing text",
             "✓ OK   runtime:reachable\nsummary: 1 ok, 0 fail, 0 warn, 0 skip (1 total) extra\n", 0, False),
        ]
        for name, report, status, expected in cases:
            with self.subTest(name=name):
                result = self.report_ok(report, status)
                self.assertEqual(result.returncode == 0, expected, result.stderr)
        self.assertNotEqual(self.report_ok(MISSING_CLI, 1, optional=False).returncode, 0)
        self.assertNotEqual(self.report_ok(MISSING_CLI_NEW, 1, optional=False).returncode, 0)

    def test_installer_gate_warns_on_nonblocking_doctor_warnings_and_continues(self):
        bundle = self.home / "bundle"
        bundle.mkdir()
        doctor = bundle / "doctor.sh"
        doctor.write_text(
            "#!/bin/sh\n"
            "cat << 'EOF'\n"
            "✓ OK   runtime:reachable\n"
            "! WARN bridge:bind\n"
            "! WARN executor_config:path_set\n"
            "· SKIP bridge_dispatch:launcher:muse\n"
            "summary: 1 ok, 0 fail, 2 warn, 1 skip (4 total)\n"
            "EOF\n"
            "exit 0\n"
        )
        doctor.chmod(0o755)
        result = shell(
            "ok() { printf 'SUCCESS %s\\n' \"$*\"; }\n"
            "warn() { printf 'WARN %s\\n' \"$*\"; }\n"
            "die() { printf '%s\\n' \"$*\" >&2; exit 1; }\n" +
            function("doctor_report_ok") + "\n" + function("gate_on_doctor") + "\n" +
            f"BUNDLE_DIR={shlex.quote(str(bundle))}\nBIN_DIR=$HOME/bin\ngate_on_doctor", self.home,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN doctor: bridge:bind, executor_config:path_set — run: datacore doctor", result.stdout)
        self.assertIn("SUCCESS doctor: no blocking failures", result.stdout)

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

    def test_lean_workers_passes_through_worker_change_warning(self):
        result = self.run_worker_install_step(
            "case \"$1\" in\n"
            "prune)\n"
            "  echo '  1 worker(s) enabled of 4 the bundle minted'\n"
            "  echo '  ! this update changed which workers are enabled:'\n"
            "  echo '      - codex-worker@default   (was enabled; now off: the CLI is not on PATH)'\n"
            "  echo '    keep a worker off for good: datacore worker remove <family>; turn one back on: datacore worker add <id>'\n"
            "  exit 0 ;;\n"
            "sync) echo 'worker configuration synced'; exit 0 ;;\nesac\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("this update changed which workers are enabled:", result.stdout)
        self.assertIn("- codex-worker@default", result.stdout)
        self.assertIn("SUMMARY 1 enabled", result.stdout)

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

    def run_upgrade_flow(self, env_content):
        bundle = self.home / "bundle"
        bundle.mkdir(parents=True, exist_ok=True)
        prev = self.home / "prev"
        prev.mkdir(parents=True, exist_ok=True)
        if env_content is not None:
            (bundle / ".env").write_text(env_content)
        return shell(
            "ok() { :; }; info() { :; }; warn() { :; }; die() { exit 1; }\n"
            "PROJECTS_MAPPED=0\nPROJECTS_SUMMARY='not configured'\n"
            "WORKERS_SUMMARY='left as generated'\nRUNTIME_URL='http://127.0.0.1:43123'\n"
            "REGISTERED='Claude Code'\nB=''; R=''\n" +
            function("prepare_env") + "\n" +
            function("summarise_projects") + "\n" +
            function("print_summary") + "\n" +
            f"BUNDLE_DIR={shlex.quote(str(bundle))}\nPREVIOUS_DIR={shlex.quote(str(prev))}\n"
            "prepare_env\nsummarise_projects\nprint_summary",
            self.home,
        )

    def test_upgrade_with_real_project_mapping_reports_mapped(self):
        result = self.run_upgrade_flow(
            'DATACORE_WORKER_PROJECT_WORKSPACES=\'{"my-project":"/home/user/repo"}\'\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Projects   mapped (see: datacore project list)", result.stdout)
        self.assertIn("Next:  restart Claude Code", result.stdout)

    def test_upgrade_with_unconfigured_standin_reports_none_mapped(self):
        result = self.run_upgrade_flow(
            'DATACORE_WORKER_PROJECT_WORKSPACES=\'{"_unconfigured":"/path/to/workspaces/_unconfigured"}\'\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Projects   none mapped — nothing can be dispatched yet", result.stdout)
        self.assertIn("Next:  datacore project link", result.stdout)

    def run_install_command_step(self, sums_dict, fetch_func, cli_files=None):
        sums_path = self.home / "SHA256SUMS"
        sums_lines = [f"{digest}  {name}\n" for name, digest in sums_dict.items()]
        sums_path.write_text("".join(sums_lines))
        cli_def = f'CLI_FILES="{cli_files}"\n' if cli_files is not None else ""
        return shell(
            "B=''; D=''; R=''\n"
            "say() { printf '%s\\n' \"$*\"; }\n"
            "ok() { printf 'OK %s\\n' \"$*\"; }\n"
            "info() { printf 'INFO %s\\n' \"$*\"; }\n"
            "warn() { printf 'WARN %s\\n' \"$*\"; }\n"
            "die() {\n"
            "  printf '\\nInstall stopped. %s\\n\\n' \"$1\" >&2\n"
            "  shift\n"
            "  while [ $# -gt 0 ]; do printf '%s\\n' \"$1\" >&2; shift; done\n"
            "  printf '\\n' >&2\n"
            "  exit 1\n"
            "}\n"
            + function("step") + "\n"
            + function("sha256_of") + "\n"
            + fetch_func + "\n"
            + function("install_command") + "\n"
            + "BIN_DIR=$HOME/bin\n"
            + "RELEASE_BASE=https://github.com/david3xu/datacore-install/releases\n"
            + "VERSION=v0.1.89\n"
            + "SELF_DIR=''\n"
            + f"SUMS_FILE={shlex.quote(str(sums_path))}\n"
            + cli_def
            + "lean_workers() { touch \"$HOME/lean-workers-called\"; printf 'LEAN_WORKERS\\n'; }\n"
            + "step 'Installing the command'; install_command\n"
            + "step 'Workers'; lean_workers\n",
            self.home,
        )

    def test_listed_helper_download_failure_stops_install_and_never_reaches_lean_workers(self):
        script_content = "#!/bin/sh\nexit 0\n"
        digest = hashlib.sha256(script_content.encode("utf-8")).hexdigest()
        sums = {"datacore": digest, "worker.sh": digest}
        fetch_stub = (
            "fetch() {\n"
            "  case \"$1\" in\n"
            "    */datacore)\n"
            "      mkdir -p \"$(dirname \"$2\")\"\n"
            "      printf '#!/bin/sh\\nexit 0\\n' > \"$2\" ;;\n"
            "    */worker.sh)\n"
            "      printf 'curl: (22) The requested URL returned error: 504 Gateway Timeout\\n' >&2\n"
            "      return 22 ;;\n"
            "  esac\n"
            "}\n"
        )
        result = self.run_install_command_step(sums, fetch_stub, cli_files="datacore lib/worker.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Installing the command", result.stdout)
        self.assertNotIn("Workers", result.stdout)
        self.assertNotIn("LEAN_WORKERS", result.stdout)
        self.assertFalse((self.home / "lean-workers-called").exists())
        self.assertIn(
            "Could not download worker.sh from https://github.com/david3xu/datacore-install/releases/download/v0.1.89/worker.sh.",
            result.stderr,
        )
        self.assertIn(
            "This release carries it, so the download failed: check your network or try again in a few minutes.",
            result.stderr,
        )
        self.assertIn("curl: (22) The requested URL returned error: 504 Gateway Timeout", result.stderr)
        self.assertIn("Install stopped.", result.stderr)

    def test_listed_helper_bad_checksum_dies(self):
        script_content = "#!/bin/sh\nexit 0\n"
        digest = hashlib.sha256(script_content.encode("utf-8")).hexdigest()
        sums = {
            "datacore": digest,
            "worker.sh": "0000000000000000000000000000000000000000000000000000000000000000",
        }
        fetch_stub = (
            "fetch() {\n"
            "  mkdir -p \"$(dirname \"$2\")\"\n"
            "  printf '#!/bin/sh\\nexit 0\\n' > \"$2\"\n"
            "}\n"
        )
        result = self.run_install_command_step(sums, fetch_stub, cli_files="datacore lib/worker.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum mismatch on worker.sh — refusing to install.", result.stderr)
        self.assertIn("Install stopped.", result.stderr)
        self.assertFalse((self.home / "bin/lib/worker.sh").exists())
        self.assertFalse((self.home / "lean-workers-called").exists())

    def test_helper_absent_from_sums_skipped_with_warn_and_install_continues(self):
        script_content = "#!/bin/sh\nexit 0\n"
        digest = hashlib.sha256(script_content.encode("utf-8")).hexdigest()
        sums = {"datacore": digest, "worker.sh": digest}
        fetch_stub = (
            "fetch() {\n"
            "  case \"$1\" in\n"
            "    */project.sh)\n"
            "      touch \"$HOME/project-fetched\"\n"
            "      return 1 ;;\n"
            "    *)\n"
            "      mkdir -p \"$(dirname \"$2\")\"\n"
            "      printf '#!/bin/sh\\nexit 0\\n' > \"$2\" ;;\n"
            "  esac\n"
            "}\n"
        )
        result = self.run_install_command_step(sums, fetch_stub, cli_files="datacore lib/worker.sh lib/project.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "project-fetched").exists())
        self.assertFalse((self.home / "bin/lib/project.sh").exists())
        self.assertIn("WARN not installed: project.sh — the matching 'datacore' subcommand will say it is unavailable", result.stdout)
        self.assertIn("LEAN_WORKERS", result.stdout)
        self.assertTrue((self.home / "lean-workers-called").exists())

    def test_worker_helper_absent_from_sums_dies_with_installer_needs_message(self):
        script_content = "#!/bin/sh\nexit 0\n"
        digest = hashlib.sha256(script_content.encode("utf-8")).hexdigest()
        sums = {"datacore": digest}
        fetch_stub = (
            "fetch() {\n"
            "  mkdir -p \"$(dirname \"$2\")\"\n"
            "  printf '#!/bin/sh\\nexit 0\\n' > \"$2\"\n"
            "}\n"
        )
        result = self.run_install_command_step(sums, fetch_stub, cli_files="datacore lib/worker.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("this release does not include worker.sh, which the installer needs", result.stderr)
        self.assertIn("installer needs", result.stderr)
        self.assertIn("Install stopped.", result.stderr)
        self.assertFalse((self.home / "lean-workers-called").exists())

    def test_install_desktop_entry_absent_from_sums_dies_with_installer_needs_message(self):
        script_content = "#!/bin/sh\nexit 0\n"
        digest = hashlib.sha256(script_content.encode("utf-8")).hexdigest()
        sums = {"datacore": digest}
        fetch_stub = (
            "fetch() {\n"
            "  mkdir -p \"$(dirname \"$2\")\"\n"
            "  printf '#!/bin/sh\\nexit 0\\n' > \"$2\"\n"
            "}\n"
        )
        result = self.run_install_command_step(sums, fetch_stub, cli_files="datacore lib/install-desktop-entry.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("this release does not include install-desktop-entry.py, which the installer needs", result.stderr)
        self.assertIn("installer needs", result.stderr)
        self.assertIn("Install stopped.", result.stderr)
        self.assertFalse((self.home / "lean-workers-called").exists())

    def test_retry_flags_appear_in_fetch_guarded_by_support_check(self):
        fetch_code = function("fetch")
        self.assertIn("--retry 5", fetch_code)
        self.assertIn("--retry-delay 3", fetch_code)
        self.assertIn("--retry-all-errors", fetch_code)
        self.assertIn("curl --help all", fetch_code)

        # 1. Curl supports --retry-all-errors: check flags passed and support detected only once.
        curl_bin = self.home / "curl"
        curl_bin.write_text(
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  *\"--help all\"*)\n"
            "    echo 'check' >> \"$HOME/curl-help.log\"\n"
            "    echo '  --retry-all-errors Retry all errors'\n"
            "    exit 0 ;;\n"
            "esac\n"
            "printf '%s\\n' \"$*\" >> \"$HOME/curl-fetch.log\"\n"
            "while [ $# -gt 0 ]; do\n"
            "  if [ \"$1\" = '-o' ]; then touch \"$2\"; shift 2; else shift; fi\n"
            "done\n"
            "exit 0\n"
        )
        curl_bin.chmod(0o755)
        res = shell(
            f"PATH={shlex.quote(str(self.home))}:$PATH\n"
            + "CURL_RETRY_CHECKED=''\nCURL_RETRY_FLAGS=''\n"
            + function("fetch") + "\n"
            + f"fetch http://example.com/one {shlex.quote(str(self.home / 'out1'))}\n"
            + f"fetch http://example.com/two {shlex.quote(str(self.home / 'out2'))}\n",
            self.home,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        help_log = (self.home / "curl-help.log").read_text().splitlines()
        self.assertEqual(len(help_log), 1, "support check must run only once across multiple fetches")
        fetch_log = (self.home / "curl-fetch.log").read_text().splitlines()
        self.assertEqual(len(fetch_log), 2)
        for line in fetch_log:
            self.assertIn("--retry 5", line)
            self.assertIn("--retry-delay 3", line)
            self.assertIn("--retry-all-errors", line)

        # 2. Curl does not support --retry-all-errors.
        curl_bin.write_text(
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  *\"--help all\"*)\n"
            "    echo 'standard curl help without retry all errors'\n"
            "    exit 0 ;;\n"
            "esac\n"
            "printf '%s\\n' \"$*\" >> \"$HOME/curl-fetch-noall.log\"\n"
            "while [ $# -gt 0 ]; do\n"
            "  if [ \"$1\" = '-o' ]; then touch \"$2\"; shift 2; else shift; fi\n"
            "done\n"
            "exit 0\n"
        )
        curl_bin.chmod(0o755)
        res_noall = shell(
            f"PATH={shlex.quote(str(self.home))}:$PATH\n"
            + "CURL_RETRY_CHECKED=''\nCURL_RETRY_FLAGS=''\n"
            + function("fetch") + "\n"
            + f"fetch http://example.com/three {shlex.quote(str(self.home / 'out3'))}\n",
            self.home,
        )
        self.assertEqual(res_noall.returncode, 0, res_noall.stderr)
        fetch_log_noall = (self.home / "curl-fetch-noall.log").read_text().splitlines()
        self.assertEqual(len(fetch_log_noall), 1)
        self.assertIn("--retry 5", fetch_log_noall[0])
        self.assertIn("--retry-delay 3", fetch_log_noall[0])
        self.assertNotIn("--retry-all-errors", fetch_log_noall[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
