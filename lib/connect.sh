#!/bin/sh
# Datacore front doors — connect any AI client to plan, brief and dispatch work through Datacore.
#
# Usage: datacore connect <name> [--model <model>] [--write[=<settings.json>]]
#        datacore connect list | remove <name> | serve <name>
#
# A front door is the AI client a person talks to. It reads the briefing, shapes tasks and wakes
# workers through the Runtime's `front_door` MCP tool bundle. The bundle mints front-door
# credentials for Claude clients only, and the one connect script it ships runs `claude mcp add`, so
# every other client -- Muse, Codex, Cursor, a local model's chat app -- had no way in.
#
# Nothing in the Runtime required that. It picks a tool bundle by matching the agent id against role
# rules, and a front-door credential holds the same five scopes as any worker -- measured with
# `agent-list` on an installed Runtime. What makes an identity a front door is its name.
#
# So this mints one identity per client, keeps its token in a private file outside the versioned
# bundle (an upgrade replaces the bundle, as the worker choices learned), and serves it to the client
# over stdio. The client's settings then name a command, never a secret.
#
# Which model the client runs is the client's business. Datacore never launches a front door, so it
# has nothing to check a model against: `--model` is recorded for whoever reads `connect list`, and
# validated by nobody.
#
# DATACORE_HOME   runtime data directory (default: read from the install's .env)
set -eu
ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
DATA_HOME="${DATACORE_HOME:-}"
if [ -z "$DATA_HOME" ] && [ -f "$ROOT/current/.env" ]; then
  DATA_HOME=$(grep '^DATACORE_HOME=' "$ROOT/current/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
[ -n "$DATA_HOME" ] || DATA_HOME="$HOME/.datacore-local"
FRONT_DOORS="${DATACORE_FRONT_DOORS_PATH:-$DATA_HOME/front-doors.json}"
COMPOSE_PROJECT="${DATACORE_LOCAL_COMPOSE_PROJECT:-}"
if [ -z "$COMPOSE_PROJECT" ] && [ -f "$ROOT/current/.env" ]; then
  COMPOSE_PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' "$ROOT/current/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
[ -n "$COMPOSE_PROJECT" ] || COMPOSE_PROJECT="datacore-local"
# What the client's settings name. An absolute path, because MCP clients start servers with a
# minimal PATH and do not expand `~`.
DATACORE_BIN="${DATACORE_BIN_PATH:-$ROOT/bin/datacore}"

die() { printf '%s\n' "$*" >&2; exit 1; }

find_bun() {
  if command -v bun >/dev/null 2>&1; then command -v bun; return 0; fi
  [ -x "$ROOT/bin/bun" ] && { printf '%s\n' "$ROOT/bin/bun"; return 0; }
  return 1
}

connect_tool() {
  _bun=$(find_bun) || die "bun is not installed. Re-run the installer, or: datacore doctor"
  _js="${TMPDIR:-/tmp}/datacore-connect.$$.js"
  cat > "$_js" <<'DATACORE_CONNECT_JS'
const { readFileSync, writeFileSync, existsSync, renameSync, chmodSync, mkdirSync, statSync, copyFileSync } = require("fs");
const { dirname, join } = require("path");
const { homedir } = require("os");
const { spawnSync } = require("child_process");
const readline = require("readline");

const [cmd, ...rest] = process.argv.slice(2);
const STATE = process.env.DC_FRONT_DOORS || "";
const ENV_FILE = process.env.DC_ENV_FILE || "";
const BUNDLE_DIR = process.env.DC_BUNDLE_DIR || "";
const COMPOSE_PROJECT = process.env.DC_COMPOSE_PROJECT || "datacore-local";
const DATACORE_BIN = process.env.DC_DATACORE_BIN || "datacore";

// Measured with `agent-list`: the bundle's own front door (Claude Code's) holds exactly these, and so
// does every worker. Nothing wider is needed, so nothing wider is granted.
const SCOPES = "events:read,events:write,facts:read,tasks:read,tasks:write";
const TOOL_BUNDLE = "front_door";

// Clients whose settings file is known, for `--write` without a path. Anything else that runs MCP
// servers from an `mcpServers` map takes the same entry via `--write=<path>`.
const KNOWN_SETTINGS = { muse: join(homedir(), ".config", "muse", "settings.json") };

function die(msg) { process.stderr.write(`${msg}\n`); process.exit(1); }

function readEnv(p) {
  const out = {};
  if (!p || !existsSync(p)) return out;
  for (const line of readFileSync(p, "utf8").split(/\r?\n/)) {
    const m = /^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
  return out;
}

// A corrupt file is reported and left alone: overwriting it would drop every token in it, and the
// Runtime cannot hand a token back -- only reissue it.
function load() {
  if (!existsSync(STATE)) return { version: 1, front_doors: {} };
  let doc;
  try { doc = JSON.parse(readFileSync(STATE, "utf8")); }
  catch (e) { die(`${STATE} is not valid JSON, so it was left untouched: ${e.message}`); }
  const fd = doc && doc.front_doors;
  if (!fd || typeof fd !== "object" || Array.isArray(fd)) die(`${STATE} has no front_doors map, so it was left untouched.`);
  return doc;
}

// Private and atomic: the file holds bearer tokens, and a half-written one would lose all of them.
function save(doc) {
  mkdirSync(dirname(STATE), { recursive: true });
  const tmp = `${STATE}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, STATE);
}

// The Runtime picks a tool bundle by matching the agent id against role rules in order, and the
// first match wins. An id containing "front-door" reaches the front door unless an earlier rule
// claims it, and only one rule comes earlier: the lifecycle/recovery operator's.
function agentIdFor(name) {
  if (!name) die("usage: datacore connect <name> [--model <model>]");
  if (!/^[a-z][a-z0-9-]{0,39}$/.test(name)) {
    die(`'${name}' is not a usable name. Use lower-case letters, digits and hyphens, starting with a letter -- for example: muse, codex, cursor.`);
  }
  if (/lifecycle-operator|recovery-operator/.test(name)) {
    die(`'${name}' would be routed to the lifecycle operator's tools, not the front door. Choose another name.`);
  }
  return name.endsWith("front-door") ? name : `${name}-front-door`;
}

function composeRunner() {
  for (const [bin, lead] of [["docker", ["compose"]], ["docker-compose", []]]) {
    const probe = spawnSync(bin, [...lead, "version"], { stdio: "ignore" });
    if (probe.status === 0) {
      return (args) => spawnSync(bin, [...lead, "-p", COMPOSE_PROJECT, "-f", "docker-compose.yml", ...args], { cwd: BUNDLE_DIR, encoding: "utf8" });
    }
  }
  return null;
}
const runtimeCli = (run, args) => run(["exec", "-T", "runtime", "/app/datacore", ...args]);
function parse(res) {
  for (const text of [`${res.stdout || ""}`, `${res.stderr || ""}`]) {
    const start = text.indexOf("{");
    if (start < 0) continue;
    try { return JSON.parse(text.slice(start)); } catch { /* try the other stream */ }
  }
  return null;
}

function mint(agentId) {
  const run = composeRunner();
  if (!run) die("docker compose is not on PATH, so the Runtime cannot be asked for a credential.");
  let doc = parse(runtimeCli(run, ["agent-create", "--agent-id", agentId, "--scopes", SCOPES]));
  // Left behind by an earlier connect whose file was lost: the Runtime still has the identity but
  // nobody holds its token, and a token cannot be read back -- only reissued.
  if (doc && doc.error && /already exists/i.test(doc.error.message || "")) {
    runtimeCli(run, ["agent-revoke", "--agent-id", agentId]);
    doc = parse(runtimeCli(run, ["agent-create", "--agent-id", agentId, "--scopes", SCOPES]));
  }
  const hint = "\n  The Runtime has to be running to issue a credential. Check: datacore status";
  if (doc && doc.error) die(`The Runtime refused to create ${agentId}: ${doc.error.message || "unknown error"}${hint}`);
  if (!doc || !doc.token) die(`The Runtime returned no credential for ${agentId}.${hint}`);
  return doc.token;
}

function entryFor(name) {
  return { command: DATACORE_BIN, args: ["connect", "serve", name] };
}

// Merge rather than replace: a settings file holds the client's other servers and preferences.
function writeSettings(path, name) {
  let doc = {};
  if (existsSync(path)) {
    try { doc = JSON.parse(readFileSync(path, "utf8") || "{}"); }
    catch (e) { die(`${path} is not valid JSON, so it was left untouched: ${e.message}`); }
    if (!doc || typeof doc !== "object" || Array.isArray(doc)) die(`${path} is not a JSON object, so it was left untouched.`);
    const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "");
    copyFileSync(path, `${path}.bak-${stamp}`);
  }
  const servers = doc.mcpServers && typeof doc.mcpServers === "object" && !Array.isArray(doc.mcpServers) ? doc.mcpServers : {};
  servers.datacore = entryFor(name);
  doc.mcpServers = servers;
  mkdirSync(dirname(path), { recursive: true });
  const mode = existsSync(path) ? statSync(path).mode & 0o777 : 0o644;
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(doc, null, 2) + "\n", { mode });
  renameSync(tmp, path);
  return path;
}

function printConfig(name) {
  const entry = { mcpServers: { datacore: entryFor(name) } };
  console.log("");
  console.log("  The client's MCP settings need this entry. It names a command, not a secret:");
  console.log("");
  for (const line of JSON.stringify(entry, null, 2).split("\n")) console.log(`    ${line}`);
  console.log("");
  if (KNOWN_SETTINGS[name]) console.log(`  Or let this write it: datacore connect ${name} --write`);
  else console.log(`  Or let this write it: datacore connect ${name} --write=<path to the client's settings.json>`);
  console.log("  Then start a new session in the client: MCP servers load when a session starts.");
}

if (cmd === "add") {
  const name = rest[0];
  let model = null;
  let write = null;
  for (let i = 1; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--model") {
      if (!rest[i + 1]) die("--model needs a value, for example: --model muse-spark-1.3");
      model = rest[++i];
    } else if (a.startsWith("--model=")) {
      model = a.slice(8) || die("--model needs a value");
    } else if (a === "--write") {
      write = true;
    } else if (a.startsWith("--write=")) {
      write = a.slice(8) || die("--write= needs a path");
    } else {
      die(`Unknown option: ${a}\n  usage: datacore connect <name> [--model <model>] [--write[=<settings.json>]]`);
    }
  }
  const agentId = agentIdFor(name);
  let settingsPath = null;
  if (write === true) {
    settingsPath = KNOWN_SETTINGS[name] || die(`No known settings file for '${name}'. Give one: --write=<path to the client's settings.json>`);
  } else if (typeof write === "string") {
    settingsPath = write;
  }
  const doc = load();
  const had = doc.front_doors[name];
  if (had) {
    if (model !== null && model !== had.model) { had.model = model; save(doc); }
    console.log(`  ${name} is already connected, as ${had.agent_id}.`);
  } else {
    const token = mint(agentId);
    doc.front_doors[name] = { agent_id: agentId, model, token, created_at: new Date().toISOString() };
    save(doc);
    console.log(`  connected ${name}, as ${agentId}${model ? ` (model: ${model})` : ""}`);
  }
  if (settingsPath) {
    writeSettings(settingsPath, name);
    console.log(`  wrote the datacore entry into ${settingsPath} (the previous file is kept as a .bak)`);
    console.log("  Start a new session in the client: MCP servers load when a session starts.");
  } else {
    printConfig(name);
  }
  process.exit(0);
}

if (cmd === "list") {
  const doc = load();
  const names = Object.keys(doc.front_doors).sort();
  if (!names.length) {
    console.log("  No front doors connected yet. Connect one: datacore connect <name>");
  } else {
    for (const n of names) {
      const fd = doc.front_doors[n];
      console.log(`  ${n.padEnd(16)} ${String(fd.agent_id).padEnd(30)} model: ${fd.model || "the client's choice"}`);
    }
  }
  console.log("  (Claude Code and Claude Desktop are connected by the installer and are not listed here.)");
  process.exit(0);
}

if (cmd === "remove") {
  const name = rest[0];
  const doc = load();
  const had = doc.front_doors[name];
  if (!had) die(`'${name}' is not connected. See: datacore connect list`);
  const run = composeRunner();
  let revoked = false;
  if (run) {
    const res = runtimeCli(run, ["agent-revoke", "--agent-id", had.agent_id]);
    const out = parse(res);
    revoked = res.status === 0 && !(out && out.error);
  }
  delete doc.front_doors[name];
  save(doc);
  console.log(`  removed ${name}${revoked ? ", and revoked its credential" : ""}`);
  if (!revoked) {
    console.log(`  The Runtime could not be reached, so ${had.agent_id} still holds a valid credential there.`);
    console.log("  Once Datacore is running, revoke it from the bundle directory with:");
    console.log(`    docker compose -p ${COMPOSE_PROJECT} exec -T runtime /app/datacore agent-revoke --agent-id ${had.agent_id}`);
  }
  console.log("  Remove the datacore entry from the client's settings as well.");
  process.exit(0);
}

// The MCP server a client runs. stdout is the protocol channel, so every diagnostic goes to stderr
// and nothing else may be printed. One JSON-RPC message per line in, the Runtime's reply out -- the
// same exchange the bundle's own Claude Desktop proxy performs, with the token taken from this
// front door's entry instead of a Claude-only variable.
if (cmd === "serve") {
  const name = rest[0];
  if (!name) die("usage: datacore connect serve <name>");
  const fd = load().front_doors[name];
  if (!fd) die(`'${name}' is not connected. Connect it first: datacore connect ${name}`);
  const port = readEnv(ENV_FILE).DATACORE_HTTP_PORT;
  if (!port) die(`DATACORE_HTTP_PORT is not set in ${ENV_FILE}. Is Datacore installed?`);
  const url = `http://127.0.0.1:${port}/mcp`;
  const headers = {
    Authorization: `Bearer ${fd.token}`,
    "Content-Type": "application/json",
    "X-Datacore-MCP-Tool-Bundle": TOOL_BUNDLE,
  };
  const idOf = (line) => {
    try {
      const m = JSON.parse(line);
      return m && Object.prototype.hasOwnProperty.call(m, "id") ? m.id : undefined;
    } catch { return null; }
  };
  // A request gets an error reply it can match; a notification gets nothing, as the protocol says.
  const fail = (line, message, data) => {
    const id = idOf(line);
    if (id === undefined) return undefined;
    return JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32603, message, data } });
  };
  async function forward(line) {
    const body = line.trim();
    if (!body) return undefined;
    let res;
    try { res = await fetch(url, { method: "POST", headers, body }); }
    catch (e) {
      return fail(body, "Datacore is not reachable. Is it running? Check: datacore status", { detail: String((e && e.message) || e) });
    }
    if (res.status === 202) return undefined;
    const text = await res.text();
    if (!res.ok) return fail(body, `Datacore returned HTTP ${res.status}.`, { status: res.status, body: text.slice(0, 2000) });
    if ((res.headers.get("content-type") || "").includes("text/event-stream")) {
      const data = text.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).filter(Boolean);
      return data.length ? data.join("\n") : undefined;
    }
    return text.trim() || undefined;
  }
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  let chain = Promise.resolve();
  rl.on("line", (line) => {
    chain = chain
      .then(async () => { const out = await forward(line); if (out) process.stdout.write(`${out}\n`); })
      .catch((e) => process.stderr.write(`${(e && e.stack) || e}\n`));
  });
  rl.on("close", () => { chain.then(() => process.exit(0)); });
} else {
  die(`unknown connect command '${cmd}'`);
}
DATACORE_CONNECT_JS
  _rc=0
  DC_FRONT_DOORS="$FRONT_DOORS" DC_ENV_FILE="$ROOT/current/.env" DC_BUNDLE_DIR="$ROOT/current" \
  DC_COMPOSE_PROJECT="$COMPOSE_PROJECT" DC_DATACORE_BIN="$DATACORE_BIN" \
    "$_bun" "$_js" "$@" || _rc=$?
  rm -f "$_js"
  return $_rc
}

usage() {
  cat <<'EOF'
datacore connect — let any AI client be a front door to Datacore

  datacore connect <name> [--model <model>]    connect a client, and show the entry its settings need
      --write                                   write that entry into a known client's settings (muse)
      --write=<settings.json>                   ... or into any client's mcpServers settings file
  datacore connect list                        the clients connected, and the model each was given
  datacore connect remove <name>               disconnect a client and revoke its credential
  datacore connect serve <name>                the MCP server a client runs (named in its settings)

A front door is the AI client you talk to: it reads the briefing, shapes tasks and wakes workers.
Any client that runs MCP servers can be one, with any model it supports. Workers -- the CLIs that do
the work -- are configured separately, with: datacore worker

  datacore connect muse --model muse-spark-1.3 --write
EOF
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  ''|-h|--help|help) usage ;;
  list)   connect_tool list ;;
  remove) [ $# -ge 1 ] || die "usage: datacore connect remove <name>"; connect_tool remove "$@" ;;
  serve)  [ $# -ge 1 ] || die "usage: datacore connect serve <name>";  connect_tool serve "$@" ;;
  -*)     die "Unknown option: $sub. See: datacore connect --help" ;;
  *)      connect_tool add "$sub" "$@" ;;
esac
