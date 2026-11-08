#!/usr/bin/env python3
"""Exercise make-release.sh lockstep version guard."""

import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


def build_fake_archive(dest_path: Path, bundle_ver: str, has_manifest: bool = True, manifest_dict: dict = None):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        dir_name = f"datacore-local-edition-{bundle_ver}"
        ti_dir = tarfile.TarInfo(f"{dir_name}/")
        ti_dir.type = tarfile.DIRTYPE
        tf.addfile(ti_dir)

        if has_manifest:
            manifest_data = manifest_dict if manifest_dict is not None else {
                "product": "Datacore Local Edition",
                "version": bundle_ver,
            }
            content = json.dumps(manifest_data, indent=2).encode("utf-8") + b"\n"
            ti_file = tarfile.TarInfo(f"{dir_name}/manifest.json")
            ti_file.size = len(content)
            tf.addfile(ti_file, io.BytesIO(content))

    dest_path.parent.mkdir(parents=True, exist_ok=True)
    dest_path.write_bytes(buf.getvalue())


class MakeReleaseGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="datacore-make-release-test-")
        self.temp_dir = Path(self.tmp.name)
        self.repo_copy = self.temp_dir / "repo"
        shutil.copytree(
            REPO,
            self.repo_copy,
            ignore=shutil.ignore_patterns(".git", "dist", "__pycache__", "*.pyc"),
        )
        self.bundle_dir = self.temp_dir / "bundle"
        self.bundle_dir.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def run_make_release(self, version: str, bundle_dir: Path):
        return subprocess.run(
            ["sh", str(self.repo_copy / "make-release.sh"), version, str(bundle_dir)],
            cwd=self.repo_copy,
            capture_output=True,
            text=True,
        )

    def test_matching_versions_pass_guard(self):
        build_fake_archive(self.bundle_dir / "datacore-local-edition-amd64.tar.gz", "0.1.88")
        build_fake_archive(self.bundle_dir / "datacore-local-edition-arm64.tar.gz", "0.1.88")

        result = self.run_make_release("v0.1.88", self.bundle_dir)
        self.assertNotIn("Installer and bundle versions must match", result.stderr)
        self.assertNotIn("manifest is missing or unreadable", result.stderr)
        self.assertEqual(result.returncode, 0, f"make-release failed unexpectedly:\n{result.stderr}")

    def test_mismatched_version_exits_one_with_message(self):
        build_fake_archive(self.bundle_dir / "datacore-local-edition-amd64.tar.gz", "0.1.83")
        build_fake_archive(self.bundle_dir / "datacore-local-edition-arm64.tar.gz", "0.1.88")

        result = self.run_make_release("v0.1.88", self.bundle_dir)
        self.assertEqual(result.returncode, 1)
        expected_msg = (
            "Bundle datacore-local-edition-amd64.tar.gz is 0.1.83 but this installer release is v0.1.88. "
            "Installer and bundle versions must match: build bundle 0.1.88."
        )
        self.assertIn(expected_msg, result.stderr)

    def test_arm64_mismatch_exits_one_with_message(self):
        build_fake_archive(self.bundle_dir / "datacore-local-edition-amd64.tar.gz", "0.1.88")
        build_fake_archive(self.bundle_dir / "datacore-local-edition-arm64.tar.gz", "0.1.83")

        result = self.run_make_release("v0.1.88", self.bundle_dir)
        self.assertEqual(result.returncode, 1)
        expected_msg = (
            "Bundle datacore-local-edition-arm64.tar.gz is 0.1.83 but this installer release is v0.1.88. "
            "Installer and bundle versions must match: build bundle 0.1.88."
        )
        self.assertIn(expected_msg, result.stderr)

    def test_missing_manifest_exits_one(self):
        build_fake_archive(self.bundle_dir / "datacore-local-edition-amd64.tar.gz", "0.1.88", has_manifest=False)
        build_fake_archive(self.bundle_dir / "datacore-local-edition-arm64.tar.gz", "0.1.88")

        result = self.run_make_release("v0.1.88", self.bundle_dir)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Bundle datacore-local-edition-amd64.tar.gz manifest is missing or unreadable.", result.stderr)

    def test_archive_without_dir_entries_nested_first_entry(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as tf:
            dir_name = "datacore-local-edition-0.1.88"
            # Add a nested file as the first entry, without adding directory entries
            dummy_content = b"nested file content\n"
            ti_dummy = tarfile.TarInfo(f"{dir_name}/nested/file.txt")
            ti_dummy.size = len(dummy_content)
            tf.addfile(ti_dummy, io.BytesIO(dummy_content))

            # Add manifest
            manifest_data = {
                "product": "Datacore Local Edition",
                "version": "0.1.88",
            }
            content = json.dumps(manifest_data, indent=2).encode("utf-8") + b"\n"
            ti_file = tarfile.TarInfo(f"{dir_name}/manifest.json")
            ti_file.size = len(content)
            tf.addfile(ti_file, io.BytesIO(content))

        dest_amd64 = self.bundle_dir / "datacore-local-edition-amd64.tar.gz"
        dest_amd64.write_bytes(buf.getvalue())
        build_fake_archive(self.bundle_dir / "datacore-local-edition-arm64.tar.gz", "0.1.88")

        result = self.run_make_release("v0.1.88", self.bundle_dir)
        self.assertNotIn("manifest is missing or unreadable", result.stderr)
        self.assertNotIn("Installer and bundle versions must match", result.stderr)
        self.assertEqual(result.returncode, 0, f"make-release failed unexpectedly:\n{result.stderr}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
