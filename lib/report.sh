#!/bin/sh
# Datacore preflight report — configuration checks and the next step when one fails.
#
# Usage: datacore report [--output PATH] [--no-open]
#
# `datacore doctor` answers "is each component healthy?", one check at a time, in a wall of text.
# This page combines runtime, worker, launcher and project checks. It does not log into a model
# provider or run a task, so a passing preflight is not evidence of a model reply.
#
# So this gathers what doctor, worker, project and provider each know, computes that one verdict,
# and writes a self-contained HTML page. No network, no fonts, no CDN: the page is a single file
# that opens offline, which matters because the moment you need it is the moment something is
# broken.
#
# Nothing secret is written. Tokens are redacted on the way in, before the page is built.
#
# DATACORE_INSTALL_ROOT  install root (default: ~/.datacore)
# DATACORE_HOME          runtime data directory

set -eu

ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
C="$ROOT/current"
SELF_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || SELF_DIR=""
[ -n "$SELF_DIR" ] && PATH="$SELF_DIR:$PATH" && export PATH

OUTPUT=""
OPEN=1

die() { while [ $# -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done; exit 1; }

usage() {
  cat <<'EOF'
Usage: datacore report [options]

Writes a self-contained HTML page with the preflight verdict, enabled workers,
mapped projects and doctor checks. Model login and task completion are not tested.

Options:
  --output PATH   where to write the page (default: a file in your temp directory)
  --no-open       write the file but do not open it
  -h, --help      this message
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ $# -ge 2 ] || die "--output needs a path."; OUTPUT="$2"; shift 2 ;;
    --output=*) OUTPUT="${1#--output=}"; shift ;;
    --no-open) OPEN=0; shift ;;
    --open) OPEN=1; shift ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1" "Run: datacore report --help" ;;
  esac
done

[ -d "$C" ] || die "Datacore is not installed. Run the installer:" \
  "  https://github.com/david3xu/datacore-install"

# The bundle's own scripts run on bun, so the installer always places one.
find_bun() {
  if command -v bun >/dev/null 2>&1; then command -v bun; return 0; fi
  for _c in "$ROOT/bin/bun" "$HOME/.bun/bin/bun"; do
    [ -x "$_c" ] && { printf '%s\n' "$_c"; return 0; }
  done
  return 1
}
BUN=$(find_bun) || die "bun is not installed. Re-run the installer, or: datacore doctor"

# Redact anything token-shaped before it reaches the page. doctor already truncates the tokens it
# prints, but a page meant to be shared should not depend on every producer remembering to.
redact() {
  sed -E -e 's/(dc_[A-Za-z0-9_-]{6})[A-Za-z0-9_-]+/\1…redacted/g' \
         -e 's/(Bearer )[A-Za-z0-9._~+\/-]{8,}=*/\1…redacted/g' \
         -e 's/\b[0-9a-f]{32,}\b/…redacted/g'
}

WORK="${TMPDIR:-/tmp}/datacore-report.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

DC="$SELF_DIR/datacore"
[ -x "$DC" ] || DC="datacore"

# Every collection step tolerates failure: this command has to work on a broken install, which is
# the only time anyone runs it.
doctor_status=0
doctor_output=$("$DC" doctor 2>&1) || doctor_status=$?
printf '%s\n' "$doctor_output" | redact > "$WORK/doctor.txt"
unset doctor_output
printf '%s\n' "$doctor_status" > "$WORK/doctor-exit.txt"
"$DC" worker  list 2>&1 | redact > "$WORK/worker.txt"   || true
"$DC" project list 2>&1 | redact > "$WORK/project.txt"  || true
"$DC" provider list 2>&1 | redact > "$WORK/provider.txt" || true

# Version: resolve the `current` symlink so the page names the real one.
(cd "$C" 2>/dev/null && basename "$(pwd -P)") > "$WORK/version.txt" 2>/dev/null || printf 'unknown\n' > "$WORK/version.txt"

# Runtime health, read from the port this install actually uses.
PORT=$(sed -n 's/^[[:space:]]*\(export \)\{0,1\}DATACORE_HTTP_PORT=["'\'']\{0,1\}\([0-9]\{1,\}\).*/\2/p' "$C/.env" 2>/dev/null | head -1)
[ -n "${PORT:-}" ] || PORT=43123
printf '%s\n' "$PORT" > "$WORK/port.txt"
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null > "$WORK/health.txt" || printf 'UNREACHABLE\n' > "$WORK/health.txt"
else
  printf 'NO-CURL\n' > "$WORK/health.txt"
fi

printf '%s\n' "$(uname -s) $(uname -m)" > "$WORK/machine.txt"
date '+%Y-%m-%d %H:%M %Z' > "$WORK/generated.txt"

if [ -z "$OUTPUT" ]; then OUTPUT="${TMPDIR:-/tmp}/datacore-report.html"; fi

JS="$WORK/build.js"
cat > "$JS" <<'DATACORE_REPORT_JS'
const fs = require("fs");
const path = require("path");
const [work, out] = process.argv.slice(2);
const read = (n) => { try { return fs.readFileSync(path.join(work, n), "utf8"); } catch { return ""; } };

const esc = (s) => String(s).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
// Defence in depth: the shell redacted already, but this page gets shared.
const safe = (s) => esc(String(s)
  .replace(/(dc_[A-Za-z0-9_-]{6})[A-Za-z0-9_-]+/g, "$1…redacted")
  .replace(/\b[0-9a-f]{32,}\b/g, "…redacted"));

// ---- parse doctor -------------------------------------------------------
// Lines are "<glyph> <STATUS> <name>" followed by indented detail, one of which may be a
// "→ remediation:" line. A check with no recognised status is ignored rather than guessed at.
function parseDoctor(text) {
  const checks = [];
  let summary = "";
  let summaries = 0;
  for (const raw of text.split("\n")) {
    const m = raw.match(/^[^\s]+\s+(OK|FAIL|SKIP|WARN)\s+(.+?)\s*$/);
    if (m) { checks.push({ status: m[1].toLowerCase(), name: m[2], detail: [], remediation: "" }); continue; }
    if (/^summary:/.test(raw)) { summary = raw.trim(); summaries++; continue; }
    const d = raw.match(/^\s+(.*\S)\s*$/);
    if (d && checks.length) {
      const line = d[1];
      if (/^→\s*remediation:/.test(line)) checks[checks.length - 1].remediation = line.replace(/^→\s*remediation:\s*/, "");
      else checks[checks.length - 1].detail.push(line);
    }
  }
  const totals = summary.match(/^summary:\s+(\d+) ok, (\d+) fail, (\d+) skip \((\d+) total\)$/);
  const complete = summaries === 1 && checks.length > 0 && totals
    && ["ok", "fail", "skip"].every((status, i) => checks.filter((c) => c.status === status).length === Number(totals[i + 1]))
    && checks.length === Number(totals[4]);
  return { checks, summary, complete: Boolean(complete) };
}

const doctor = parseDoctor(read("doctor.txt"));
const doctorExit = read("doctor-exit.txt").trim();
const count = (s) => doctor.checks.filter((c) => c.status === s).length;

// ---- parse the list commands -------------------------------------------
const workerTxt = read("worker.txt");
const projectTxt = read("project.txt");
const providerTxt = read("provider.txt");

// "    name@model  [phase, phase]"
const workers = [...workerTxt.matchAll(/^\s{2,}(\S+@\S+)\s+\[([^\]]*)\]\s*$/gm)]
  .map((m) => ({ name: m[1], phases: m[2] }));
const enabledMatch = workerTxt.match(/(\d+)\s+enabled/);
const enabled = enabledMatch ? Number(enabledMatch[1]) : workers.length;
const noToken = [...workerTxt.matchAll(/^\s{4,}(\S+)\s+\((\S+),\s*(\d+)\s*model/gm)]
  .map((m) => ({ name: m[1], cli: m[2], models: m[3] }));

// "  name" then an indented path on the next line
const projects = [];
{
  const lines = projectTxt.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const n = lines[i].match(/^\s{2}(\S+)\s*$/);
    const p = (lines[i + 1] || "").match(/^\s{4,}(\/.*\S)\s*$/);
    if (n && p) { projects.push({ name: n[1], path: p[1] }); i++; }
  }
}
const providersConfigured = !/No providers configured/.test(providerTxt);

// ---- launchers, pulled out of doctor because they are a gate ------------
const launchers = doctor.checks
  .filter((c) => /^bridge_dispatch:launcher:/.test(c.name))
  .map((c) => ({ cli: c.name.replace(/^bridge_dispatch:launcher:/, ""), status: c.status, detail: c.detail.join(" ") }));

// ---- the verdict --------------------------------------------------------
const health = read("health.txt").trim();
const runtimeOk = /"?status"?\s*:\s*"?ok/i.test(health);
const failing = count("fail");
const launcherOk = launchers.filter((l) => l.status === "ok");

const gates = [
  { label: "The runtime answers", pass: runtimeOk,
    detail: runtimeOk ? `http://127.0.0.1:${read("port.txt").trim()}/health returned ok`
                      : `no healthy response from http://127.0.0.1:${read("port.txt").trim()}/health`,
    fix: "datacore start" },
  { label: "At least one worker is enabled", pass: enabled > 0,
    detail: enabled > 0 ? `${enabled} enabled: ${workers.map((w) => w.name).join(", ")}`
                        : "no worker is enabled, so nothing can be dispatched to",
    fix: "datacore worker add claude" },
  { label: "That worker's CLI resolves on PATH", pass: launcherOk.length > 0,
    detail: launchers.length
      ? launchers.map((l) => `${l.cli}: ${l.status}`).join("  ·  ")
      : "doctor reported no launcher checks",
    fix: "install the CLI, then: datacore doctor" },
  { label: "A project is mapped to a repository", pass: projects.length > 0,
    detail: projects.length ? projects.map((p) => `${p.name} → ${p.path}`).join("  ·  ")
                            : "no project is mapped, so a dispatched task has nowhere to work",
    fix: "datacore project link <project> <path>" },
  { label: "Doctor completed without failures", pass: doctor.complete && doctorExit === "0" && failing === 0,
    detail: !doctor.complete ? "doctor did not return a complete report; health is unknown"
      : failing > 0 ? `${failing} failing: ${doctor.checks.filter((c) => c.status === "fail").map((c) => c.name).join(", ")}`
      : doctorExit !== "0" ? `doctor exited with status ${doctorExit || "unknown"}; health is unknown`
      : doctor.summary,
    fix: "datacore doctor" },
];
const blocked = gates.filter((g) => !g.pass);
const ready = blocked.length === 0;

// A worker whose CLI does not resolve is listed as enabled and will never run, so name the pairing
// rather than leaving the reader to cross-reference two sections.
const launcherByCli = Object.fromEntries(launchers.map((l) => [l.cli, l.status]));
const cliOf = (name) => {
  const f = name.split("@")[0];
  if (/^claude/.test(f)) return "claude";
  if (/^codex/.test(f)) return "codex";
  if (/^agy/.test(f)) return "agy";
  if (/^muse/.test(f)) return "muse";
  return "";
};

const chip = (s) => {
  const k = { ok: "ok", pass: "ok", fail: "no", skip: "skip", warn: "warn" }[s] || "skip";
  return `<span class="chip ${k}">${esc(s)}</span>`;
};

const gateRows = gates.map((g) => `
  <div class="row">
    <span class="chip ${g.pass ? "ok" : "no"}">${g.pass ? "pass" : "blocked"}</span>
    <span class="claim">${esc(g.label)}</span>
    <span class="ev">${safe(g.detail)}${g.pass ? "" : `<br><span class="fix">fix: <code>${esc(g.fix)}</code></span>`}</span>
  </div>`).join("");

const order = { fail: 0, warn: 1, skip: 2, ok: 3 };
const checkRows = [...doctor.checks].sort((a, b) => (order[a.status] ?? 9) - (order[b.status] ?? 9))
  .map((c) => `
  <div class="row">
    ${chip(c.status)}
    <span class="claim">${esc(c.name)}</span>
    <span class="ev">${safe(c.detail.join(" "))}${c.remediation ? `<br><span class="fix">remediation: ${safe(c.remediation)}</span>` : ""}</span>
  </div>`).join("");

const workerRows = workers.length ? workers.map((w) => {
  const cli = cliOf(w.name);
  const st = launcherByCli[cli];
  const warn = st && st !== "ok";
  return `<tr><td class="mono">${esc(w.name)}</td><td>${esc(w.phases)}</td>
    <td>${cli ? `<span class="chip ${warn ? "no" : "ok"}">${esc(cli)}: ${esc(st || "unchecked")}</span>` : "&mdash;"}</td></tr>`;
}).join("") : `<tr><td colspan="3" class="empty">No worker is enabled. Nothing can be dispatched until one is.</td></tr>`;

const projectRows = projects.length ? projects.map((p) =>
  `<tr><td class="mono">${esc(p.name)}</td><td class="mono">${esc(p.path)}</td></tr>`).join("")
  : `<tr><td colspan="2" class="empty">No project is mapped. A dispatched task would have nowhere to work.</td></tr>`;

const notProvisioned = noToken.length ? `
  <p class="sub">${noToken.length} further famil${noToken.length === 1 ? "y has" : "ies have"} no credential yet.
  <code>datacore worker add &lt;name&gt;</code> mints one on the spot, which needs the runtime running.</p>
  <div class="scroll"><table><thead><tr><th>Family</th><th>CLI</th><th>Models</th></tr></thead><tbody>
  ${noToken.map((n) => `<tr><td class="mono">${esc(n.name)}</td><td class="mono">${esc(n.cli)}</td><td class="num">${esc(n.models)}</td></tr>`).join("")}
  </tbody></table></div>` : "";

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Datacore readiness — ${esc(read("version.txt").trim())}</title>
<style>
:root{
  --bg:#f4f5f7; --surface:#fff; --surface-2:#eceef1; --fg:#1a1f26; --muted:#5d6673;
  --line:#d4d8df; --accent:#a8562a; --ok:#1d6a5c; --no:#9c3024; --warn:#9a6508; --skip:#6b7280;
  --sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,monospace;
  color-scheme:light;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --bg:#14171c; --surface:#1c2128; --surface-2:#242b34; --fg:#e4e7ec; --muted:#99a3b1;
  --line:#313a45; --accent:#e0905f; --ok:#5cb9a4; --no:#e08275; --warn:#d9a541; --skip:#9aa4b2;
  color-scheme:dark;}}
:root[data-theme="dark"]{
  --bg:#14171c; --surface:#1c2128; --surface-2:#242b34; --fg:#e4e7ec; --muted:#99a3b1;
  --line:#313a45; --accent:#e0905f; --ok:#5cb9a4; --no:#e08275; --warn:#d9a541; --skip:#9aa4b2;
  color-scheme:dark;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--sans);font-size:16px;line-height:1.6;-webkit-font-smoothing:antialiased}
.wrap{max-width:58rem;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px));padding-block:2.5rem 4rem}
h1{font-size:clamp(1.7rem,5vw,2.3rem);font-weight:700;letter-spacing:-.02em;line-height:1.15;margin:0;text-wrap:balance}
h2{font-size:1.2rem;font-weight:600;margin-block:2.75rem 1rem;padding-bottom:.5rem;border-bottom:1px solid var(--line)}
p{margin-block:0 1rem;max-width:62ch}
.sub{color:var(--muted);font-size:.92rem}
.eyebrow{font-family:var(--mono);font-size:.7rem;font-weight:600;letter-spacing:.14em;text-transform:uppercase;color:var(--muted);margin-bottom:.6rem}
code{font-family:var(--mono);font-size:.875em;background:var(--surface-2);padding:.1em .35em;border-radius:3px}
.verdict{margin-top:1.5rem;padding:1.5rem;background:var(--surface);border:1px solid var(--line);border-left:4px solid var(--vcol);border-radius:4px}
.verdict .headline{font-size:1.2rem;font-weight:600;line-height:1.35}
.verdict p{margin-block:.7rem 0;color:var(--muted)}
.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(9rem,1fr));gap:.6rem;margin-top:1.5rem}
.fact{background:var(--surface);border:1px solid var(--line);border-radius:4px;padding:.8rem .9rem}
.fact .k{font-family:var(--mono);font-size:.65rem;letter-spacing:.1em;text-transform:uppercase;color:var(--muted)}
.fact .v{font-size:1.25rem;font-weight:600;font-variant-numeric:tabular-nums;margin-top:.15rem}
.fact .v.small{font-size:.95rem;font-weight:500;word-break:break-word}
.rows{display:grid;gap:.5rem;margin-block:1rem 0}
.row{display:grid;grid-template-columns:5.4rem 1fr;gap:.6rem 1rem;padding:.8rem 1rem;background:var(--surface);border:1px solid var(--line);border-radius:4px}
.row .claim{font-weight:500}
.row .ev{grid-column:2;font-family:var(--mono);font-size:.78rem;color:var(--muted);line-height:1.5;word-break:break-word}
.row .fix{color:var(--accent)}
@media(max-width:34rem){.row{grid-template-columns:1fr}.row .ev{grid-column:1}}
.chip{display:inline-block;font-family:var(--mono);font-size:.66rem;font-weight:600;letter-spacing:.07em;text-transform:uppercase;padding:.2em .5em;border-radius:3px;border:1px solid currentColor;white-space:nowrap;align-self:start}
.chip.ok{color:var(--ok)} .chip.no{color:var(--no)} .chip.warn{color:var(--warn)} .chip.skip{color:var(--skip)}
.scroll{overflow-x:auto;margin-block:1rem 1.5rem;border:1px solid var(--line);border-radius:4px}
table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{text-align:left;padding:.55rem .8rem;border-bottom:1px solid var(--line);vertical-align:top}
thead th{font-family:var(--mono);font-size:.68rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);background:var(--surface-2);white-space:nowrap}
tbody tr:last-child td{border-bottom:0}
td.mono{font-family:var(--mono);font-size:.82rem;word-break:break-all}
td.num{font-variant-numeric:tabular-nums}
td.empty{color:var(--muted);font-style:italic}
footer{margin-top:3rem;padding-top:1.25rem;border-top:1px solid var(--line);color:var(--muted);font-size:.85rem}
</style></head><body>
<div class="wrap">
  <div class="eyebrow">Datacore · preflight · ${esc(read("generated.txt").trim())}</div>
  <h1>Is this install configured for work?</h1>

  <div class="verdict" style="--vcol:var(${ready ? "--ok" : "--no"})">
    <div class="headline">${ready ? "Preflight passes." : `${blocked.length} preflight check${blocked.length === 1 ? " needs" : "s need"} attention.`}</div>
    <p>${ready
      ? "The runtime answers, a worker is enabled, its CLI resolves, a project is mapped, and doctor completed without failures."
      : "Each blocked check below names the next command to run."}</p>
    <p><strong>Model login and task completion: unverified.</strong> Run your worker CLI once to confirm it answers, then complete one small task through Datacore.</p>
  </div>

  <div class="facts">
    <div class="fact"><div class="k">Version</div><div class="v small">${esc(read("version.txt").trim())}</div></div>
    <div class="fact"><div class="k">Runtime</div><div class="v small">${runtimeOk ? "healthy" : "unreachable"}</div></div>
    <div class="fact"><div class="k">Workers</div><div class="v">${enabled}</div></div>
    <div class="fact"><div class="k">Projects</div><div class="v">${projects.length}</div></div>
    <div class="fact"><div class="k">Checks failing</div><div class="v">${failing}</div></div>
    <div class="fact"><div class="k">Providers</div><div class="v small">${providersConfigured ? "configured" : "none"}</div></div>
  </div>

  <h2>The gates</h2>
  <div class="rows">${gateRows}</div>

  <h2>Workers</h2>
  <p class="sub">A worker is enabled in the registry; it only runs if its CLI also resolves on PATH.
  The right-hand column pairs the two, because an enabled worker with a missing CLI looks fine in a
  worker list and never runs.</p>
  <div class="scroll"><table>
    <thead><tr><th>Worker</th><th>Phases</th><th>Launcher</th></tr></thead>
    <tbody>${workerRows}</tbody></table></div>
  ${notProvisioned}

  <h2>Projects</h2>
  <p class="sub">A dispatched task works inside the repository its project maps to. Without a
  mapping the task has nowhere to go.</p>
  <div class="scroll"><table>
    <thead><tr><th>Project</th><th>Repository</th></tr></thead>
    <tbody>${projectRows}</tbody></table></div>

  <h2>Every check</h2>
  <p class="sub">${esc(doctor.summary || "doctor produced no summary")} — failures first.</p>
  <div class="rows">${checkRows}</div>

  <footer>
    Generated by <code>datacore report</code> on ${esc(read("machine.txt").trim())},
    ${esc(read("generated.txt").trim())}. Every value was read from this install; nothing is
    estimated. Tokens are redacted, so this page is safe to send to someone helping you.
    Re-run it any time with <code>datacore report</code>.
  </footer>
</div></body></html>`;

fs.writeFileSync(out, html, "utf8");
process.stdout.write(`${ready ? "ready" : "blocked:" + blocked.length}\n`);
DATACORE_REPORT_JS

VERDICT=$("$BUN" "$JS" "$WORK" "$OUTPUT") || die "Could not build the report."

printf 'Wrote %s\n' "$OUTPUT"
case "$VERDICT" in
  ready) printf 'Verdict: ready — preflight only; model login and task completion are unverified.\n' ;;
  blocked:*) printf 'Verdict: %s preflight check(s) need attention. The page names each one and its fix.\n' "${VERDICT#blocked:}" ;;
esac

if [ "$OPEN" -eq 1 ]; then
  if command -v open >/dev/null 2>&1; then open "$OUTPUT" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$OUTPUT" >/dev/null 2>&1 || true
  fi
fi
