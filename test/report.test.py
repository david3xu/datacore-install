#!/usr/bin/env python3
"""Exercise report preflight verdicts with an isolated CLI and no network calls."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
RUNTIME = shutil.which("bun") or shutil.which("node")
HEALTHY_DOCTOR = """✓ OK runtime:health
✓ OK bridge_dispatch:launcher:muse
summary: 2 ok, 0 fail, 0 skip (2 total)
"""


@unittest.skipUnless(RUNTIME, "Bun or Node is required to build the report")
class ReportPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="datacore-report-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / "install"
        self.bin = self.install / "bin"
        (self.bin / "lib").mkdir(parents=True)
        current = self.install / "current"
        current.mkdir()
        (current / ".env").write_text("DATACORE_HTTP_PORT=43123\n")
        shutil.copyfile(REPO / "lib/report.sh", self.bin / "lib/report.sh")
        self.fixture = self.root / "fixture"
        self.fixture.mkdir()
        (self.fixture / "doctor.txt").write_text(HEALTHY_DOCTOR)
        (self.fixture / "worker.txt").write_text(
            "    muse-worker@muse-spark-1.3  [implementation, rework]\n  1 enabled\n"
        )
        (self.fixture / "project.txt").write_text("  sample\n    /tmp/disposable-repo\n")
        (self.fixture / "provider.txt").write_text("No providers configured\n")
        self.executable(
            self.bin / "datacore",
            """#!/bin/sh
case "$1" in
  doctor) cat "$REPORT_FIXTURE/doctor.txt"; exit "${REPORT_DOCTOR_EXIT:-0}" ;;
  worker) cat "$REPORT_FIXTURE/worker.txt" ;;
  project) cat "$REPORT_FIXTURE/project.txt" ;;
  provider) cat "$REPORT_FIXTURE/provider.txt" ;;
  *) exit 2 ;;
esac
""",
        )
        self.executable(self.bin / "bun", f"#!/bin/sh\nexec {shlex.quote(RUNTIME)} \"$@\"\n")
        self.executable(self.bin / "curl", "#!/bin/sh\nprintf '%s\\n' '{\"status\":\"ok\"}'\n")
        self.output = self.root / "report.html"
        self.env = {
            **os.environ,
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "DATACORE_INSTALL_ROOT": str(self.install),
            "REPORT_FIXTURE": str(self.fixture),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
        }

    @staticmethod
    def executable(path: Path, content: str) -> None:
        path.write_text(content)
        path.chmod(0o700)

    def report(self, doctor: str = HEALTHY_DOCTOR, exit_code: int = 0) -> tuple[str, str]:
        (self.fixture / "doctor.txt").write_text(doctor)
        self.env["REPORT_DOCTOR_EXIT"] = str(exit_code)
        result = subprocess.run(
            ["sh", str(self.bin / "lib/report.sh"), "--no-open", "--output", str(self.output)],
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
            timeout=15,
        )
        return result.stdout, self.output.read_text()

    def test_ready_means_preflight_and_pairs_muse_launcher(self) -> None:
        stdout, html = self.report()
        self.assertIn("Verdict: ready — preflight only", stdout)
        self.assertIn("Model login and task completion: unverified.", html)
        self.assertIn("muse: ok</span>", html)
        self.assertNotIn("will be picked up", html)

    def test_crash_before_checks_is_unknown_even_if_other_inputs_pass(self) -> None:
        stdout, html = self.report("Runtime exception before checks\n", 37)
        self.assertNotIn("Verdict: ready", stdout)
        self.assertIn("doctor did not return a complete report", html)

    def test_crash_after_complete_report_is_not_ready(self) -> None:
        stdout, html = self.report(HEALTHY_DOCTOR, 37)
        self.assertNotIn("Verdict: ready", stdout)
        self.assertIn("doctor exited with status 37", html)

    def test_truncated_or_inconsistent_report_is_unknown(self) -> None:
        for doctor in [
            "",
            "✓ OK bridge_dispatch:launcher:muse\n",
            "✓ OK bridge_dispatch:launcher:muse\nsummary: 2 ok, 0 fail, 0 skip (2 total)\n",
            HEALTHY_DOCTOR + "summary: 2 ok, 0 fail, 0 skip (2 total)\n",
        ]:
            with self.subTest(doctor=doctor):
                stdout, html = self.report(doctor)
                self.assertNotIn("Verdict: ready", stdout)
                self.assertIn("doctor did not return a complete report", html)

    def test_failure_is_named_and_token_remains_redacted(self) -> None:
        token = "dc_abcdef0123456789abcdef"
        stdout, html = self.report(
            "✓ OK bridge_dispatch:launcher:muse\n"
            "✗ FAIL executor_config:file_present\n"
            f"    invalid token {token}\n"
            "summary: 1 ok, 1 fail, 0 skip (2 total)\n",
            1,
        )
        self.assertNotIn("Verdict: ready", stdout)
        self.assertIn("executor_config:file_present", html)
        self.assertNotIn(token, html)


if __name__ == "__main__":
    unittest.main()
