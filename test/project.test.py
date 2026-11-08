#!/usr/bin/env python3
"""Exercise `datacore project` git repository detection for normal repos, worktrees, plain dirs, and missing paths."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "lib" / "project.sh"
RUNTIME = shutil.which("bun") or shutil.which("node")

GIT_IDENTITY_ENV = {
    "GIT_AUTHOR_NAME": "CI",
    "GIT_AUTHOR_EMAIL": "ci@example.invalid",
    "GIT_COMMITTER_NAME": "CI",
    "GIT_COMMITTER_EMAIL": "ci@example.invalid",
}


def run_git(*args: str, env: dict | None = None, check: bool = True, **kwargs) -> subprocess.CompletedProcess:
    git_env = {**os.environ, **GIT_IDENTITY_ENV}
    if env is not None:
        git_env.update(env)
    return subprocess.run(
        ["git", "-c", "user.name=CI", "-c", "user.email=ci@example.invalid", *args],
        env=git_env,
        check=check,
        **kwargs,
    )


@unittest.skipUnless(RUNTIME, "Bun or Node is required to run project.sh map tool")
class ProjectWorktreeGitCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="datacore-project-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.install = self.root / "install"
        self.bin = self.install / "bin"
        self.bin.mkdir(parents=True)
        current = self.install / "current"
        current.mkdir(parents=True)
        (current / ".env").write_text("DATACORE_WORKER_PROJECT_WORKSPACES='{}'\n")
        (self.bin / "bun").symlink_to(RUNTIME)

        self.env = {
            **os.environ,
            **GIT_IDENTITY_ENV,
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "DATACORE_INSTALL_ROOT": str(self.install),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
        }

    run_git = staticmethod(run_git)

    def run_project(self, *args: str, env_override: dict | None = None) -> subprocess.CompletedProcess:
        env = self.env if env_override is None else env_override
        return subprocess.run(
            ["sh", str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )

    def test_a1_normal_repository_no_warning_and_unlabelled(self) -> None:
        repo = self.root / "repo-a1"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        res_link = self.run_project("link", "proj-a1", str(repo))
        self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")
        self.assertNotIn("is not a git repository", res_link.stderr)
        self.assertIn("proj-a1", res_link.stdout)
        self.assertNotIn("(not a git repository)", res_link.stdout)

        res_list = self.run_project("list")
        self.assertEqual(res_list.returncode, 0)
        self.assertIn("proj-a1", res_list.stdout)
        self.assertIn(str(repo), res_list.stdout)
        self.assertNotIn("(not a git repository)", res_list.stdout)
        self.assertNotIn("(missing — dispatch will fail)", res_list.stdout)

    def test_a2_linked_worktree_behaves_same_as_normal_repo(self) -> None:
        base_repo = self.root / "base-a2"
        base_repo.mkdir()
        self.run_git("init", "-q", str(base_repo))
        self.run_git("-C", str(base_repo), "commit", "--allow-empty", "-m", "init", "-q")
        worktree = self.root / "worktree-a2"
        self.run_git("-C", str(base_repo), "worktree", "add", "-q", str(worktree))

        # Confirm that in a linked worktree, .git is a file, not a directory
        git_entry = worktree / ".git"
        self.assertTrue(git_entry.is_file(), f"Expected {git_entry} to be a file")

        res_link = self.run_project("link", "proj-a2", str(worktree))
        self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")
        self.assertNotIn("is not a git repository", res_link.stderr)
        self.assertIn("proj-a2", res_link.stdout)
        self.assertNotIn("(not a git repository)", res_link.stdout)

        res_list = self.run_project("list")
        self.assertEqual(res_list.returncode, 0)
        self.assertIn("proj-a2", res_list.stdout)
        self.assertIn(str(worktree), res_list.stdout)
        self.assertNotIn("(not a git repository)", res_list.stdout)
        self.assertNotIn("(missing — dispatch will fail)", res_list.stdout)

    def test_a3_plain_directory_warns_and_is_labelled(self) -> None:
        plain = self.root / "plain-a3"
        plain.mkdir()

        res_link = self.run_project("link", "proj-a3", str(plain))
        self.assertEqual(res_link.returncode, 0)
        self.assertIn(f"{plain} is not a git repository", res_link.stderr)
        self.assertIn("a worker records its work as commits there", res_link.stderr)
        self.assertIn("(not a git repository)", res_link.stdout)

        res_list = self.run_project("list")
        self.assertEqual(res_list.returncode, 0)
        self.assertIn("proj-a3", res_list.stdout)
        self.assertIn(f"{plain}  (not a git repository)", res_list.stdout)

    def test_a4_missing_path_shows_missing_dispatch_will_fail(self) -> None:
        target = self.root / "disappearing-a4"
        target.mkdir()

        res_link = self.run_project("link", "proj-a4", str(target))
        self.assertEqual(res_link.returncode, 0)

        # Remove the directory so it becomes missing
        target.rmdir()
        self.assertFalse(target.exists())

        res_list = self.run_project("list")
        self.assertEqual(res_list.returncode, 0)
        self.assertIn("proj-a4", res_list.stdout)
        self.assertIn(f"{target}  (missing — dispatch will fail)", res_list.stdout)

    def test_fallback_when_git_is_not_installed(self) -> None:
        """Verify fallback [ -e "$path/.git" ] when git command is not available on PATH."""
        no_git_bin = self.root / "no_git_bin"
        no_git_bin.mkdir()
        for b in ["sh", "rm", "cat", "mktemp", "pwd", "mkdir"]:
            p = shutil.which(b)
            if p:
                (no_git_bin / b).symlink_to(p)
        (no_git_bin / "bun").symlink_to(RUNTIME)

        no_git_env = {
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "DATACORE_INSTALL_ROOT": str(self.install),
            "PATH": str(no_git_bin),
        }

        # Confirm git is indeed absent in this environment
        probe = subprocess.run(["sh", "-c", "command -v git"], env=no_git_env, capture_output=True)
        self.assertNotEqual(probe.returncode, 0)

        # Prepare normal repo and linked worktree fixtures beforehand
        repo = self.root / "fallback-repo"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        base = self.root / "fallback-base"
        base.mkdir()
        self.run_git("init", "-q", str(base))
        self.run_git("-C", str(base), "commit", "--allow-empty", "-m", "init", "-q")
        wt = self.root / "fallback-wt"
        self.run_git("-C", str(base), "worktree", "add", "-q", str(wt))

        plain = self.root / "fallback-plain"
        plain.mkdir()

        # Link normal repo without git on PATH
        res_link_repo = self.run_project("link", "fb-repo", str(repo), env_override=no_git_env)
        self.assertEqual(res_link_repo.returncode, 0)
        self.assertNotIn("is not a git repository", res_link_repo.stderr)
        self.assertNotIn("(not a git repository)", res_link_repo.stdout)

        # Link worktree without git on PATH (fallback checks [ -e "$path/.git" ])
        res_link_wt = self.run_project("link", "fb-wt", str(wt), env_override=no_git_env)
        self.assertEqual(res_link_wt.returncode, 0)
        self.assertNotIn("is not a git repository", res_link_wt.stderr)
        self.assertNotIn("(not a git repository)", res_link_wt.stdout)

        # Link plain dir without git on PATH
        res_link_plain = self.run_project("link", "fb-plain", str(plain), env_override=no_git_env)
        self.assertEqual(res_link_plain.returncode, 0)
        self.assertIn("is not a git repository", res_link_plain.stderr)
        self.assertIn("(not a git repository)", res_link_plain.stdout)

        # Bare repo without git on PATH
        bare = self.root / "fallback-bare"
        self.run_git("init", "--bare", "-q", str(bare))
        res_link_bare = self.run_project("link", "fb-bare", str(bare), env_override=no_git_env)
        self.assertEqual(res_link_bare.returncode, 0)
        self.assertIn("is not a git repository", res_link_bare.stderr)
        self.assertIn("(not a git repository)", res_link_bare.stdout)

        # List all without git on PATH
        res_list = self.run_project("list", env_override=no_git_env)
        self.assertEqual(res_list.returncode, 0)
        self.assertIn("fb-repo", res_list.stdout)
        self.assertIn("fb-wt", res_list.stdout)
        self.assertIn("fb-plain", res_list.stdout)
        self.assertIn("fb-bare", res_list.stdout)
        self.assertNotIn(f"{repo}  (not a git repository)", res_list.stdout)
        self.assertNotIn(f"{wt}  (not a git repository)", res_list.stdout)
        self.assertIn(f"{plain}  (not a git repository)", res_list.stdout)
        self.assertIn(f"{bare}  (not a git repository)", res_list.stdout)

    def test_e1_fake_stop_leaves_listener_pid_unchanged_warns_with_remediation_and_exits_nonzero(self) -> None:
        repo = self.root / "repo-e1"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        listener_file = self.root / "listener_e1.txt"
        listener_file.write_text("1001\n")

        lsof_shim = self.bin / "lsof"
        lsof_shim.write_text(f"""#!/bin/sh
if [ -s "{listener_file}" ]; then
  cat "{listener_file}"
  exit 0
fi
exit 1
""")
        lsof_shim.chmod(0o755)

        curl_shim = self.bin / "curl"
        curl_shim.write_text("""#!/bin/sh
exit 0
""")
        curl_shim.chmod(0o755)

        current = self.install / "current"
        stop_sh = current / "stop-host-worker-bridge.sh"
        stop_sh.write_text("""#!/bin/sh
# Leaves listener PID unchanged (simulating lost PID file)
exit 0
""")
        stop_sh.chmod(0o755)

        start_sh = current / "start-host-worker-bridge.sh"
        start_sh.write_text("""#!/bin/sh
exit 0
""")
        start_sh.chmod(0o755)

        env = {**self.env, "DATACORE_BRIDGE_RESTART_TIMEOUT": "1"}
        res = self.run_project("link", "proj-e1", str(repo), env_override=env)

        self.assertNotEqual(res.returncode, 0, "link must exit non-zero when bridge restart fails")
        self.assertNotIn("restarted the worker bridge", res.stdout)
        self.assertNotIn("restarted the worker bridge", res.stderr)
        self.assertIn(
            "the worker bridge did not restart, and workers will keep using the previous project map",
            res.stderr,
        )
        self.assertIn("remediation:", res.stderr)
        self.assertNotIn("datacore restart", res.stderr)
        self.assertIn("./start-host-worker-bridge.sh", res.stderr)
        self.assertIn("1001", res.stderr)

        # Mapping must still be saved
        env_content = (current / ".env").read_text()
        self.assertIn("proj-e1", env_content)
        self.assertIn(str(repo), env_content)

    def test_e2_listener_pid_changes_and_health_answers_restarts_bridge_and_exits_zero(self) -> None:
        repo = self.root / "repo-e2"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        listener_file = self.root / "listener_e2.txt"
        listener_file.write_text("1001\n")

        lsof_shim = self.bin / "lsof"
        lsof_shim.write_text(f"""#!/bin/sh
if [ -s "{listener_file}" ]; then
  cat "{listener_file}"
  exit 0
fi
exit 1
""")
        lsof_shim.chmod(0o755)

        curl_shim = self.bin / "curl"
        curl_shim.write_text("""#!/bin/sh
exit 0
""")
        curl_shim.chmod(0o755)

        current = self.install / "current"
        stop_sh = current / "stop-host-worker-bridge.sh"
        stop_sh.write_text(f"""#!/bin/sh
rm -f "{listener_file}"
exit 0
""")
        stop_sh.chmod(0o755)

        start_sh = current / "start-host-worker-bridge.sh"
        start_sh.write_text(f"""#!/bin/sh
printf '2002\\n' > "{listener_file}"
exit 0
""")
        start_sh.chmod(0o755)

        res = self.run_project("link", "proj-e2", str(repo))
        self.assertEqual(res.returncode, 0, f"link failed: {res.stderr}")
        self.assertIn("restarted the worker bridge so it picks up the change", res.stdout)
        self.assertIn("proj-e2", res.stdout)
        self.assertIn(str(repo), res.stdout)

        env_content = (current / ".env").read_text()
        self.assertIn("proj-e2", env_content)

    def test_e3_no_bridge_running_saves_mapping_says_nothing_about_restart(self) -> None:
        repo = self.root / "repo-e3"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        lsof_shim = self.bin / "lsof"
        lsof_shim.write_text("""#!/bin/sh
exit 1
""")
        lsof_shim.chmod(0o755)

        current = self.install / "current"
        stop_sh = current / "stop-host-worker-bridge.sh"
        stop_sh.write_text("""#!/bin/sh
exit 0
""")
        stop_sh.chmod(0o755)

        start_sh = current / "start-host-worker-bridge.sh"
        start_sh.write_text("""#!/bin/sh
exit 0
""")
        start_sh.chmod(0o755)

        res = self.run_project("link", "proj-e3", str(repo))
        self.assertEqual(res.returncode, 0, f"link failed: {res.stderr}")
        self.assertNotIn("restarted the worker bridge", res.stdout)
        self.assertNotIn("the worker bridge did not restart", res.stderr)
        self.assertIn("proj-e3", res.stdout)
        self.assertIn(str(repo), res.stdout)

        env_content = (current / ".env").read_text()
        self.assertIn("proj-e3", env_content)

    def test_e4_bare_repository_labelled_not_git_repo_and_worktree_passes(self) -> None:
        # Bare repo check
        bare = self.root / "bare-e4"
        self.run_git("init", "--bare", "-q", str(bare))

        res_bare = self.run_project("link", "proj-bare", str(bare))
        self.assertEqual(res_bare.returncode, 0)
        self.assertIn("is not a git repository", res_bare.stderr)
        self.assertIn("(not a git repository)", res_bare.stdout)

        res_list = self.run_project("list")
        self.assertEqual(res_list.returncode, 0)
        self.assertIn("proj-bare", res_list.stdout)
        self.assertIn(f"{bare}  (not a git repository)", res_list.stdout)

        # Linked worktree check
        base = self.root / "base-e4"
        base.mkdir()
        self.run_git("init", "-q", str(base))
        self.run_git("-C", str(base), "commit", "--allow-empty", "-m", "init", "-q")
        wt = self.root / "wt-e4"
        self.run_git("-C", str(base), "worktree", "add", "-q", str(wt))

        res_wt = self.run_project("link", "proj-wt", str(wt))
        self.assertEqual(res_wt.returncode, 0)
        self.assertNotIn("is not a git repository", res_wt.stderr)
        self.assertNotIn(f"{wt}  (not a git repository)", res_wt.stdout)

        res_list2 = self.run_project("list")
        self.assertEqual(res_list2.returncode, 0)
        self.assertIn("proj-wt", res_list2.stdout)
        self.assertNotIn(f"{wt}  (not a git repository)", res_list2.stdout)

    def test_fallback_when_lsof_is_unavailable_uses_pid_file(self) -> None:
        """Verify fallback to <temp DATACORE_HOME>/host-worker-bridge/host-worker-bridge.pid when lsof is unavailable."""
        repo = self.root / "repo-fb-lsof"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        no_lsof_bin = self.root / "no_lsof_bin"
        no_lsof_bin.mkdir()
        for b in ["sh", "rm", "cat", "mktemp", "pwd", "mkdir", "git", "grep", "cut", "tail", "tr", "sleep"]:
            p = shutil.which(b)
            if p:
                (no_lsof_bin / b).symlink_to(p)
        (no_lsof_bin / "bun").symlink_to(RUNTIME)

        curl_shim = no_lsof_bin / "curl"
        curl_shim.write_text("""#!/bin/sh
exit 0
""")
        curl_shim.chmod(0o755)

        data_home = self.root / "data_home"
        bridge_dir = data_home / "host-worker-bridge"
        bridge_dir.mkdir(parents=True)
        pid_file = bridge_dir / "host-worker-bridge.pid"
        pid_file.write_text("3001\n")

        current = self.install / "current"
        (current / ".env").write_text(f"DATACORE_HOME={data_home}\nDATACORE_WORKER_PROJECT_WORKSPACES='{{}}'\n")

        no_lsof_env = {
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "DATACORE_INSTALL_ROOT": str(self.install),
            "PATH": str(no_lsof_bin),
            "DATACORE_BRIDGE_RESTART_TIMEOUT": "1",
        }

        # Confirm lsof is absent
        probe = subprocess.run(["sh", "-c", "command -v lsof"], env=no_lsof_env, capture_output=True)
        self.assertNotEqual(probe.returncode, 0)

        # Case 1: stop changes the PID file to a new PID -> success
        stop_sh = current / "stop-host-worker-bridge.sh"
        stop_sh.write_text(f"""#!/bin/sh
rm -f "{pid_file}"
exit 0
""")
        stop_sh.chmod(0o755)

        start_sh = current / "start-host-worker-bridge.sh"
        start_sh.write_text(f"""#!/bin/sh
printf '3002\\n' > "{pid_file}"
exit 0
""")
        start_sh.chmod(0o755)

        res = self.run_project("link", "proj-fb-lsof", str(repo), env_override=no_lsof_env)
        self.assertEqual(res.returncode, 0, f"link failed: {res.stderr}")
        self.assertIn("restarted the worker bridge so it picks up the change", res.stdout)

        # Case 2: stop leaves the PID file unchanged -> failure with remediation
        pid_file.write_text("3002\n")
        stop_sh.write_text("""#!/bin/sh
# leaves PID file unchanged
exit 0
""")
        res_fail = self.run_project("link", "proj-fb-lsof2", str(repo), env_override=no_lsof_env)
        self.assertNotEqual(res_fail.returncode, 0)
        self.assertNotIn("restarted the worker bridge", res_fail.stdout)
        self.assertIn("the worker bridge did not restart, and workers will keep using the previous project map", res_fail.stderr)
        self.assertIn("remediation:", res_fail.stderr)
        self.assertNotIn("datacore restart", res_fail.stderr)
        self.assertIn("3002", res_fail.stderr)
        self.assertIn("./start-host-worker-bridge.sh", res_fail.stderr)

    def test_fallback_when_lsof_is_unavailable_uses_bridge_state_dir(self) -> None:
        """Verify fallback uses overriding DATACORE_WORKER_BRIDGE_STATE_DIR when lsof is unavailable."""
        repo = self.root / "repo-fb-statedir"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        no_lsof_bin = self.root / "no_lsof_bin_statedir"
        no_lsof_bin.mkdir()
        for b in ["sh", "rm", "cat", "mktemp", "pwd", "mkdir", "git", "grep", "cut", "tail", "tr", "sleep"]:
            p = shutil.which(b)
            if p:
                (no_lsof_bin / b).symlink_to(p)
        (no_lsof_bin / "bun").symlink_to(RUNTIME)

        curl_shim = no_lsof_bin / "curl"
        curl_shim.write_text("""#!/bin/sh
exit 0
""")
        curl_shim.chmod(0o755)

        custom_state = self.root / "custom_bridge_state"
        custom_state.mkdir(parents=True)
        pid_file = custom_state / "host-worker-bridge.pid"
        pid_file.write_text("4001\n")

        current = self.install / "current"
        (current / ".env").write_text(
            f"DATACORE_WORKER_BRIDGE_STATE_DIR={custom_state}\nDATACORE_WORKER_PROJECT_WORKSPACES='{{}}'\n"
        )

        no_lsof_env = {
            "HOME": str(self.root),
            "TMPDIR": str(self.root),
            "DATACORE_INSTALL_ROOT": str(self.install),
            "PATH": str(no_lsof_bin),
            "DATACORE_BRIDGE_RESTART_TIMEOUT": "1",
        }

        # Case 1: stop changes the PID file in custom_state -> success
        stop_sh = current / "stop-host-worker-bridge.sh"
        stop_sh.write_text(f"""#!/bin/sh
rm -f "{pid_file}"
exit 0
""")
        stop_sh.chmod(0o755)

        start_sh = current / "start-host-worker-bridge.sh"
        start_sh.write_text(f"""#!/bin/sh
printf '4002\\n' > "{pid_file}"
exit 0
""")
        start_sh.chmod(0o755)

        res = self.run_project("link", "proj-fb-sd", str(repo), env_override=no_lsof_env)
        self.assertEqual(res.returncode, 0, f"link failed: {res.stderr}")
        self.assertIn("restarted the worker bridge so it picks up the change", res.stdout)

        # Case 2: stop leaves the PID file unchanged in custom_state -> failure with remediation
        pid_file.write_text("4002\n")
        stop_sh.write_text("""#!/bin/sh
exit 0
""")
        res_fail = self.run_project("link", "proj-fb-sd2", str(repo), env_override=no_lsof_env)
        self.assertNotEqual(res_fail.returncode, 0)
        self.assertNotIn("restarted the worker bridge", res_fail.stdout)
        self.assertIn("remediation:", res_fail.stderr)
        self.assertNotIn("datacore restart", res_fail.stderr)
        self.assertIn("4002", res_fail.stderr)
        self.assertIn("./start-host-worker-bridge.sh", res_fail.stderr)

    def test_remediation_text_contains_no_datacore_restart(self) -> None:
        """Verify remediation text on failed bridge restart contains no 'datacore restart'."""
        repo = self.root / "repo-remediation"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        listener_file = self.root / "listener_remediation.txt"
        listener_file.write_text("5001\n")

        lsof_shim = self.bin / "lsof"
        lsof_shim.write_text(f"""#!/bin/sh
cat "{listener_file}"
exit 0
""")
        lsof_shim.chmod(0o755)

        curl_shim = self.bin / "curl"
        curl_shim.write_text("""#!/bin/sh
exit 0
""")
        curl_shim.chmod(0o755)

        current = self.install / "current"
        stop_sh = current / "stop-host-worker-bridge.sh"
        stop_sh.write_text("""#!/bin/sh
exit 0
""")
        stop_sh.chmod(0o755)

        start_sh = current / "start-host-worker-bridge.sh"
        start_sh.write_text("""#!/bin/sh
exit 0
""")
        start_sh.chmod(0o755)

        env = {**self.env, "DATACORE_BRIDGE_RESTART_TIMEOUT": "1"}
        res = self.run_project("link", "proj-remediation", str(repo), env_override=env)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("remediation:", res.stderr)
        self.assertNotIn("datacore restart", res.stderr)
        self.assertIn("kill the old bridge process (PID 5001)", res.stderr)
        self.assertIn("./start-host-worker-bridge.sh", res.stderr)

    def test_help_documents_exit_code_on_failed_bridge_restart(self) -> None:
        """Verify project --help documents that project link and unlink exit 1 when bridge does not restart."""
        res = self.run_project("--help")
        self.assertEqual(res.returncode, 0)
        self.assertIn("project link", res.stdout)
        self.assertIn("project unlink", res.stdout)
        self.assertIn("exit 1 when the bridge does not restart", res.stdout)

    def test_d4_coordinator_env_updated_on_link_and_unlink(self) -> None:
        repo1 = self.root / "repo-d4-1"
        repo1.mkdir()
        self.run_git("init", "-q", str(repo1))

        generated = self.install / "current" / "generated"
        generated.mkdir(parents=True, exist_ok=True)
        coord_env = generated / "coordinator.env"
        coord_env.write_text("DATACORE_HTTP_PORT=43123\nDATACORE_WORKER_PROJECT_WORKSPACES={}\nSOME_OTHER_KEY=val\n")
        coord_env.chmod(0o600)

        res_link = self.run_project("link", "proj-d4", str(repo1))
        self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")
        self.assertIn("the Coordinator picks up the project map at its next start (datacore start); dispatch is unaffected meanwhile", res_link.stdout)

        # File permissions preserved at 0600
        self.assertEqual(coord_env.stat().st_mode & 0o777, 0o600)

        # Verify coordinator.env holds the same map as .env
        env_raw = (self.install / "current" / ".env").read_text()
        coord_raw = coord_env.read_text()
        self.assertIn("DATACORE_HTTP_PORT=43123\n", coord_raw)
        self.assertIn("SOME_OTHER_KEY=val\n", coord_raw)

        m_env = re.search(r"^DATACORE_WORKER_PROJECT_WORKSPACES=(.*)$", env_raw, re.MULTILINE)
        m_coord = re.search(r"^DATACORE_WORKER_PROJECT_WORKSPACES=(.*)$", coord_raw, re.MULTILINE)
        self.assertIsNotNone(m_env)
        self.assertIsNotNone(m_coord)
        map_env = json.loads(m_env.group(1).strip("'\""))
        map_coord = json.loads(m_coord.group(1).strip("'\""))
        self.assertEqual(map_env, map_coord)
        self.assertEqual(map_coord.get("proj-d4"), str(repo1))

        # Unlink proj-d4
        res_unlink = self.run_project("unlink", "proj-d4")
        self.assertEqual(res_unlink.returncode, 0, f"unlink failed: {res_unlink.stderr}")
        self.assertIn("the Coordinator picks up the project map at its next start (datacore start); dispatch is unaffected meanwhile", res_unlink.stdout)
        self.assertEqual(coord_env.stat().st_mode & 0o777, 0o600)

        coord_raw_unlink = coord_env.read_text()
        env_raw_unlink = (self.install / "current" / ".env").read_text()
        m_env_un = re.search(r"^DATACORE_WORKER_PROJECT_WORKSPACES=(.*)$", env_raw_unlink, re.MULTILINE)
        m_coord_un = re.search(r"^DATACORE_WORKER_PROJECT_WORKSPACES=(.*)$", coord_raw_unlink, re.MULTILINE)
        self.assertIsNotNone(m_env_un)
        self.assertIsNotNone(m_coord_un)
        map_env_un = json.loads(m_env_un.group(1).strip("'\""))
        map_coord_un = json.loads(m_coord_un.group(1).strip("'\""))
        self.assertEqual(map_env_un, map_coord_un)
        self.assertNotIn("proj-d4", map_coord_un)

    def test_d4_missing_coordinator_env_tolerated(self) -> None:
        repo = self.root / "repo-d4-missing"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        coord_env = self.install / "current" / "generated" / "coordinator.env"
        self.assertFalse(coord_env.exists())

        res_link = self.run_project("link", "proj-missing", str(repo))
        self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")
        self.assertFalse(coord_env.exists())
        self.assertNotIn("the Coordinator picks up the project map", res_link.stdout)

        res_unlink = self.run_project("unlink", "proj-missing")
        self.assertEqual(res_unlink.returncode, 0, f"unlink failed: {res_unlink.stderr}")
        self.assertFalse(coord_env.exists())
        self.assertNotIn("the Coordinator picks up the project map", res_unlink.stdout)

    def test_d4_coordinator_env_appended_if_missing_from_file(self) -> None:
        repo = self.root / "repo-d4-append"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        generated = self.install / "current" / "generated"
        generated.mkdir(parents=True, exist_ok=True)
        coord_env = generated / "coordinator.env"
        coord_env.write_text("DATACORE_HTTP_PORT=43123\n")
        coord_env.chmod(0o600)

        res_link = self.run_project("link", "proj-append", str(repo))
        self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")
        self.assertEqual(coord_env.stat().st_mode & 0o777, 0o600)

        coord_raw = coord_env.read_text()
        self.assertIn("DATACORE_HTTP_PORT=43123\n", coord_raw)
        m_coord = re.search(r"^DATACORE_WORKER_PROJECT_WORKSPACES=(.*)$", coord_raw, re.MULTILINE)
        self.assertIsNotNone(m_coord)
        map_coord = json.loads(m_coord.group(1).strip("'\""))
        self.assertEqual(map_coord.get("proj-append"), str(repo))

    def test_d4_coordinator_env_preserves_single_quoting_style(self) -> None:
        repo = self.root / "repo-d4-quoted"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        generated = self.install / "current" / "generated"
        generated.mkdir(parents=True, exist_ok=True)
        coord_env = generated / "coordinator.env"
        coord_env.write_text("DATACORE_WORKER_PROJECT_WORKSPACES='{}'\n")
        coord_env.chmod(0o600)

        res_link = self.run_project("link", "proj-quoted", str(repo))
        self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")

        coord_raw = coord_env.read_text()
        self.assertIn("DATACORE_WORKER_PROJECT_WORKSPACES='{", coord_raw)

    def test_d4_readonly_coordinator_env_warns_and_continues_with_exit_0(self) -> None:
        repo = self.root / "repo-d4-ro"
        repo.mkdir()
        self.run_git("init", "-q", str(repo))

        generated = self.install / "current" / "generated"
        generated.mkdir(parents=True, exist_ok=True)
        coord_env = generated / "coordinator.env"
        coord_env.write_text("DATACORE_WORKER_PROJECT_WORKSPACES='{\"old\":\"/tmp\"}'\n")
        coord_env.chmod(0o400)
        try:
            res_link = self.run_project("link", "proj-ro", str(repo))
            self.assertEqual(res_link.returncode, 0, f"link failed: {res_link.stderr}")
            self.assertNotIn("the Coordinator picks up the project map", res_link.stdout)
            self.assertIn(
                f"could not update {coord_env}; the Coordinator keeps its old project map until the next install (dispatch is unaffected)",
                res_link.stderr,
            )
            # Coordinator env was not modified
            coord_raw = coord_env.read_text()
            self.assertIn('"old":"/tmp"', coord_raw)
            self.assertNotIn("proj-ro", coord_raw)
            # .env was updated
            env_raw = (self.install / "current" / ".env").read_text()
            self.assertIn("proj-ro", env_raw)

            # Also verify unlink on read-only coordinator.env
            res_unlink = self.run_project("unlink", "proj-ro")
            self.assertEqual(res_unlink.returncode, 0, f"unlink failed: {res_unlink.stderr}")
            self.assertNotIn("the Coordinator picks up the project map", res_unlink.stdout)
            self.assertIn(
                f"could not update {coord_env}; the Coordinator keeps its old project map until the next install (dispatch is unaffected)",
                res_unlink.stderr,
            )
        finally:
            coord_env.chmod(0o600)


if __name__ == "__main__":
    unittest.main()
