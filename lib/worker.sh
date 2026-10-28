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

# ---------------------------------------------------------------- helpers

die()  { printf '%s\n' "$1" >&2; exit 1; }
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
  return 0
}

# The bridge reads the registry when it starts, so a change while it is running is invisible until
# it restarts. On a minimal install it is not running and there is nothing to do.
restart_bridge_if_running() {
  _stop="$ROOT/current/stop-host-worker-bridge.sh"
  _start="$ROOT/current/start-host-worker-bridge.sh"
  [ -x "$_stop" ] && [ -x "$_start" ] || return 0
  pgrep -f 'host-worker-bridge' >/dev/null 2>&1 || return 0
  if (cd "$ROOT/current" && "$_stop" >/dev/null 2>&1 && "$_start" >/dev/null 2>&1); then
    ok "restarted the worker bridge so it picks up the change"
  else
    warn "could not restart the worker bridge — run: datacore restart"
  fi
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
    out.set(m[1], {
      cli: pick(/cli:"([^"]+)"/),
      defaultAlias: pick(/defaultModelAlias:"([^"]+)"/),
      inDefault: /inDefaultProfile:(?:!0|true)/.test(seg),
      aliases: (aliasRef && arrays.get(aliasRef)) || [],
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
  catalogue.workers = [...byId.values()];
  if (cataloguePath) write(cataloguePath, catalogue);
}

const fams = families(configPath);

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
    console.log("  Provisioning those needs the installer — see: datacore worker add <name>");
  }
  process.exit(0);
}

if (cmd === "prune") {
  // rest = CLI binaries that resolve on this machine, as the family `cli` names them.
  const present = new Set(rest.filter(Boolean));
  const keep = onePerFamily(catalogue.workers, fams, (w, meta, fam) => {
    if (isInfra(w)) return false;
    if (!meta.inDefault) return false;             // agy: the bundle itself flags it opt-in
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
  // A selector names a CLI (codex), a family (codex-review) or one exact worker (codex-review@gpt-6-luna).
  const matches = (w) => {
    const fam = familyOf(w);
    const meta = fams.get(fam) || {};
    const hit = fam === selName || (meta.cli || w.cli) === selName || w.cli === selName;
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
      die(
        `'${sel}' is a worker Datacore knows, but this install has no token for it.\n` +
          `  The registry is generated with the default profile only. To provision every\n` +
          `  catalogued model, re-run the install with the full registry:\n\n` +
          `    DATACORE_LOCAL_FULL_WORKER_REGISTRY=1 datacore update\n\n` +
          `  Then: datacore worker add ${sel}\n\n  Matched:\n    ${aliasNote}`,
      );
    }
    const names = [...new Set(catalogue.workers.filter((w) => !isInfra(w)).map((w) => familyOf(w)))];
    die(`No worker matches '${sel}'.\n  Known: ${names.join(", ")}`);
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
      say "No worker CLI found on this machine (looked for: claude, codex, agy)."
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
    *)                                       _bin='' ;;
  esac

  registry_tool enable "$sel" || exit $?
  if [ -n "$_bin" ] && ! command -v "$_bin" >/dev/null 2>&1; then
    warn "the '$_bin' command is not on PATH, so nothing will be dispatched to it yet"
  fi
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
  say "  (check: datacore doctor), and DATACORE_WORKER_PROJECT_WORKSPACES in"
  say "  $ROOT/current/.env must map your project name to a git repository."
}

# ---------------------------------------------------------------- subcommand: remove

cmd_remove() {
  _name="${1:-}"
  [ -n "$_name" ] || { say "Usage: datacore worker remove <name>" >&2; exit 2; }
  registry_tool disable "$_name" || exit $?
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

The bundle mints a token for every CLI x model x role combination it knows (29 of them). They are
kept in a catalogue beside the registry; these subcommands move workers between the two, so
enabling one never needs new credentials and disabling one never destroys any.

Datacore stores no credential for a worker CLI — it uses your own login for that tool. A model API
provider (datacore provider add) is the other kind, and there Datacore does hold the key.
EOF
  exit 0
}

# ---------------------------------------------------------------- dispatch

subcmd="${1:-}"; [ $# -gt 0 ] && shift || true
case "$subcmd" in
  ''|-h|--help) usage ;;
  add)    cmd_add    "$@" ;;
  list)   cmd_list   "$@" ;;
  remove) cmd_remove "$@" ;;
  prune)  cmd_prune  "$@" ;;
  *) printf 'Unknown subcommand: %s\nRun: datacore worker --help\n' "$subcmd" >&2; exit 2 ;;
esac
