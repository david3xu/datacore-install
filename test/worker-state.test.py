#!/usr/bin/env python3
"""Exercise worker choices through the shipped shell using disposable files and fake CLIs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "worker.sh"
NODE = shutil.which("node")
FAMILIES = [
    ("codex-worker", "codex", ["default", "alternate"], True, ["implementation", "rework"]),
    ("codex-review", "codex", ["default", "alternate"], True, ["review"]),
    ("muse-worker", "muse", ["default", "alternate"], False, ["implementation", "rework"]),
    ("muse-review", "muse", ["default", "alternate"], False, ["review"]),
]


def worker(family, cli, alias, phases):
    return {"agent_id": f"{family}@{alias}", "cli": cli, "model_alias": alias,
            "phases": phases, "token": f"fixture-{family}-{alias}"}


DEFAULT = [worker(f, c, a[0], p) for f, c, a, default, p in FAMILIES if default]
OPT_IN = [worker(f, c, a[0], p) for f, c, a, default, p in FAMILIES if not default]
ALT = worker("muse-worker", "muse", "alternate", ["implementation", "rework"])


def save(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc))


def config():
    # Match the minified bundle's family shape, with opt-in records immediately before defaults.
    # The extractor must never borrow the next family's default-profile flag or model alias.
    blocks = []
    for i, (family, cli, aliases, default, phases) in enumerate(sorted(FAMILIES, key=lambda f: f[3])):
        blocks.append(f'var M{i}={json.dumps(aliases, separators=(",", ":"))};' +
                      f'var F{i}={{agentFamily:"{family}",cli:"{cli}",modelAliases:M{i},' +
                      f'defaultModelAlias:"{aliases[0]}",inDefaultProfile:{str(default).lower()},' +
                      'phases:' + json.dumps(phases, separators=(",", ":")) + '};')
    return "\n".join(blocks)


class Fixture:
    def __init__(self, root):
        self.root = root
        self.home = root / "home"
        self.data = root / "data"
        self.state = self.data / "worker-state.json"
        self.mirror = self.data / "runtime" / "worker-registry.json"
        self.executors = self.data / "coordinator" / "executors.json"
        self.bin = root / "bin"
        self.bin.mkdir()
        self.home.mkdir()
        (root / "tmp").mkdir()
        (self.bin / "bun").symlink_to(NODE)
        docker = self.bin / "docker"
        self.mint_log = root / "minted-identities.txt"
        docker.write_text(f'#!{sys.executable}\n' + """import json, os, pathlib, sys
if "agent-create" in sys.argv:
    agent = sys.argv[sys.argv.index("--agent-id") + 1]
    log = pathlib.Path(os.environ["WORKER_TEST_MINT_LOG"])
    old = log.read_text().splitlines() if log.exists() else []
    log.write_text("\\n".join(old + [agent]) + "\\n")
    print(json.dumps({"token": "fixture-minted-" + agent + "-" + str(len(old) + 1)}))
else:
    print("fixture compose")
""")
        docker.chmod(0o755)
        self.set_clis("codex", "muse")

    def set_clis(self, *clis):
        for cli in ("codex", "muse"):
            path = self.bin / cli
            path.unlink(missing_ok=True)
            if cli in clis:
                path.write_text("#!/bin/sh\nexit 0\n")
                path.chmod(0o755)

    def version(self, name, workers=None):
        self.current = self.root / "versions" / name
        self.current.mkdir(parents=True)
        (self.current / "support").mkdir()
        (self.current / "support" / "install-config.js").write_text(config())
        link = self.root / "current"
        link.unlink(missing_ok=True)
        link.symlink_to(self.current, target_is_directory=True)
        self.registry = self.current / "generated" / "azure-worker-registry.json"
        self.catalogue = self.current / "generated" / "azure-worker-catalogue.json"
        save(self.registry, {"workers": DEFAULT if workers is None else workers})
        # Recreate the bundle-installer boundary: the new bundle replaces the live mirror.
        save(self.mirror, json.loads(self.registry.read_text()))

    def run(self, *args, success=True):
        env = {key: val for key, val in os.environ.items() if not key.startswith(("DATACORE_", "DC_"))}
        env.update(HOME=str(self.home), TMPDIR=str(self.root / "tmp"),
                   PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   DATACORE_INSTALL_ROOT=str(self.root), DATACORE_HOME=str(self.data),
                   WORKER_TEST_MINT_LOG=str(self.mint_log))
        result = subprocess.run(["/bin/sh", str(SCRIPT), *args], env=env, text=True,
                                capture_output=True, timeout=15)
        if success and result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        return result

    def entries(self):
        return json.loads(self.registry.read_text())["workers"]

    def ids(self):
        return {w["agent_id"] for w in self.entries()}

    def choices(self):
        return json.loads(self.state.read_text())

    def snapshot(self):
        return {str(p): p.read_bytes() for p in [self.registry, self.catalogue, self.mirror,
                                               self.executors, self.state] if p.exists()}


@unittest.skipUnless(NODE, "Node is required as the isolated Bun-compatible runner")
class WorkerStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="datacore-worker-test-")
        self.addCleanup(self.temp.cleanup)
        self.f = Fixture(Path(self.temp.name))
        self.f.version("old")

    def test_default_profile_flag_does_not_bleed_from_next_family(self):
        save(self.f.registry, {"workers": DEFAULT + OPT_IN})
        # No prior choices exist: opt-in credentials alone must not enable those families.
        self.f.run("prune")
        self.assertEqual(self.f.ids(), {w["agent_id"] for w in DEFAULT})
        self.assertEqual(self.f.choices()["chosen"], [])

    def test_first_provision_survives_prune(self):
        self.f.run("prune")
        self.f.run("add", "muse")
        self.assertEqual(set(self.f.choices()["chosen"]), {"muse-worker", "muse-review"})
        tokens = {w["agent_id"]: w["token"] for w in self.f.entries()}
        self.f.run("prune")
        self.assertEqual({w["agent_id"]: w["token"] for w in self.f.entries()}, tokens)

    def test_cli_add_provisions_missing_reviewer_without_reminting_worker(self):
        self.f.run("add", "muse-worker")
        first_token = next(w["token"] for w in self.f.entries() if w["agent_id"] == "muse-worker@default")
        self.f.run("add", "muse")
        muse = {w["agent_id"]: w["token"] for w in self.f.entries() if w["cli"] == "muse"}
        self.assertEqual(set(muse), {"muse-worker@default", "muse-review@default"})
        self.assertEqual(muse["muse-worker@default"], first_token)
        self.assertEqual(self.f.mint_log.read_text().splitlines(), ["muse-worker@default", "muse-review@default"])
        self.assertEqual(set(self.f.choices()["chosen"]), {"muse-worker", "muse-review"})
        self.f.run("prune")
        self.assertEqual({w["agent_id"]: w["token"] for w in self.f.entries() if w["cli"] == "muse"}, muse)

    def test_unknown_alias_fails_without_changing_intent_or_registry(self):
        self.f.run("add", "muse-worker")
        before = self.f.snapshot()
        result = self.f.run("add", "muse@unknown-model", success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no model 'unknown-model'", result.stderr)
        self.assertEqual(self.f.snapshot(), before)

    def test_remove_clears_choice_while_cli_absent(self):
        self.f.run("add", "muse")
        self.f.set_clis("codex")
        self.f.run("prune")
        self.assertFalse(any(x.startswith("muse") for x in self.f.ids()))
        self.f.run("remove", "muse")
        self.assertFalse(any(x.startswith("muse") for x in self.f.choices()["chosen"]))
        self.f.set_clis("codex", "muse")
        self.f.run("prune")
        self.assertFalse(any(x.startswith("muse") for x in self.f.ids()))

    def test_two_upgrade_boundaries_and_cli_return_keep_intent_and_tokens(self):
        save(self.f.registry, {"workers": DEFAULT + OPT_IN})
        save(self.f.catalogue, {"workers": DEFAULT + OPT_IN})
        self.f.version("new")
        self.f.run("prune")
        self.assertEqual(self.f.ids(), {w["agent_id"] for w in DEFAULT + OPT_IN})
        self.f.version("future")
        self.f.run("prune")
        self.assertEqual({w["agent_id"]: w["token"] for w in self.f.entries()},
                         {w["agent_id"]: w["token"] for w in DEFAULT + OPT_IN})
        self.f.set_clis()
        self.f.run("prune")
        self.assertEqual(self.f.ids(), set())
        self.assertEqual(set(self.f.choices()["chosen"]), {"muse-worker", "muse-review"})
        self.f.set_clis("codex", "muse")
        self.f.run("prune")
        self.f.run("remove", "muse")
        self.f.version("after-removal")
        self.f.run("prune")
        self.assertFalse(any(x.startswith("muse") for x in self.f.ids()))

    def test_default_removal_stays_disabled_until_explicit_add(self):
        self.f.run("prune")
        self.f.run("remove", "codex")
        self.assertEqual(self.f.ids(), set())
        self.assertEqual(set(self.f.choices()["disabled"]), {"codex-worker", "codex-review"})
        self.f.version("future")
        self.f.run("prune")
        self.assertEqual(self.f.ids(), set())
        self.f.run("add", "codex")
        self.assertEqual(self.f.choices()["disabled"], [])
        self.f.run("prune")
        self.assertEqual(self.f.ids(), {w["agent_id"] for w in DEFAULT})

    def test_remove_default_family_while_cli_absent_stays_removed(self):
        self.f.run("prune")
        self.f.set_clis("muse")
        self.f.run("prune")
        self.assertEqual(self.f.ids(), set())
        self.f.run("remove", "codex")
        self.f.set_clis("codex", "muse")
        self.f.run("prune")
        self.assertEqual(self.f.ids(), set())
        self.assertEqual(set(self.f.choices()["disabled"]), {"codex-worker", "codex-review"})

    def test_removing_unselected_alias_does_not_clear_saved_model(self):
        save(self.f.registry, {"workers": DEFAULT + OPT_IN + [ALT]})
        self.f.run("add", "muse-worker@alternate")
        self.f.set_clis("codex")
        self.f.run("prune")
        result = self.f.run("remove", "muse-worker@default", success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.f.choices()["selected"]["muse-worker"], ALT["agent_id"])
        self.f.set_clis("codex", "muse")
        self.f.run("prune")
        self.assertIn(ALT["agent_id"], self.f.ids())

    def test_explicit_model_replaces_family_and_survives_prune_upgrade(self):
        save(self.f.registry, {"workers": DEFAULT + OPT_IN + [ALT]})
        self.f.run("add", "muse-worker@alternate")
        self.assertEqual({x for x in self.f.ids() if x.startswith("muse-worker@")}, {ALT["agent_id"]})
        self.f.run("prune")
        self.f.version("future")
        self.f.run("prune")
        self.assertIn(ALT["agent_id"], self.f.ids())
        self.assertNotIn("muse-worker@default", self.f.ids())
        self.f.run("add", "muse-worker")
        self.assertIn("muse-worker@default", self.f.ids())
        self.assertNotIn(ALT["agent_id"], self.f.ids())
        self.assertNotIn("muse-worker", self.f.choices()["selected"])

    def test_current_registry_token_wins_over_older_catalogue(self):
        self.f.run("prune")
        current = {"workers": self.f.entries()}
        current["workers"][0]["token"] = "fixture-current-token"
        target = current["workers"][0]["agent_id"]
        save(self.f.registry, current)
        save(self.f.mirror, current)
        self.f.run("prune")
        self.assertEqual(next(w["token"] for w in self.f.entries() if w["agent_id"] == target),
                         "fixture-current-token")
        self.assertEqual(next(w["token"] for w in self.f.choices()["identities"] if w["agent_id"] == target),
                         "fixture-current-token")

    def test_corrupt_existing_state_fails_without_changing_files(self):
        self.f.run("add", "muse")
        secret = "fixture-secret-that-must-not-appear"
        self.f.state.write_text('{"token":"' + secret + '"')
        before = self.f.snapshot()
        result = self.f.run("prune", success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot read worker choices", result.stderr)
        self.assertNotIn(secret, result.stderr)
        self.assertEqual(self.f.snapshot(), before)

    def test_state_write_failure_leaves_registry_and_intent_unchanged(self):
        self.f.run("add", "muse")
        before = self.f.snapshot()
        # The atomic writer must create its temporary file alongside the state file.
        self.f.data.chmod(0o500)
        try:
            result = self.f.run("remove", "muse", success=False)
        finally:
            self.f.data.chmod(0o700)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not save worker choices", result.stderr)
        self.assertEqual(self.f.snapshot(), before)

    def test_atomic_replace_is_private_and_leaves_no_temporary_files(self):
        self.f.run("add", "muse")
        inode = self.f.state.stat().st_ino
        self.f.run("remove", "muse")
        self.assertNotEqual(self.f.state.stat().st_ino, inode)
        self.assertEqual(self.f.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.f.data.glob("worker-state.json.tmp.*")), [])
        self.f.run("prune")
        self.assertFalse(any(x.startswith("muse") for x in self.f.ids()))


if __name__ == "__main__":
    unittest.main()
