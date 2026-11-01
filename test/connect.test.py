#!/usr/bin/env python3
"""Exercise `datacore connect` through the shipped shell, with a fake Runtime and disposable files."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = Path(__file__).resolve().parents[1] / "lib" / "connect.sh"
NODE = shutil.which("node")
SCOPES = "events:read,events:write,facts:read,tasks:read,tasks:write"


class Runtime(BaseHTTPRequestHandler):
    """Stands in for the Runtime's /mcp endpoint and records what each request carried."""
    seen = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        Runtime.seen.append({"headers": dict(self.headers), "body": body})
        msg = json.loads(body)
        if "id" not in msg:
            self.send_response(202); self.end_headers(); return
        if msg.get("method") == "explode":
            self.send_response(500); self.end_headers(); self.wfile.write(b"boom"); return
        reply = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"echo": msg.get("method")}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *a):
        pass


class Fixture:
    def __init__(self, root, port):
        self.root = root
        self.home = root / "home"; self.home.mkdir()
        self.data = root / "data"
        self.state = self.data / "front-doors.json"
        self.bin = root / "bin"; self.bin.mkdir()
        (root / "tmp").mkdir()
        current = root / "versions" / "datacore-local-edition-test"
        current.mkdir(parents=True)
        (root / "current").symlink_to(current)
        (current / ".env").write_text(f"DATACORE_HOME={self.data}\nDATACORE_HTTP_PORT={port}\n")
        (self.bin / "bun").symlink_to(NODE)
        self.dcbin = root / "installed" / "bin" / "datacore"
        self.dcbin.parent.mkdir(parents=True)
        self.launcher = self.dcbin.parent / "muse-front-door"
        self.muse_settings = self.home / ".config" / "muse" / "settings.json"
        self.log = root / "runtime-cli.log"
        docker = self.bin / "docker"
        docker.write_text(f"#!{sys.executable}\n" + """import json, os, pathlib, sys
log = pathlib.Path(os.environ["CONNECT_TEST_LOG"])
def record(line):
    old = log.read_text() if log.exists() else ""
    log.write_text(old + line + "\\n")
if "agent-create" in sys.argv:
    agent = sys.argv[sys.argv.index("--agent-id") + 1]
    scopes = sys.argv[sys.argv.index("--scopes") + 1]
    record(f"create {agent} {scopes}")
    print(json.dumps({"token": "fixture-secret-" + agent}))
elif "agent-revoke" in sys.argv:
    record("revoke " + sys.argv[sys.argv.index("--agent-id") + 1])
    print(json.dumps({"revoked": True}))
else:
    print("fixture compose")
""")
        docker.chmod(0o755)

    def run(self, *args, stdin=None):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.root / "tmp"),
            "DATACORE_INSTALL_ROOT": str(self.root),
            "DATACORE_BIN_PATH": str(self.dcbin),
            "CONNECT_TEST_LOG": str(self.log),
        }
        return subprocess.run(["sh", str(SCRIPT), *args], input=stdin, capture_output=True, text=True, env=env, timeout=30)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def doc(self):
        return json.loads(self.state.read_text())


@unittest.skipUnless(NODE, "node is required to stand in for bun")
class ConnectTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Runtime)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.f = Fixture(Path(self.tmp.name), self.server.server_address[1])
        Runtime.seen = []

    def tearDown(self):
        self.tmp.cleanup()

    def test_connect_mints_a_front_door_identity_with_worker_scopes_only(self):
        r = self.f.run("muse", "--model", "muse-spark-1.3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.f.calls(), [f"create muse-front-door {SCOPES}"])
        entry = self.f.doc()["front_doors"]["muse"]
        self.assertEqual(entry["agent_id"], "muse-front-door")
        self.assertEqual(entry["model"], "muse-spark-1.3")
        self.assertEqual(entry["token"], "fixture-secret-muse-front-door")
        self.assertEqual(self.f.state.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fixture-secret", r.stdout + r.stderr)

    def test_any_model_is_accepted_because_datacore_never_launches_a_front_door(self):
        for model in ("gpt-oss-120b", "llama-local:70b", "some/vendor-model@v2"):
            r = self.f.run(f"client-{len(model)}", "--model", model)
            self.assertEqual(r.returncode, 0, r.stderr)
        models = {v["model"] for v in self.f.doc()["front_doors"].values()}
        self.assertEqual(models, {"gpt-oss-120b", "llama-local:70b", "some/vendor-model@v2"})

    def test_connecting_twice_keeps_the_credential_and_updates_only_the_model(self):
        self.f.run("codex")
        r = self.f.run("codex", "--model", "gpt-6-luna")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.f.calls()), 1, "a second connect must not reissue a working token")
        self.assertEqual(self.f.doc()["front_doors"]["codex"]["model"], "gpt-6-luna")

    def test_names_that_would_not_reach_the_front_door_are_refused_before_minting(self):
        for bad in ("Muse", "1muse", "my_client", "lifecycle-operator-x", "x-recovery-operator"):
            r = self.f.run(bad)
            self.assertNotEqual(r.returncode, 0, bad)
        self.assertEqual(self.f.calls(), [], "a refused name must not leave an identity in the Runtime")

    def test_list_never_prints_a_token(self):
        self.f.run("muse", "--model", "muse-spark-1.3")
        self.f.run("cursor")
        r = self.f.run("list")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("muse-front-door", r.stdout)
        self.assertIn("the client's choice", r.stdout)
        self.assertNotIn("fixture-secret", r.stdout + r.stderr)

    def test_write_merges_into_existing_settings_and_writes_no_secret(self):
        settings = self.f.root / "client" / "settings.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"theme": "dark", "mcpServers": {"other": {"command": "x"}}}))
        r = self.f.run("cursor", f"--write={settings}")
        self.assertEqual(r.returncode, 0, r.stderr)
        doc = json.loads(settings.read_text())
        self.assertEqual(doc["theme"], "dark")
        self.assertEqual(doc["mcpServers"]["other"], {"command": "x"})
        self.assertEqual(doc["mcpServers"]["datacore"],
                         {"command": str(self.f.dcbin), "args": ["connect", "serve", "cursor"]})
        self.assertNotIn("fixture-secret", settings.read_text())
        self.assertTrue(list(settings.parent.glob("settings.json.bak-*")), "the previous settings must be kept")

    def test_muse_gets_a_launcher_not_a_global_settings_entry(self):
        # Datacore also runs Muse as a worker, and a worker run inherits every server in Muse's
        # settings. Measured: an entry there blocked every Muse worker ("the server name is
        # reserved") and would hand each one the front door's identity.
        r = self.f.run("muse", "--write")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.f.muse_settings.exists(), "muse's global settings must not be created")
        self.assertTrue(os.access(self.f.launcher, os.X_OK), "the launcher must be executable")
        body = self.f.launcher.read_text()
        self.assertIn("exec muse -c 'mcpServers.datacore=", body)
        self.assertNotIn("fixture-secret", body)

    def test_the_launcher_hands_muse_a_well_formed_server_entry(self):
        self.f.run("muse", "--write")
        argv_log = self.f.root / "muse-argv.json"
        fake = self.f.bin / "muse"
        fake.write_text(f"#!{sys.executable}\nimport json, sys\n"
                        f"open({str(argv_log)!r}, 'w').write(json.dumps(sys.argv[1:]))\n")
        fake.chmod(0o755)
        env = {"PATH": f"{self.f.bin}:/usr/bin:/bin", "HOME": str(self.f.home)}
        r = subprocess.run([str(self.f.launcher), "--resume"], capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = json.loads(argv_log.read_text())
        self.assertEqual(argv[0], "-c")
        key, _, value = argv[1].partition("=")
        self.assertEqual(key, "mcpServers.datacore")
        self.assertEqual(json.loads(value), {"command": str(self.f.dcbin), "args": ["connect", "serve", "muse"]})
        self.assertEqual(argv[2:], ["--resume"], "the user's own arguments must pass through untouched")

        # `muse exec` takes its own flags after the subcommand, so the server goes after `exec`.
        r = subprocess.run([str(self.f.launcher), "exec", "--model", "m", "hello"], capture_output=True, text=True, env=env, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = json.loads(argv_log.read_text())
        self.assertEqual(argv[0], "exec")
        self.assertEqual(argv[1], "-c")
        self.assertTrue(argv[2].startswith("mcpServers.datacore="))
        self.assertEqual(argv[3:], ["--model", "m", "hello"])

    def test_the_entry_an_earlier_version_wrote_is_taken_back(self):
        self.f.muse_settings.parent.mkdir(parents=True)
        self.f.muse_settings.write_text(json.dumps({
            "model": "muse-wonder-1.0",
            "mcpServers": {"datacore": {"command": str(self.f.dcbin), "args": ["connect", "serve", "muse"]},
                           "other": {"command": "x"}}}))
        r = self.f.run("muse", "--write")
        self.assertEqual(r.returncode, 0, r.stderr)
        doc = json.loads(self.f.muse_settings.read_text())
        self.assertNotIn("datacore", doc["mcpServers"])
        self.assertEqual(doc["mcpServers"]["other"], {"command": "x"})
        self.assertEqual(doc["model"], "muse-wonder-1.0")
        self.assertTrue(list(self.f.muse_settings.parent.glob("settings.json.bak-*")))

    def test_a_datacore_server_the_user_configured_is_left_alone(self):
        self.f.muse_settings.parent.mkdir(parents=True)
        mine = {"mcpServers": {"datacore": {"command": "/somewhere/else", "args": ["--mine"]}}}
        self.f.muse_settings.write_text(json.dumps(mine))
        r = self.f.run("muse", "--write")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(self.f.muse_settings.read_text()), mine)

    def test_writing_muse_global_settings_by_path_is_refused(self):
        r = self.f.run("muse", f"--write={self.f.muse_settings}")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("worker", r.stderr)
        self.assertFalse(self.f.muse_settings.exists())

    def test_remove_also_deletes_the_launcher(self):
        self.f.run("muse", "--write")
        self.assertTrue(self.f.launcher.exists())
        r = self.f.run("remove", "muse")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.f.launcher.exists())

    def test_invalid_settings_are_left_untouched(self):
        settings = self.f.root / "broken.json"
        settings.write_text("{not json")
        r = self.f.run("cursor", f"--write={settings}")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(settings.read_text(), "{not json")

    def test_serve_forwards_with_the_front_door_token_and_bundle(self):
        self.f.run("muse")
        lines = "\n".join([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize"}),
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
        ]) + "\n"
        r = self.f.run("serve", "muse", stdin=lines)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(Runtime.seen), 3)
        for req in Runtime.seen:
            self.assertEqual(req["headers"].get("Authorization"), "Bearer fixture-secret-muse-front-door")
            self.assertEqual(req["headers"].get("X-Datacore-MCP-Tool-Bundle"), "front_door")
        out = [json.loads(l) for l in r.stdout.splitlines()]
        self.assertEqual([m["id"] for m in out], [1, 2], "a notification answered 202 must produce no output")
        self.assertEqual(out[1]["result"]["echo"], "tools/list")

    def test_serve_turns_a_runtime_failure_into_an_error_the_client_can_match(self):
        self.f.run("muse")
        r = self.f.run("serve", "muse", stdin=json.dumps({"jsonrpc": "2.0", "id": 7, "method": "explode"}) + "\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        reply = json.loads(r.stdout.strip())
        self.assertEqual(reply["id"], 7)
        self.assertIn("HTTP 500", reply["error"]["message"])

    def test_serve_for_an_unknown_name_keeps_stdout_clean(self):
        r = self.f.run("serve", "nobody", stdin="")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, "", "stdout is the protocol channel; diagnostics belong on stderr")
        self.assertIn("not connected", r.stderr)

    def test_remove_revokes_and_forgets(self):
        self.f.run("muse")
        r = self.f.run("remove", "muse")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("revoke muse-front-door", self.f.calls())
        self.assertEqual(self.f.doc()["front_doors"], {})

    def test_a_corrupt_state_file_is_reported_not_overwritten(self):
        self.f.data.mkdir(parents=True)
        self.f.state.write_text("{oops")
        r = self.f.run("muse")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.f.state.read_text(), "{oops")
        self.assertEqual(self.f.calls(), [], "nothing may be minted when its token could not be stored")


if __name__ == "__main__":
    unittest.main(verbosity=1)
