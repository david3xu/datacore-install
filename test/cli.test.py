#!/usr/bin/env python3
"""Exercise datacore CLI dispatch guards without starting Docker or services."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
DATACORE = REPO / "datacore"


class CliGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="datacore-cli-test-")
        self.home = Path(self.tmp.name)
        self.install_root = self.home / ".datacore"
        self.current = self.install_root / "current"
        self.current.mkdir(parents=True)

        self.backup_marker = self.home / "backup-invoked"
        self.restore_marker = self.home / "restore-invoked"

        fake_backup = self.current / "backup-datacore-local.sh"
        fake_backup.write_text(f"#!/bin/sh\ntouch {self.backup_marker}\n")
        fake_backup.chmod(0o755)

        fake_restore = self.current / "restore-datacore-local.sh"
        fake_restore.write_text(f"#!/bin/sh\ntouch {self.restore_marker}\n")
        fake_restore.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        env = {
            **os.environ,
            "HOME": str(self.home),
            "TMPDIR": str(self.home),
            "DATACORE_INSTALL_ROOT": str(self.install_root),
        }
        return subprocess.run(
            ["sh", str(DATACORE), *args],
            cwd=self.home,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_backup_help_prints_usage_and_does_not_run_bundle_script(self):
        for flag in ["--help", "-h"]:
            with self.subTest(flag=flag):
                result = self.run_cli("backup", flag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Usage: datacore backup [archive-path]", result.stdout)
                self.assertIn("Stops the Datacore services", result.stdout)
                self.assertIn("bundles before\n0.1.88 leave the services stopped", result.stdout)
                self.assertFalse(self.backup_marker.exists())

    def test_restore_help_prints_usage_and_does_not_run_bundle_script(self):
        for flag in ["--help", "-h"]:
            with self.subTest(flag=flag):
                result = self.run_cli("restore", flag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Usage: datacore restore <archive-path>", result.stdout)
                self.assertFalse(self.restore_marker.exists())

    def test_backup_without_help_dispatches_to_bundle_script(self):
        result = self.run_cli("backup", str(self.home / "archive.tar.gz"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.backup_marker.exists())

    def test_restore_without_help_dispatches_to_bundle_script(self):
        result = self.run_cli("restore", str(self.home / "archive.tar.gz"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.restore_marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
