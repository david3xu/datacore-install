#!/bin/sh
# Datacore project workspaces — map a project name to the repository a worker should work in.
#
# Usage: datacore project link <name> <path> | list | unlink <name>
#
# Nothing is dispatched to a worker until its project has a workspace. The host worker bridge
# resolves that from DATACORE_WORKER_PROJECT_WORKSPACES, a JSON object in the install's .env, by
# exact project name — there is no "default" key and no wildcard, so an unmapped project fails with
# "No worker workspace configured for project: <name>". Before this command existed the only way to
# set it was to hand-edit JSON inside that .env, which `datacore worker list` told the user to do
# and `datacore --help` never mentioned; a fresh install therefore passed doctor with 21 ok and
# still could not run a task. This command is that missing verb.
#
# DATACORE_HOME   runtime data directory (default: ~/.datacore-local)

set -eu

ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
ENV_FILE="$ROOT/current/.env"
KEY=DATACORE_WORKER_PROJECT_WORKSPACES

# The installer writes this when it has no real project to map, because the bundle's pre-flight
# rejects an empty object outright ("the host-worker-bridge throws on empty"). It exists only to
# satisfy that check, so it is never presented as a usable mapping: `list` calls it out and `link`
# removes it as soon as there is something true to put in its place.
PLACEHOLDER_KEY=_unconfigured
# Resolved here, from the install root this command already honours, and handed to the map program.
# Deriving it a second time inside that program -- or in the installer -- is how the two drift.
PLACEHOLDER_DIR="$ROOT/workspaces/$PLACEHOLDER_KEY"

die()  { while [ $# -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done; exit 1; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

find_bun() {
  if command -v bun >/dev/null 2>&1; then command -v bun; return 0; fi
  [ -x "$ROOT/bin/bun" ] && { printf '%s\n' "$ROOT/bin/bun"; return 0; }
  return 1
}

[ -f "$ENV_FILE" ] || die "Datacore is not installed, or its .env is missing: $ENV_FILE" \
  "Run the installer: https://github.com/david3xu/datacore-install"

# ---------------------------------------------------------------- the map program
#
# Reads every copy of the key in .env, applies one edit, and rewrites the file with the key
# appearing exactly once. Rewriting rather than appending is deliberate: the installer appended a
# copy of this key before the bundle generated its own, leaving the live .env with two, and which
# one applies then depends on whether the reader takes the first or the last. An edit here collapses
# them, so running `project list` once is enough to make an install single-valued again.
#
# JSON surgery in POSIX sh is not worth attempting and python3 is not guaranteed on a user's
# machine, so this runs on the bun the installer always places. It is embedded rather than shipped
# as another lib/ file so that a release cut before that file existed still gets this command whole.

map_tool() {
  _bun=$(find_bun) || die "bun is not installed. Re-run the installer, or: datacore doctor"
  # bun needs a real file with a .js name -- `bun run /dev/stdin` cannot resolve a heredoc -- and a
  # temp directory from mktemp gives one without the predictable `$$` path a shared /tmp makes
  # guessable. The trap removes it even when the command is interrupted.
  _jsdir=$(mktemp -d "${TMPDIR:-/tmp}/datacore-project.XXXXXX") || die "Could not create a temporary directory."
  trap 'rm -rf "$_jsdir"' EXIT INT TERM
  _js="$_jsdir/map.js"
  cat > "$_js" <<'DATACORE_PROJECT_JS'
// Datacore project-workspace map surgery. Invoked by `datacore project`.
const { readFileSync, writeFileSync, renameSync, existsSync, mkdirSync } = require("fs");

const FILE = process.env.DC_ENV_FILE;
const KEY = process.env.DC_KEY;
const PLACEHOLDER = process.env.DC_PLACEHOLDER;
const PLACEHOLDER_DIR = process.env.DC_PLACEHOLDER_DIR;
const USER_HOME = process.env.DC_HOME || "";
const [action, argName, argPath] = process.argv.slice(2);

// Installs made before the stand-in was reserved carry {"default":"$HOME"}: a key no project is
// named, pointing at everything the user owns. It is a stand-in too, and a dangerous one, so it is
// reported as such and removed by the first real mapping rather than left to be inherited.
const isLegacyStandIn = (k, v) => k === "default" && USER_HOME && v === USER_HOME;

const raw = readFileSync(FILE, "utf8");
const lines = raw.split("\n");

// A .env value may be single-quoted, double-quoted or bare. Take the last occurrence as the
// starting point only because it is the one a compose-style reader would use; the rewrite makes the
// choice moot by leaving a single line behind.
const hits = [];
lines.forEach((l, i) => { if (l.startsWith(KEY + "=")) hits.push(i); });

function unquote(v) {
  const t = v.trim();
  const last = t.length ? t[t.length - 1] : "";
  if (t.length >= 2 && ((t[0] === "'" && last === "'") || (t[0] === '"' && last === '"'))) {
    return t.slice(1, -1);
  }
  return t;
}

let map = {};
let parseError = null;
if (hits.length) {
  const body = unquote(lines[hits[hits.length - 1]].slice(KEY.length + 1));
  if (body) {
    try {
      const parsed = JSON.parse(body);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) map = parsed;
      else parseError = "not a JSON object";
    } catch (e) { parseError = e.message; }
  }
}

function report() {
  const all = Object.entries(map);
  const entries = all.filter(([k, v]) => k !== PLACEHOLDER && !isLegacyStandIn(k, v));
  process.stdout.write(JSON.stringify({
    entries,
    duplicates: hits.length,
    parseError,
    placeholder: PLACEHOLDER in map,
    legacy: all.some(([k, v]) => isLegacyStandIn(k, v)),
  }));
}

if (action === "read") { report(); process.exit(0); }

if (parseError) {
  process.stderr.write(KEY + " in " + FILE + " is not usable (" + parseError + ").\n");
  process.exit(3);
}

if (action === "link") {
  map[argName] = argPath;
  // A real mapping replaces every stand-in, the reserved one and the legacy {"default":"$HOME"}.
  delete map[PLACEHOLDER];
  for (const [k, v] of Object.entries(map)) if (isLegacyStandIn(k, v)) delete map[k];
} else if (action === "unlink") {
  // Exit 4 and say nothing: the caller knows the project name and prints a message that also
  // tells the user how to see what is mapped. Writing here as well printed both.
  if (!(argName in map)) process.exit(4);
  delete map[argName];
} else {
  process.stderr.write("unknown action: " + action + "\n");
  process.exit(2);
}

// Pre-flight fails a map with no entries, and the bridge throws on one, so an install must never be
// left holding an empty object. Putting the stand-in back keeps `unlink` of the last project from
// breaking the next start, and `list` still reports the install as not configured.
if (Object.entries(map).filter(([k, v]) => !isLegacyStandIn(k, v)).length === 0) {
  for (const [k, v] of Object.entries(map)) if (isLegacyStandIn(k, v)) delete map[k];
  map[PLACEHOLDER] = PLACEHOLDER_DIR;
}
if (PLACEHOLDER in map) {
  const dir = map[PLACEHOLDER];
  try { if (!existsSync(dir)) mkdirSync(dir, { recursive: true }); } catch (e) { /* list reports it */ }
}

const line = KEY + "='" + JSON.stringify(map) + "'";
let wrote = false;
const kept = [];
for (const l of lines) {
  if (!l.startsWith(KEY + "=")) { kept.push(l); continue; }
  if (!wrote) { kept.push(line); wrote = true; }   // first copy becomes the canonical one,
                                                   // every later copy is dropped
}
if (!wrote) kept.push(line);

// Write through a temp file in the same directory and rename, so an interrupted write cannot leave
// the install with a half-written .env that nothing will start from.
const tmp = FILE + ".dc-project.tmp";
writeFileSync(tmp, kept.join("\n"), { mode: 0o600 });
renameSync(tmp, FILE);
report();
DATACORE_PROJECT_JS

  DC_ENV_FILE="$ENV_FILE" DC_KEY="$KEY" DC_PLACEHOLDER="$PLACEHOLDER_KEY" \
  DC_PLACEHOLDER_DIR="$PLACEHOLDER_DIR" DC_HOME="$HOME" \
    "$_bun" "$_js" "$@"
  # Clean up now rather than leaving it to the trap: the trap holds one path, so a second call to
  # this function would overwrite it and the first directory would survive until the script exits.
  _st=$?
  rm -rf "$_jsdir"
  trap - EXIT INT TERM
  return $_st
}

# The map is written as a single-quoted .env value, and .env has no escape for a single quote, so a
# single quote anywhere inside the JSON -- in a project name just as much as in a path -- produces a
# file nothing can parse. Refusing is better than writing that file.
#
# Guarding only the path was the first version of this, and the test caught it: the name lands in
# the same single-quoted value and breaks it the same way.
check_no_single_quote() {
  case "$2" in
    *"'"*) die "A $1 containing a single quote cannot be stored in .env: $2" \
                "The map is written as a single-quoted .env value, which has no escape for one." \
                "Rename it and run this again." ;;
  esac
}

# ---------------------------------------------------------------- the bridge
#
# The map is read by the host worker bridge from its own environment at startup, so a change to
# .env does nothing until the bridge is restarted. Lifted from `datacore worker`, which has the
# same obligation, including its reason for not trusting "a bridge is running" as proof.

restart_bridge_if_running() {
  _stop="$ROOT/current/stop-host-worker-bridge.sh"
  _start="$ROOT/current/start-host-worker-bridge.sh"
  [ -x "$_stop" ] && [ -x "$_start" ] || return 0
  pgrep -f 'host-worker-bridge' >/dev/null 2>&1 || return 0
  _pids_before=$(pgrep -f 'host-worker-bridge' 2>/dev/null | tr '\n' ' ')
  if ! (cd "$ROOT/current" && "$_stop" >/dev/null 2>&1 && "$_start" >/dev/null 2>&1); then
    warn "could not restart the worker bridge — run: datacore restart"
    return 0
  fi
  _waited=0
  while [ "$_waited" -lt 10 ]; do
    for _pid in $(pgrep -f 'host-worker-bridge' 2>/dev/null); do
      case " $_pids_before " in
        *" $_pid "*) ;;
        *) ok "restarted the worker bridge so it picks up the change"; return 0 ;;
      esac
    done
    sleep 1
    _waited=$((_waited + 1))
  done
  warn "the worker bridge did not come back after 10s"
  warn "check it with: datacore doctor    then: datacore restart"
}

# ---------------------------------------------------------------- reading the report

# The map program prints one JSON object. Pull fields out with bun rather than a grep, so a path
# containing a brace or a comma cannot be mis-split.
report_field() {
  _bun=$(find_bun) || return 1
  _rfdir=$(mktemp -d "${TMPDIR:-/tmp}/datacore-project-rf.XXXXXX") || return 1
  _rf="$_rfdir/field.js"
  cat > "$_rf" <<'DATACORE_FIELD_JS'
const [field, payload] = process.argv.slice(2);
const d = JSON.parse(payload);
if (field === "entries") {
  for (const [k, v] of d.entries) process.stdout.write(k + "\t" + v + "\n");
} else {
  process.stdout.write(String(d[field] === undefined || d[field] === null ? "" : d[field]));
}
DATACORE_FIELD_JS
  "$_bun" "$_rf" "$1" "$2"
  _st=$?
  rm -rf "$_rfdir"
  return $_st
}

usage() {
  cat <<'EOF'
Usage: datacore project <subcommand> [args...]

Subcommands:
  link <name> <path>   map a project to the repository its workers should work in
  list                 show the mapped projects, and whether each path is usable
  unlink <name>        remove a project's mapping

  With no subcommand, list.

A worker is dispatched into the workspace its project is mapped to. The name must be the project
name as Datacore knows it — the one you see in `get_tasks` or on a task — and matching is exact:
no "default" entry and no wildcard stands in for a project that is not listed here.
EOF
  exit 0
}

cmd_list() {
  _out=$(map_tool read) || exit 1
  _dups=$(report_field duplicates "$_out")
  _perr=$(report_field parseError "$_out")
  _ph=$(report_field placeholder "$_out")

  if [ -n "$_perr" ]; then
    warn "$KEY in $ENV_FILE is not valid JSON: $_perr"
    warn "fix it with: datacore project link <name> <path>    (which rewrites the whole value)"
    exit 1
  fi

  _entries=$(report_field entries "$_out")
  if [ -z "$_entries" ]; then
    say "No project is mapped to a workspace."
    say ""
    say "  Until one is, a worker cannot be dispatched: the bridge resolves the workspace by"
    say "  exact project name and fails with \"No worker workspace configured for project\"."
    say ""
    say "  Map one with:  datacore project link <project-name> <path-to-repo>"
  else
    say "Projects a worker can be dispatched into:"
    printf '%s\n' "$_entries" | while IFS="$(printf '\t')" read -r _name _path; do
      [ -n "$_name" ] || continue
      if [ ! -d "$_path" ]; then
        printf '  %s\n      %s  (missing — dispatch will fail)\n' "$_name" "$_path"
      elif [ ! -d "$_path/.git" ]; then
        printf '  %s\n      %s  (not a git repository)\n' "$_name" "$_path"
      else
        printf '  %s\n      %s\n' "$_name" "$_path"
      fi
    done
  fi

  _legacy=$(report_field legacy "$_out")
  if [ "$_legacy" = true ]; then
    say ""
    warn "this install carries the old stand-in entry \"default\" → $HOME"
    warn "no project is named \"default\", so it maps nothing; had it matched, a worker would have"
    warn "been given your whole home directory. The next 'datacore project link' removes it."
  fi
  if [ "$_ph" = true ]; then
    say ""
    say "  This install still carries the stand-in entry the installer writes when it has no"
    say "  project to map. It is not a usable mapping — the bundle's pre-flight rejects an empty"
    say "  map, so something has to be there. Adding a real project removes it."
  fi
  if [ "${_dups:-0}" -gt 1 ]; then
    say ""
    warn "$KEY appears $_dups times in $ENV_FILE — which copy applies depends on the reader"
    warn "the next 'datacore project link' or 'unlink' collapses it to one"
  fi
}

# ---------------------------------------------------------------- dispatch

sub="${1:-list}"
[ $# -gt 0 ] && shift

case "$sub" in
  -h|--help|help) usage ;;

  list) cmd_list ;;

  link)
    [ $# -eq 2 ] || die "Usage: datacore project link <name> <path>"
    _name=$1; _path=$2
    case "$_name" in
      "") die "The project name cannot be empty." ;;
      "$PLACEHOLDER_KEY") die "$PLACEHOLDER_KEY is reserved for the installer's stand-in entry." ;;
    esac
    check_no_single_quote "project name" "$_name"
    check_no_single_quote "workspace path" "$_path"
    # Resolve to an absolute path. The bridge requires one, and a relative path recorded here would
    # resolve against whatever directory the bridge happens to start in.
    _abs=$(cd "$_path" 2>/dev/null && pwd -P) || die "No such directory: $_path" \
      "Create the repository first, then map it."
    if [ ! -d "$_abs/.git" ]; then
      warn "$_abs is not a git repository"
      warn "a worker records its work as commits there, so map a repository unless you are about to create one"
    fi
    _out=$(map_tool link "$_name" "$_abs") || exit 1
    ok "$_name → $_abs"
    restart_bridge_if_running
    say ""
    cmd_list
    ;;

  unlink)
    [ $# -eq 1 ] || die "Usage: datacore project unlink <name>"
    check_no_single_quote "project name" "$1"
    if _out=$(map_tool unlink "$1"); then
      ok "unmapped $1"
      restart_bridge_if_running
      say ""
      cmd_list
    else
      _st=$?
      [ "$_st" = 4 ] && die "No such mapped project: $1" "See what is mapped with: datacore project list"
      exit "$_st"
    fi
    ;;

  *) die "Unknown subcommand: $sub" "Run: datacore project --help" ;;
esac
