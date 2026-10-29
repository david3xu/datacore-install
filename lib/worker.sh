#!/bin/sh
# Datacore worker management — enable, list and disable the AI workers the runtime dispatches to.
#
# Usage: datacore worker add [name] | list | remove <name> | prune
#
# A worker here is an entry in the bundle's generated worker registry. That registry is the only
# list the host worker bridge reads, so enabling a worker means putting it there and disabling one
# means taking it out. Earlier versions of this command wrote its own JSON under
# $DATACORE_HOME/workers, which nothing in the bundle ever read: `worker add` reported success and
# changed nothing. It now edits the registry.
#
# DATACORE_HOME   runtime data directory (default: ~/.datacore-local)

set -eu

ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"

# Prefer the data directory this install actually uses. The old fixed default is shared between
# installs, so reading it blind reports another install's state as if it were this one's.
DATA_HOME="${DATACORE_HOME:-}"
if [ -z "$DATA_HOME" ] && [ -f "$ROOT/current/.env" ]; then
  DATA_HOME=$(grep '^DATACORE_HOME=' "$ROOT/current/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
[ -n "$DATA_HOME" ] || DATA_HOME="$HOME/.datacore-local"
PROVIDERS_DIR="$DATA_HOME/providers"

GEN="$ROOT/current/generated"
REGISTRY="$GEN/azure-worker-registry.json"
CATALOGUE="$GEN/azure-worker-catalogue.json"
BUNDLE_CONFIG="$ROOT/current/support/install-config.js"

# The registry this command edits is the bundle's generated copy, and it is not the only copy.
#
#   $DATA_HOME/runtime/worker-registry.json        the host worker bridge reads this one, and only
#                                                  this one — DATACORE_WORKER_REGISTRY_PATH in its
#                                                  environment points here
#   compose-workspaces/<project>/generated/...     the copy `datacore doctor` compares against the
#                                                  bundle's; when they differ doctor reports a
#                                                  failure, which the installer treats as blocking
#
# Writing one copy and not the others is the whole defect this command was written to fix: it
# printed a new worker list while the bridge kept dispatching from the old one. So every write goes
# to all of them. Copies are mirrored only where they already exist — this never creates one.
RUNTIME_REGISTRY="${DATACORE_WORKER_REGISTRY_PATH:-$DATA_HOME/runtime/worker-registry.json}"
MIRRORS="$RUNTIME_REGISTRY"

# The compose project names the workspace directory. The datacore dispatcher exports it after
# reading COMPOSE_PROJECT_NAME out of the install's .env; resolve it again here so running this
# script directly finds the same workspace the bundle's own scripts use.
COMPOSE_PROJECT="${DATACORE_LOCAL_COMPOSE_PROJECT:-}"
if [ -z "$COMPOSE_PROJECT" ] && [ -f "$ROOT/current/.env" ]; then
  COMPOSE_PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' "$ROOT/current/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
[ -n "$COMPOSE_PROJECT" ] || COMPOSE_PROJECT="datacore-local"
WORKSPACE_REGISTRY="$DATA_HOME/compose-workspaces/$COMPOSE_PROJECT/generated/azure-worker-registry.json"
if [ -f "$WORKSPACE_REGISTRY" ]; then
  MIRRORS="$MIRRORS
$WORKSPACE_REGISTRY"
fi

export DC_REGISTRY_MIRRORS="$MIRRORS"
export DC_RUNTIME_REGISTRY="$RUNTIME_REGISTRY"

# Enabling a worker the install never provisioned needs a Runtime credential, and only the Runtime
# can mint one. It is reachable through the bundle's compose file, so hand the JS the bundle
# directory and the compose project; without a running stack it falls back to telling the user to
# re-run the installer.
export DC_BUNDLE_DIR="$ROOT/current"
export DC_COMPOSE_PROJECT="$COMPOSE_PROJECT"

# A worker in the registry is not yet a worker the Coordinator will dispatch to: dispatch is gated
# on an *executor profile* matching the task's target agent, and the bundle ships a curated example
# list that names claude and codex identities only. Enabling agy therefore produced a worker the
# Runtime reported as live and every dispatch refused with "no executor profile ... matches this
# task". The profiles are uniform apart from the agent they name, so generate them from the registry
# instead of asking the user to hand-write JSON. $DATACORE_HOME/coordinator is already bind-mounted
# into the Coordinator at /var/lib/datacore/coordinator, so the file needs no compose change.
EXECUTORS="$DATA_HOME/coordinator/executors.json"
EXECUTORS_IN_CONTAINER="/var/lib/datacore/coordinator/executors.json"
COORDINATOR_ENV="$GEN/coordinator.env"
export DC_EXECUTORS_PATH="$EXECUTORS"

# ---------------------------------------------------------------- helpers

# Prints every argument, one per line: a die() that printed only "$1" silently dropped the
# explanation lines its callers pass, leaving the user a bare refusal and no remedy.
die()  { while [ $# -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done; exit 1; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

read_field() {
  grep "\"$2\"" "$1" | sed 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/' | sed 's/[[:space:]]*$//'
}

# The bundle's own scripts run on bun, so the installer always places one. Prefer a bun on PATH,
# then the private copy the installer fetched.
find_bun() {
  if command -v bun >/dev/null 2>&1; then command -v bun; return 0; fi
  [ -x "$ROOT/bin/bun" ] && { printf '%s\n' "$ROOT/bin/bun"; return 0; }
  return 1
}

# Which worker CLIs are installed, named the way the bundle's catalogue names them (`cli:`), not the
# way the binary is named — the claude-code families dispatch the `claude` binary.
installed_clis() {
  command -v claude >/dev/null 2>&1 && printf 'claude-code\n'
  command -v codex  >/dev/null 2>&1 && printf 'codex\n'
  command -v agy    >/dev/null 2>&1 && printf 'agy\n'
  command -v muse   >/dev/null 2>&1 && printf 'muse\n'
  return 0
}

# The bridge reads the registry when it starts, so a change while it is running is invisible until
# it restarts. On a minimal install it is not running and there is nothing to do.
# generated/ exists twice for the same reason the registry does: the install mirrors it into the
# compose workspace, and `datacore doctor` compares the two and fails when they differ. Anything
# this script changes under generated/ therefore has to be mirrored, or enabling a worker leaves a
# blocking doctor failure behind.
mirror_generated_file() {
  _name=$1
  _copy="$DATA_HOME/compose-workspaces/$COMPOSE_PROJECT/generated/$_name"
  [ -f "$_copy" ] || return 0
  cp "$GEN/$_name" "$_copy" 2>/dev/null || { warn "could not mirror $_name into the compose workspace"; return 0; }
  chmod 600 "$_copy" 2>/dev/null || true
}

# The Coordinator reads its executor profiles from DATACORE_EXECUTOR_CONFIG_PATH, which the bundle
# points at an example file baked into the image. Repoint it at the generated one, but only while it
# still names that example: an operator who has curated their own list keeps it.
point_coordinator_at_generated_executors() {
  [ -f "$COORDINATOR_ENV" ] || return 0
  # Repointing at a file with no profiles in it is worse than leaving the bundle example in
  # place: the Coordinator loads zero executors and doctor fails executor_config:has_entries,
  # on an install whose only fault is that no worker is enabled yet. Wait until there is at
  # least one profile to point at; enabling a worker comes back through here.
  grep -q '"executor_id"' "$EXECUTORS" 2>/dev/null || return 0
  _cur=$(grep '^DATACORE_EXECUTOR_CONFIG_PATH=' "$COORDINATOR_ENV" 2>/dev/null | head -1 | cut -d= -f2-)
  case "$_cur" in
    "$EXECUTORS_IN_CONTAINER") return 0 ;;                      # already ours
    *executors.host-bridge.example.json|"") ;;                  # the bundle default, or unset
    *) warn "leaving DATACORE_EXECUTOR_CONFIG_PATH at $_cur (not the bundle default)"; return 0 ;;
  esac
  _tmp="$COORDINATOR_ENV.tmp.$$"
  if [ -n "$_cur" ]; then
    sed "s|^DATACORE_EXECUTOR_CONFIG_PATH=.*|DATACORE_EXECUTOR_CONFIG_PATH=$EXECUTORS_IN_CONTAINER|" "$COORDINATOR_ENV" > "$_tmp"
  else
    cat "$COORDINATOR_ENV" > "$_tmp"
    printf 'DATACORE_EXECUTOR_CONFIG_PATH=%s\n' "$EXECUTORS_IN_CONTAINER" >> "$_tmp"
  fi
  # coordinator.env holds the Runtime bearer token, so keep the private mode across the swap.
  chmod 600 "$_tmp" 2>/dev/null || true
  mv "$_tmp" "$COORDINATOR_ENV"
  mirror_generated_file coordinator.env
  COORDINATOR_ENV_REPOINTED=1
}

# Executor profiles are read when the Coordinator starts, so a change is invisible until it does.
# An env_file change needs a recreate rather than a restart, which is why both paths exist.
restart_coordinator_if_needed() {
  [ -f "$EXECUTORS.changed" ] || [ "${COORDINATOR_ENV_REPOINTED:-0}" = 1 ] || return 0
  rm -f "$EXECUTORS.changed"
  _compose=''
  if docker compose version >/dev/null 2>&1; then _compose='docker compose'
  elif docker-compose version >/dev/null 2>&1; then _compose='docker-compose'
  else
    warn "executor profiles written, but no docker compose to restart the Coordinator — run: datacore restart"
    return 0
  fi
  if [ "${COORDINATOR_ENV_REPOINTED:-0}" = 1 ]; then
    _action='up -d coordinator'          # env_file changed: recreate so it is re-read
  else
    _action='restart coordinator'        # only the profiles changed
  fi
  if ! (cd "$ROOT/current" && $_compose -p "$COMPOSE_PROJECT" -f docker-compose.yml $_action >/dev/null 2>&1); then
    warn "could not restart the Coordinator — run: datacore restart"
    return 0
  fi
  # Restarting is not the same as succeeding. If the profiles were never written -- the
  # directory is a bind-mount target and can be root-owned -- the Coordinator silently falls
  # back to the example list in the image, and claiming success here hides that completely.
  if [ -f "$EXECUTORS" ] && grep -q '"executor_id"' "$EXECUTORS" 2>/dev/null; then
    ok "updated the Coordinator's executor profiles so these workers can be dispatched to"
  else
    warn "the Coordinator restarted, but no executor profiles reached $EXECUTORS"
    warn "it is still dispatching from the example list in the image; enabled workers outside that list will not be reached"
  fi
}

restart_bridge_if_running() {
  _stop="$ROOT/current/stop-host-worker-bridge.sh"
  _start="$ROOT/current/start-host-worker-bridge.sh"
  [ -x "$_stop" ] && [ -x "$_start" ] || return 0
  pgrep -f 'host-worker-bridge' >/dev/null 2>&1 || return 0
  # Remember which bridge processes exist now. "A bridge is running" afterwards is not proof of a
  # restart: a stale bridge the stop script failed to kill -- including one from an older version
  # -- would satisfy it while the new one never came up with the change we just wrote.
  _pids_before=$(pgrep -f 'host-worker-bridge' 2>/dev/null | tr '\n' ' ')
  if ! (cd "$ROOT/current" && "$_stop" >/dev/null 2>&1 && "$_start" >/dev/null 2>&1); then
    warn "could not restart the worker bridge — run: datacore restart"
    return 0
  fi
  # The start script backgrounds the bridge and returns 0 before it is up, so ask the process
  # table instead. A bridge that exits on a bad config would otherwise be reported as restarted.
  _waited=0
  while [ "$_waited" -lt 10 ]; do
    for _pid in $(pgrep -f 'host-worker-bridge' 2>/dev/null); do
      case " $_pids_before " in
        *" $_pid "*) ;;                 # one of the old ones, still around
        *) ok "restarted the worker bridge so it picks up the change"; return 0 ;;
      esac
    done
    sleep 1
    _waited=$((_waited + 1))
  done
  warn "the worker bridge did not come back after 10s"
  if pgrep -f 'host-worker-bridge' >/dev/null 2>&1; then
    warn "an older bridge process is still running and did not pick up the change"
  fi
  warn "check it with: datacore doctor    then: datacore restart"
}

# ---------------------------------------------------------------- the registry program
#
# JSON surgery in POSIX sh is not worth attempting, and python3 is not guaranteed on a user's
# machine, so this runs on the bun the installer always places. The program is embedded rather than
# shipped as a separate lib/ file because the lib/ files are fetched from a release: a new file is
# missing from every release cut before it existed, and `worker add` must not break for that.

registry_tool() {
  _bun=$(find_bun) || die "bun is not installed. Re-run the installer, or: datacore doctor"
  [ -f "$REGISTRY" ] || die "No worker registry at $REGISTRY.
  It is written when Datacore is installed; re-run the installer if it is missing."
  _js="${TMPDIR:-/tmp}/datacore-worker-registry.$$.js"
  cat > "$_js" <<'DATACORE_REGISTRY_JS'
// Datacore worker registry surgery. Invoked by `datacore worker` and by install.sh.
//
// Two files, one directory:
//   azure-worker-registry.json   the ENABLED workers — the only list the runtime dispatches to
//   azure-worker-catalogue.json  every worker the bundle minted a token for
//
// The bundle writes the registry as the full cartesian product of CLI x model alias x role: 29
// entries on a stock install, 14 of them for a CLI (agy) its own catalogue flags as out of the
// default profile. Nobody needs 29. This keeps the full set in the catalogue, which is where
// `enable` takes tokens from, and leaves the registry holding only what was asked for.
const { readFileSync, writeFileSync, existsSync, chmodSync } = require("fs");
const { spawnSync } = require("child_process");
const { mkdirSync } = require("fs");
const { dirname } = require("path");

const [cmd, registryPath, cataloguePath, configPath, ...rest] = process.argv.slice(2);

const read = (p) => JSON.parse(readFileSync(p, "utf8"));
const write = (p, doc) => {
  writeFileSync(p, JSON.stringify(doc, null, 2) + "\n", "utf8");
  try { chmodSync(p, 0o600); } catch {}
};

// The copies of the registry that have to move together with the one being edited: the runtime copy
// the bridge dispatches from, and the compose workspace copy doctor compares. The shell works out
// which of them exist; writing only the bundle's copy is the failure mode this command exists to
// fix, because it reports success and changes nothing that dispatches.
const RUNTIME = process.env.DC_RUNTIME_REGISTRY || "";
const MIRRORS = (process.env.DC_REGISTRY_MIRRORS || "")
  .split("\n")
  .map((p) => p.trim())
  .filter((p) => p && p !== registryPath && existsSync(p));

function writeRegistry(doc) {
  write(registryPath, doc);
  for (const p of MIRRORS) write(p, doc);
  writeExecutors(doc);
}

// ---- executor profiles --------------------------------------------------------------------------
//
// The Coordinator refuses to dispatch a task unless an executor profile matches its target agent,
// and the bundle ships a curated example list naming claude and codex identities only. A worker
// enabled outside that list is live in the Runtime and undispatchable in practice:
//
//   "reason": "no executor profile in the current capability projection matches this task"
//
// The profiles are identical apart from the agent they name, the phases they serve and the MCP tool
// bundle that follows from those phases, so derive them from the registry. Everything else is
// copied from the bundle's own example, including the pull dispatch mode that makes the host bridge
// claim the intent rather than the Coordinator running a command itself.
const EXECUTORS_PATH = process.env.DC_EXECUTORS_PATH || "";
const HOST_BRIDGE_COMMAND = ["/bin/sh", "/opt/datacore-platform/deploy/workers/ai-team/dispatch-via-host-bridge.sh"];
const EXECUTOR_ENV_ALLOWLIST = [
  "DATACORE_RUNTIME_BEARER_TOKEN",
  "DATACORE_WORKER_BRIDGE_TOKEN",
  "DATACORE_WORKER_BRIDGE_URL",
  "WORKER_RUNTIME_TOKEN",
  "WORKER_RUNTIME_URL",
];

function writeExecutors(doc) {
  if (!EXECUTORS_PATH) return;
  const workers = (doc.workers || []).filter((w) => !isInfra(w));
  // assertReviewerIsolation rejects one agent serving both sides, so review and implementation
  // stay separate profiles — which they already are, being separate families.
  const isReview = (w) => (w.phases || []).every((p) => p === "review");
  let defaultImpl = true;
  let defaultReview = true;
  const profiles = workers.map((w) => {
    const review = isReview(w);
    const profile = {
      executor_id: String(w.agent_id).replace("@", "-"),
      mode: "cli",
      target_agent: w.agent_id,
      dispatch_mode: "pull",
      mcp_tool_bundles: [review ? "review_worker" : "implementation_worker"],
      phases: [...(w.phases || [])],
      command: [...HOST_BRIDGE_COMMAND],
      env_allowlist: [...EXECUTOR_ENV_ALLOWLIST],
      timeout_seconds: 30,
      retry_budget: 1,
      max_parallelism: 1,
      working_directory: ".",
    };
    // One default per side, so a task that names no target still has somewhere to go. First wins,
    // and the registry order is the bundle's own family order.
    if (review && defaultReview) { profile.is_default = true; defaultReview = false; }
    if (!review && defaultImpl) { profile.is_default = true; defaultImpl = false; }
    return profile;
  });
  try {
    mkdirSync(dirname(EXECUTORS_PATH), { recursive: true });
    const next = JSON.stringify(profiles, null, 2) + "\n";
    const prev = existsSync(EXECUTORS_PATH) ? readFileSync(EXECUTORS_PATH, "utf8") : "";
    if (prev === next) return;
    writeFileSync(EXECUTORS_PATH, next, "utf8");
    // A stamp rather than a printed marker: the shell reads it to decide whether the Coordinator
    // needs restarting, and a marker on stdout would have to be filtered back out of the output the
    // user sees. The shell removes it either way, so it never accumulates.
    writeFileSync(`${EXECUTORS_PATH}.changed`, "", "utf8");
  } catch (err) {
    // Docker creates a missing bind-mount source as root, so on an install that started
    // containers before this directory existed, nothing running as the user can write here.
    // Say what to do about it: a silent failure here means the Coordinator keeps dispatching
    // from the example list in the image and every worker outside it is quietly unreachable.
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`  ! could not write executor profiles to ${EXECUTORS_PATH}: ${msg}`);
    if (/EACCES|EPERM/.test(msg)) {
      console.error(`  ! ${dirname(EXECUTORS_PATH)} is not writable by you — Docker created it as root.`);
      console.error(`  ! fix it with:  sudo chown -R "$(id -u):$(id -g)" ${dirname(EXECUTORS_PATH)}`);
      console.error("  ! then run:     datacore worker sync");
    }
    console.error("  ! until then the Coordinator dispatches from the example list in the image,");
    console.error("  ! and enabled workers outside that list will not be reached.");
  }
}

// ---- provisioning a worker the install never minted a credential for --------------------------
//
// The install generates the registry from the default profile only, so a family the bundle flags
// `inDefaultProfile: false` (agy) has no token and cannot be enabled. The old answer was "re-run
// the whole installer with DATACORE_LOCAL_FULL_WORKER_REGISTRY=1", which re-mints every catalogued
// identity — 29 of them — to use one. The Runtime can mint a single credential on request, so ask
// it: `agent-create` through the bundle's compose file, the same call the installer makes.
const WORKER_SCOPES = "events:read,events:write,facts:read,tasks:read,tasks:write";
const BUNDLE_DIR = process.env.DC_BUNDLE_DIR || "";
const COMPOSE_PROJECT = process.env.DC_COMPOSE_PROJECT || "datacore-local";

function composeRunner() {
  // `docker compose` on anything current, `docker-compose` on older installs. The bundle has a
  // third path for machines with neither, but it is for bringing a stack up, not for talking to
  // one that is already running, so a missing binary here means "cannot mint", not "try harder".
  for (const [bin, lead] of [["docker", ["compose"]], ["docker-compose", []]]) {
    const probe = spawnSync(bin, [...lead, "version"], { stdio: "ignore" });
    if (probe.status === 0) return (args) => spawnSync(bin, [...lead, "-p", COMPOSE_PROJECT, "-f", "docker-compose.yml", ...args], { cwd: BUNDLE_DIR, encoding: "utf8" });
  }
  return null;
}

function runtimeCli(run, args) {
  return run(["exec", "-T", "runtime", "/app/datacore", ...args]);
}

function mintToken(run, agentId) {
  // The Runtime CLI prints its JSON to stdout on success and to stderr on a refusal, so read both
  // rather than guessing: "already exists" is a refusal this function has to recognise and handle.
  const parse = (res) => {
    for (const text of [`${res.stdout || ""}`, `${res.stderr || ""}`]) {
      const start = text.indexOf("{");
      if (start < 0) continue;
      try { return JSON.parse(text.slice(start)); } catch { /* try the other stream */ }
    }
    return null;
  };
  let doc = parse(runtimeCli(run, ["agent-create", "--agent-id", agentId, "--scopes", WORKER_SCOPES]));
  // An identity left behind by an earlier install still exists in the Runtime but its token was
  // never written here, and a token cannot be read back — only reissued. This is the installer's
  // own behaviour for the same case.
  if (doc?.error && /already exists/i.test(doc.error.message || "")) {
    runtimeCli(run, ["agent-revoke", "--agent-id", agentId]);
    doc = parse(runtimeCli(run, ["agent-create", "--agent-id", agentId, "--scopes", WORKER_SCOPES]));
  }
  if (doc?.error) throw new Error(doc.error.message || "agent-create failed");
  if (!doc?.token) throw new Error("the Runtime returned no token");
  return doc.token;
}

// The entry the bundle would have written for this family, had the family been in the default
// profile. agy has no defaultModelAlias — the hosted manifest does not name one — so fall back to
// the first alias the bundle lists, which is what the full registry used to enable.
function provisionEntries(run, known, selAlias) {
  const made = [];
  for (const [fam, meta] of known) {
    const alias = selAlias || meta.defaultAlias || meta.aliases[0];
    if (!alias) throw new Error(`${fam} lists no model alias to enable`);
    if (selAlias && !meta.aliases.includes(selAlias)) {
      throw new Error(`${fam} has no model '${selAlias}'. It lists: ${meta.aliases.join(", ")}`);
    }
    const agentId = `${fam}@${alias}`;
    made.push({ cli: meta.cli, model_alias: alias, agent_id: agentId, phases: [...meta.phases], token: mintToken(run, agentId) });
  }
  return made;
}
// The bridge dispatches by phase, so an entry with no phases is an identity rather than a dispatch
// target: the MCP operator is one, and it carries cli:"claude-code" like any worker, so testing the
// cli field would drop it and take the client's MCP token with it. Phases are the real distinction.
// Identities are never candidates for enable/disable and are never pruned.
const isInfra = (w) => !(w.phases || []).length;
const familyOf = (w) => String(w.agent_id || "").split("@")[0];
const die = (m) => { console.error(m); process.exit(1); };

// The bundle's own catalogue of worker families, read out of its minified config. This is the
// source of truth for which families are in the default profile and which alias each one defaults
// to; hardcoding either here would drift from the bundle on every release.
function families(path) {
  const out = new Map();
  if (!path || !existsSync(path)) return out;
  const s = readFileSync(path, "utf8");
  // The alias list for a family is a reference to a shared array, so collect those first. The file
  // is minified, which makes the names meaningless but the shape stable: `X=["opus","sonnet",...]`,
  // several per `var` statement.
  const arrays = new Map();
  for (const m of s.matchAll(/(\w+)=\[((?:"[^"]*",?)+)\]/g)) {
    arrays.set(m[1], m[2].split(",").map((x) => x.replace(/^"|"$/g, "")).filter(Boolean));
  }
  for (const m of s.matchAll(/agentFamily:"([^"]+)"/g)) {
    const seg = s.slice(m.index, m.index + 2000);
    const pick = (re) => (seg.match(re) || [])[1];
    const aliasRef = pick(/modelAliases:(\w+)/);
    const phaseList = (seg.match(/phases:\[([^\]]*)\]/) || [])[1];
    out.set(m[1], {
      cli: pick(/cli:"([^"]+)"/),
      defaultAlias: pick(/defaultModelAlias:"([^"]+)"/),
      inDefault: /inDefaultProfile:(?:!0|true)/.test(seg),
      aliases: (aliasRef && arrays.get(aliasRef)) || [],
      // Needed to build a registry entry for a family the install never provisioned: the bridge
      // dispatches by phase, and an entry with no phases is read as an identity, not a worker.
      phases: phaseList ? phaseList.split(",").map((x) => x.replace(/^"|"$/g, "")).filter(Boolean) : [],
    });
  }
  return out;
}

// Families the bundle knows about that this install has no token for. The registry generator writes
// the default profile only, so these exist in the catalog but were never provisioned — enabling one
// needs a token, which only the installer mints.
function unprovisioned(fams, catalogue) {
  const have = new Set(catalogue.filter((w) => w.token).map((w) => familyOf(w)));
  const out = [];
  for (const [fam, meta] of fams) if (!have.has(fam)) out.push([fam, meta]);
  return out;
}

// Pick one entry per family: the family's default alias when the catalogue names one and that
// alias exists, else the first entry the bundle listed for the family.
function onePerFamily(workers, fams, wantCli) {
  const chosen = [];
  const seen = new Set();
  for (const w of workers) {
    const fam = familyOf(w);
    if (seen.has(fam)) continue;
    const meta = fams.get(fam) || {};
    if (wantCli && !wantCli(w, meta, fam)) continue;
    const want = meta.defaultAlias;
    const pick = (want && workers.find((x) => familyOf(x) === fam && x.model_alias === want)) || w;
    seen.add(fam);
    chosen.push(pick);
  }
  return chosen;
}

const summarise = (ws) => {
  const dispatch = ws.filter((w) => !isInfra(w));
  for (const w of dispatch) console.log(`    ${w.agent_id}  [${(w.phases || []).join(", ")}]`);
  return dispatch.length;
};

if (!cmd || !registryPath) die("usage: worker-registry <prune|enable|disable|list> <registry> <catalogue> <config> [args]");
if (!existsSync(registryPath)) die(`no worker registry at ${registryPath}`);

const registry = read(registryPath);
registry.workers = registry.workers || [];

// The catalogue is seeded from the registry the first time, before anything is pruned away, so the
// full minted set survives. Later runs keep whichever is larger: an upgrade rewrites the registry
// with all 29 again, and that must not shrink a catalogue, nor lose a token the registry alone has.
let catalogue = existsSync(cataloguePath) ? read(cataloguePath) : { ...registry, workers: [] };
catalogue.workers = catalogue.workers || [];
{
  const byId = new Map(catalogue.workers.map((w) => [w.agent_id, w]));
  for (const w of registry.workers) if (!byId.has(w.agent_id)) byId.set(w.agent_id, w);

  // And whatever the previous install had. Both the registry and the catalogue live in
  // $ROOT/current/generated, which belongs to the *versioned* bundle directory, so an upgrade
  // starts with neither: the catalogue is reseeded from the new bundle's minted set alone.
  //
  // That set is small. The bundle mints claude-code and codex only; `worker add agy` and
  // `worker add muse` PROVISION an identity, token and all, that no later bundle re-mints. So
  // after an upgrade those identities existed nowhere the code looked, and `prune` -- which
  // iterates the catalogue -- could not keep a family that was no longer in it. Measured on a
  // real 0.1.79 -> 0.1.80 upgrade: the catalogue came back with 5 entries, none of them agy,
  // and the agy worker the user had enabled was dropped whatever the predicate said.
  //
  // The mirror under $DATACORE_HOME is outside the bundle and carries the full entry, including
  // the token, so it is the one place a provisioned identity survives. Merge it back in.
  const priorRegistryPath = process.env.DATACORE_WORKER_PRIOR_REGISTRY || "";
  let recovered = 0;
  if (priorRegistryPath && existsSync(priorRegistryPath)) {
    try {
      for (const w of read(priorRegistryPath).workers || []) {
        if (!w || !w.agent_id || byId.has(w.agent_id)) continue;
        byId.set(w.agent_id, w);
        recovered += 1;
      }
    } catch {
      // Unreadable prior registry: carry nothing forward rather than fail an install.
    }
  }
  if (recovered) console.log(`  recovered ${recovered} worker identity/identities from the previous install`);

  catalogue.workers = [...byId.values()];
  if (cataloguePath) write(cataloguePath, catalogue);
}

const fams = families(configPath);

if (cmd === "sync") {
  // Executor profiles are a pure function of the registry, but they used to be written only as a
  // side effect of writeRegistry() -- so an install whose registry came from the bundle's own
  // generator produced none at all, the Coordinator fell back to the example list baked into the
  // image, and every worker outside that list was undispatchable. Regenerating them from whatever
  // the registry currently says makes the two consistent no matter how the registry got there.
  writeExecutors(registry);
  const n = (registry.workers || []).filter((w) => !isInfra(w)).length;
  console.log(`  executor profiles synced for ${n} worker(s)`);
  process.exit(0);
}

if (cmd === "list") {
  // Report against the copy the bridge actually reads. A mismatch between the two means something
  // wrote one without the other — the bundle regenerating its copy on upgrade, or an older version
  // of this command — and it shows up as workers that are listed but never dispatched to.
  const ids = (ws) => new Set(ws.filter((w) => !isInfra(w)).map((w) => w.agent_id));
  const mine = ids(registry.workers);
  const stale = MIRRORS.filter((p) => {
    try {
      const theirs = ids(read(p).workers || []);
      return theirs.size !== mine.size || [...mine].some((x) => !theirs.has(x));
    } catch { return false; }
  });
  if (stale.length) {
    console.log("  ! another copy of the registry disagrees with this one:");
    for (const p of stale) console.log(`    ${p}${p === RUNTIME ? "   (the bridge dispatches from this one)" : ""}`);
    console.log("    Run: datacore worker prune   (rewrites every copy)");
  }
  const enabled = summarise(registry.workers);
  const avail = catalogue.workers.filter((w) => !isInfra(w) && w.token).length - enabled;
  console.log(`  ${enabled} enabled, ${avail} more available (datacore worker add <name>)`);
  const missing = unprovisioned(fams, catalogue.workers);
  if (missing.length) {
    console.log(`  ${missing.length} family/families this install has no token for:`);
    for (const [fam, meta] of missing) {
      const aliases = meta.aliases.length ? `${meta.aliases.length} model(s)` : "no models listed";
      console.log(`    ${fam}  (${meta.cli || "unknown cli"}, ${aliases})`);
    }
    console.log("  `datacore worker add <name>` provisions one of these for you.");
  }
  process.exit(0);
}

if (cmd === "prune") {
  // rest = CLI binaries that resolve on this machine, as the family `cli` names them.
  const present = new Set(rest.filter(Boolean));

  // Families the user went out of their way to enable. install.sh runs `prune` on EVERY install,
  // upgrades included, and an upgrade re-mints the registry with the full set -- so a prune that
  // keeps only default-profile families deleted, on every upgrade, exactly the workers somebody
  // had chosen. All four opt-in families were affected (agy, agy-review, muse-worker,
  // muse-review): `datacore worker add muse` worked, dispatched, and was gone after the next
  // install with nothing printed. A success message for work later undone.
  //
  // The pre-upgrade registry is unrecoverable from the bundle (generated/ belongs to the new
  // version), but its mirror under $DATA_HOME is written by writeRegistry() and persists, so it
  // still holds the curated set at the moment prune runs. An entry with no phases is an identity
  // rather than a dispatch target, so it is not a choice. A fresh install has no mirror and this
  // set is empty, which is exactly the old behaviour.
  const priorPath = process.env.DATACORE_WORKER_PRIOR_REGISTRY || "";
  const chosen = new Set();
  if (priorPath && existsSync(priorPath)) {
    try {
      for (const w of read(priorPath).workers || []) {
        if (isInfra(w) || !(w.phases || []).length) continue;
        const fam = String(w.agent_id || "").split("@")[0];
        if (fam) chosen.add(fam);
      }
    } catch {
      // An unreadable mirror must not stop an install. Falling through leaves `chosen` empty,
      // which prunes to the default profile -- the conservative answer, and what it did before.
    }
  }

  const keep = onePerFamily(catalogue.workers, fams, (w, meta, fam) => {
    if (isInfra(w)) return false;
    // The default profile, or an explicit choice. A choice outranks the default: the user asked.
    if (!meta.inDefault && !chosen.has(fam)) return false;
    return present.has(meta.cli || w.cli);          // and the CLI has to actually be installed
  });
  registry.workers = [...catalogue.workers.filter(isInfra), ...keep];
  writeRegistry(registry);
  const n = summarise(registry.workers);
  console.log(`  ${n} worker(s) enabled of ${catalogue.workers.filter((w) => !isInfra(w)).length} the bundle minted`);
  process.exit(0);
}

if (cmd === "enable" || cmd === "disable") {
  const sel = rest[0];
  if (!sel) die(`usage: datacore worker ${cmd === "enable" ? "add" : "remove"} <cli|family|family@alias>`);
  const [selName, selAlias] = sel.split("@");
  // The catalogue calls Claude Code's CLI `claude-code`, but every surface a user reads calls it
  // `claude`: the install summary says "no worker CLI installed (claude, codex, agy)", doctor
  // reports bridge_dispatch:launcher:claude, and `claude` is what they typed to install it. So
  // `datacore worker add claude` has to work, and before this map it died with
  // "No worker matches 'claude'" while `add codex` worked -- because codex's binary and catalogue
  // name happen to be the same string. This is the twin of the `case` that resolves _bin in the
  // shell half of this file; the CI job "the worker selector accepts the names users are shown"
  // asserts the two agree.
  const CLI_BIN = { "claude-code": "claude", codex: "codex", agy: "agy", muse: "muse" };
  // A selector names a CLI (codex, claude), a family (codex-review) or one exact worker
  // (codex-review@gpt-6-luna).
  const matches = (w) => {
    const fam = familyOf(w);
    const meta = fams.get(fam) || {};
    const cli = meta.cli || w.cli;
    const hit = fam === selName || cli === selName || w.cli === selName || CLI_BIN[cli] === selName;
    return hit && (!selAlias || w.model_alias === selAlias);
  };

  if (cmd === "disable") {
    const before = registry.workers.length;
    registry.workers = registry.workers.filter((w) => isInfra(w) || !matches(w));
    if (registry.workers.length === before) die(`Nothing enabled matches '${sel}'. Run: datacore worker list`);
    writeRegistry(registry);
    console.log(`  removed ${before - registry.workers.length} worker(s)`);
    summarise(registry.workers);
    process.exit(0);
  }

  const pool = catalogue.workers.filter((w) => !isInfra(w) && matches(w) && w.token);
  if (!pool.length) {
    // Distinguish "the bundle has never heard of this" from "the bundle knows it but this install
    // has no token for it". The second is the common case for a family outside the default profile,
    // and it has a specific remedy, so saying "no worker matches" would be actively misleading.
    const known = [...fams].filter(([fam, meta]) => fam === selName || meta.cli === selName);
    if (known.length) {
      const aliasNote = known
        .map(([fam, meta]) => `${fam} (${meta.aliases.join(", ") || "no models listed"})`)
        .join("\n    ");
      // No token for this family, because the install provisions the default profile only. Mint
      // one rather than sending the user back through the installer: a credential per worker is
      // what the installer would have done, and doing it here provisions exactly the one asked
      // for instead of all 29.
      const run = BUNDLE_DIR ? composeRunner() : null;
      if (!run) {
        die(
          `'${sel}' is a worker Datacore knows, but this install has no credential for it,\n` +
            `  and the Runtime is not reachable to mint one (no docker compose on PATH).\n\n` +
            `  Start the stack and try again:  datacore start\n\n  Matched:\n    ${aliasNote}`,
        );
      }
      let made;
      try {
        made = provisionEntries(run, known, selAlias);
      } catch (err) {
        die(
          `Could not provision '${sel}': ${err instanceof Error ? err.message : String(err)}\n\n` +
            `  The Runtime has to be running to mint a worker credential. Check: datacore status\n` +
            `  If it is running, the installer can still provision every catalogued model:\n\n` +
            `    DATACORE_LOCAL_FULL_WORKER_REGISTRY=1 datacore update\n\n  Matched:\n    ${aliasNote}`,
        );
      }
      // Keep the new credentials in the catalogue too, so removing and re-adding the worker later
      // does not mint a second one — the catalogue is where `add` takes tokens from.
      const catalogueHave = new Set(catalogue.workers.map((w) => w.agent_id));
      catalogue.workers = [...catalogue.workers, ...made.filter((w) => !catalogueHave.has(w.agent_id))];
      write(cataloguePath, catalogue);
      const registryHave = new Set(registry.workers.map((w) => w.agent_id));
      const fresh = made.filter((w) => !registryHave.has(w.agent_id));
      registry.workers = [...registry.workers, ...fresh];
      writeRegistry(registry);
      console.log(`  provisioned ${made.length} credential(s) and enabled ${fresh.length} worker(s)`);
      summarise(registry.workers);
      process.exit(0);
    }
    // List the CLI names too. Listing families only sent a user who typed a CLI name away with a
    // list that did not contain the thing they should have typed instead.
    const live = catalogue.workers.filter((w) => !isInfra(w));
    const names = [...new Set(live.map((w) => familyOf(w)))];
    const clis = [...new Set(live.flatMap((w) => {
      const cli = (fams.get(familyOf(w)) || {}).cli || w.cli;
      return [cli, CLI_BIN[cli]].filter(Boolean);
    }))];
    die(
      `No worker matches '${sel}'.\n` +
        `  By CLI:    ${clis.join(", ")}\n` +
        `  By family: ${names.join(", ")}\n` +
        `  Or one exact model, e.g. ${names[0]}@<model>  (see: datacore worker list)`,
    );
  }
  // Without an explicit alias, take one worker per family rather than every alias of it — the
  // whole point of this file is that `add codex` must not put eight more workers in the registry.
  const add = selAlias ? pool : onePerFamily(pool, fams);
  const have = new Set(registry.workers.map((w) => w.agent_id));
  const fresh = add.filter((w) => !have.has(w.agent_id));
  if (!fresh.length) { console.log(`  already enabled: ${add.map((w) => w.agent_id).join(", ")}`); process.exit(0); }
  registry.workers = [...registry.workers, ...fresh];
  writeRegistry(registry);
  console.log(`  enabled ${fresh.length} worker(s)`);
  summarise(registry.workers);
  process.exit(0);
}

die(`unknown command '${cmd}'`);
DATACORE_REGISTRY_JS
  # Variadic on purpose: `prune` takes one argument per installed CLI, and on a machine with none
  # it takes zero. Positional "$2" "$3" "$4" would trip `set -u` in exactly that case.
  _cmd="$1"; shift
  _rc=0
  # The mirror under $DATA_HOME is the only copy of the *enabled* set that survives an
  # upgrade: $ROOT/current is a symlink to a versioned bundle dir, so generated/ (and the
  # registry in it) is newly minted by every install. `prune` needs it to tell a worker the
  # user chose from one the bundle merely minted. Passed by environment because `prune` is
  # variadic over installed CLIs, so a fifth positional would be read as a CLI name.
  DATACORE_WORKER_PRIOR_REGISTRY="$RUNTIME_REGISTRY" \
  "$_bun" "$_js" "$_cmd" "$REGISTRY" "$CATALOGUE" "$BUNDLE_CONFIG" "$@" || _rc=$?
  rm -f "$_js"
  return $_rc
}

# ---------------------------------------------------------------- subcommand: add

cmd_add() {
  sel="${1:-}"

  if [ -z "$sel" ]; then
    say "Enabled now:"
    registry_tool list
    say ""
    _found=$(installed_clis | tr '\n' ' ')
    if [ -n "$_found" ]; then
      say "Worker CLIs installed on this machine: $_found"
      say "  Enable one:  datacore worker add codex"
    else
      say "No worker CLI found on this machine (looked for: claude, codex, agy, muse)."
      say "  Install one, then: datacore worker add <name>"
    fi
    say "  One model API:  datacore provider add meta"
    return 0
  fi

  # Enabling a worker whose CLI is absent is allowed — a machine can be prepared before the tool is
  # installed — but it will not dispatch until the binary resolves, so say so rather than imply
  # the worker is ready.
  _cli=$(printf '%s' "$sel" | cut -d@ -f1)
  case "$_cli" in
    claude-code|claude-worker|claude-review) _bin=claude ;;
    codex|codex-worker|codex-review)         _bin=codex ;;
    agy|agy-review)                          _bin=agy ;;
    muse|muse-worker|muse-review)            _bin=muse ;;
    *)                                       _bin='' ;;
  esac

  registry_tool enable "$sel" || exit $?
  if [ -n "$_bin" ] && ! command -v "$_bin" >/dev/null 2>&1; then
    warn "the '$_bin' command is not on PATH, so nothing will be dispatched to it yet"
  fi
  point_coordinator_at_generated_executors
  restart_coordinator_if_needed
  restart_bridge_if_running
  say "  Run: datacore worker list"
}

# ---------------------------------------------------------------- subcommand: list

cmd_list() {
  say "Workers the runtime will dispatch to:"
  registry_tool list

  if [ -d "$PROVIDERS_DIR" ]; then
    _any=0
    for _c in "$PROVIDERS_DIR"/*.json; do
      [ -f "$_c" ] || continue
      [ "$_any" = 0 ] && { say ""; say "Model API providers:"; _any=1; }
      printf '    %-18s model=%s\n' "$(read_field "$_c" name)" "$(read_field "$_c" model)"
    done
  fi

  # Two things gate dispatch besides the registry, and both are quiet failures, so name them here
  # rather than let the user discover an enabled worker that never picks anything up.
  say ""
  say "  Before anything is dispatched: the worker's CLI must resolve on PATH"
  say "  (check: datacore doctor), and the task's project must be mapped to a repository"
  say "  (check: datacore project list, map: datacore project link <project> <path>)."
}

# ---------------------------------------------------------------- subcommand: remove

cmd_remove() {
  _name="${1:-}"
  [ -n "$_name" ] || { say "Usage: datacore worker remove <name>" >&2; exit 2; }
  registry_tool disable "$_name" || exit $?
  point_coordinator_at_generated_executors
  restart_coordinator_if_needed
  restart_bridge_if_running
  say "  Run: datacore worker list"
}

# ---------------------------------------------------------------- subcommand: prune

# Reset the registry to the lean default: one worker per family the bundle flags as in its default
# profile, for CLIs that are actually installed. The installer calls this; it is also the way back
# from having enabled too much.
cmd_prune() {
  # shellcheck disable=SC2046  # deliberate word splitting: one argument per installed CLI
  registry_tool prune $(installed_clis | tr '\n' ' ') || exit $?
  point_coordinator_at_generated_executors
  restart_coordinator_if_needed
  restart_bridge_if_running
}

# ---------------------------------------------------------------- usage

usage() {
  cat <<'EOF'
Usage: datacore worker <subcommand> [args...]

Subcommands:
  add [name]       enable a worker: a CLI (codex), a family (codex-review),
                   or one exact worker (codex-review@gpt-6-luna).
                   With no name, show what is enabled and what is available.
  list             show the workers the runtime will dispatch to
  remove <name>    disable a worker
  prune            reset to the lean default — one worker per default-profile
                   family, for the worker CLIs installed on this machine
  sync             regenerate the Coordinator's executor profiles from the
                   registry. The installer runs this for you; run it yourself
                   if `datacore doctor` reports executor_config:file_present

The bundle mints a token for every CLI x model x role combination it knows (29 of them). They are
kept in a catalogue beside the registry; these subcommands move workers between the two, so
enabling one never needs new credentials and disabling one never destroys any.

Datacore stores no credential for a worker CLI — it uses your own login for that tool. A model API
provider (datacore provider add) is the other kind, and there Datacore does hold the key.
EOF
  exit 0
}

# Regenerate executor profiles from the registry and make the Coordinator read them. Safe to run
# at any time and on every install: it rewrites only when the content actually changes.
cmd_sync() {
  registry_tool sync || exit $?
  point_coordinator_at_generated_executors
  restart_coordinator_if_needed
}

# ---------------------------------------------------------------- dispatch

subcmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$subcmd" in
  ''|-h|--help) usage ;;
  add)    cmd_add    "$@" ;;
  list)   cmd_list   "$@" ;;
  remove) cmd_remove "$@" ;;
  prune)  cmd_prune  "$@" ;;
  sync)   cmd_sync   "$@" ;;
  *) printf 'Unknown subcommand: %s\nRun: datacore worker --help\n' "$subcmd" >&2; exit 2 ;;
esac
