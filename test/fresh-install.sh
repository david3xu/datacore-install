#!/bin/sh
# Prove the fresh-user path end to end, on a machine that has never seen Datacore.
#
# Run it from a Mac against a throwaway Linux VM. It wipes that VM first, so point
# it at a VM you do not care about -- never at a machine holding real data.
#
#   ./test/fresh-install.sh                  # install from this working tree
#   SOURCE=published ./test/fresh-install.sh # install what users actually download
#   VM_PROFILE=arm64 ./test/fresh-install.sh # a different colima profile
#
# Every phase prints PASS or FAIL on its own line and the script exits non-zero if
# any of them failed, so this is usable from CI as well as by hand.
set -u

VM_PROFILE="${VM_PROFILE:-amd64}"
SOURCE="${SOURCE:-local}"
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RELEASE_URL="${RELEASE_URL:-https://raw.githubusercontent.com/david3xu/datacore-install/main/install.sh}"
# Pin the bundle. install.sh defaults DATACORE_VERSION to "latest", so an unpinned proof
# tests whatever happens to be published at the moment it runs -- which is not a proof.
# Derived from the installer's own pin rather than repeated, so the proof always names the
# release the installer will actually fetch.
_pin=$(sed -n 's/^PINNED_RELEASE="\(.*\)"$/\1/p' "$(dirname "$0")/../install.sh" 2>/dev/null)
DATACORE_VERSION="${DATACORE_VERSION:-${_pin:-v0.1.79}}"

FAILURES=0
PHASE=""

vm() { colima ssh --profile "$VM_PROFILE" -- sh -c "$1"; }
vm_quiet() { colima ssh --profile "$VM_PROFILE" -- sh -c "$1" 2>/dev/null; }

phase() {
    PHASE="$1"
    printf '\n══ %s ══\n' "$1"
}

pass() { printf '   PASS  %s\n' "$1"; }
fail() { printf '   FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

check() {
    # check <description> <command producing output> <expected substring>
    _out=$(vm_quiet "$2")
    case "$_out" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 -- got: $(printf '%s' "$_out" | head -c 160)" ;;
    esac
}

printf 'Fresh-install proof\n'
printf '  VM profile : %s\n' "$VM_PROFILE"
printf '  Source     : %s (scripts), %s (bundle)\n' "$SOURCE" "$DATACORE_VERSION"
printf '  Started    : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ---------------------------------------------------------------- 1. clean slate
phase "1. Wipe the machine"
vm 'sudo rm -rf ~/.datacore ~/.datacore-local ~/dcsrc ~/install.sh >/dev/null 2>&1
    rm -f ~/bin/claude ~/bin/codex ~/bin/agy ~/bin/muse >/dev/null 2>&1
    rm -f ~/.local/bin/claude ~/.local/bin/codex ~/.local/bin/agy ~/.local/bin/muse >/dev/null 2>&1
    docker rm -f $(docker ps -aq) >/dev/null 2>&1
    docker volume prune -f >/dev/null 2>&1
    true' >/dev/null 2>&1
check "no install tree, no containers" \
      'echo "dirs=$(ls -d ~/.datacore* 2>/dev/null | wc -l) containers=$(docker ps -aq | wc -l)"' \
      "dirs=0 containers=0"
# A worker CLI left behind by an earlier run makes the next install look better than
# it is -- the installer enables families whose CLI it finds on PATH.
check "no worker CLI survived the wipe" \
      'for c in claude codex agy muse; do command -v $c >/dev/null 2>&1 && echo "$c SURVIVED"; done; echo clean' \
      "clean"

# ------------------------------------------------------- 2. put the installer there
phase "2. Deliver the installer the way a user gets it"
if [ "$SOURCE" = stage ]; then
    # Install from a locally built release stage. The installer reads DATACORE_RELEASE_BASE, so
    # this exercises the real download-and-verify path without pulling ~250MB over the network on
    # every run -- and it tests the bundle actually about to be shipped, not the last published one.
    STAGE="${DATACORE_STAGE:-$HOME/Developer/datacore-le-product-ready/dist/release-stage}"
    [ -d "$STAGE/latest/download" ] || { echo "no release stage at $STAGE"; exit 2; }
    # The stage holds a snapshot of the helper scripts, so a stage built before the last edit
    # silently tests old code -- which is exactly how a fix can look like it did not work.
    # Refresh them from the working tree every run.
    # Take the file list from install.sh's own CLI_FILES instead of repeating it here. Two
    # hand-kept copies drifted once already: uninstall-desktop-entry.py was missing from the
    # refresh list but present in the checksum line, so the stage kept serving a stale copy whose
    # hash matched -- a fix could be edited, staged, proven, and never actually be under test.
    _cli_files=$(sed -n 's/^CLI_FILES="\(.*\)"$/\1/p' "$REPO/install.sh")
    [ -n "$_cli_files" ] || { printf 'could not read CLI_FILES from %s/install.sh\n' "$REPO" >&2; exit 1; }
    _staged_names=''
    for _rel in $_cli_files; do
        _base=$(basename "$_rel")
        [ -f "$REPO/$_rel" ] || { printf 'CLI_FILES names %s but it is not in the repo\n' "$_rel" >&2; exit 1; }
        cp "$REPO/$_rel" "$STAGE/latest/download/$_base"
        _staged_names="$_staged_names $_base"
    done
    # shellcheck disable=SC2086
    (cd "$STAGE/latest/download" && shasum -a 256 \
        datacore-local-edition-amd64.tar.gz datacore-local-edition-arm64.tar.gz \
        $_staged_names > SHA256SUMS)
    vm "rm -rf ~/stage && mkdir -p ~/stage/latest/download" >/dev/null 2>&1
    for f in "$STAGE"/latest/download/*; do
        base=$(basename "$f")
        case "$base" in *arm64*) continue ;; esac   # the VM is x86_64
        colima ssh --profile "$VM_PROFILE" -- sh -c "cat > ~/stage/latest/download/$base" < "$f"
    done
    colima ssh --profile "$VM_PROFILE" -- sh -c "cat > ~/install.sh" < "$REPO/install.sh"
    check "staged the local bundle into the VM" \
          'test -s ~/stage/latest/download/datacore-local-edition-amd64.tar.gz && echo present' "present"
elif [ "$SOURCE" = published ]; then
    vm "curl -fsSL '$RELEASE_URL' -o ~/install.sh" >/dev/null 2>&1
    check "downloaded install.sh from the published release" \
          'test -s ~/install.sh && echo present' "present"
else
    vm 'mkdir -p ~/dcsrc/lib' >/dev/null 2>&1
    for f in install.sh datacore lib/worker.sh lib/provider.sh lib/uninstall.sh lib/uninstall-desktop-entry.py; do
        [ -f "$REPO/$f" ] || continue
        colima ssh --profile "$VM_PROFILE" -- sh -c "cat > ~/dcsrc/$f" < "$REPO/$f"
    done
    vm 'cp ~/dcsrc/install.sh ~/install.sh' >/dev/null 2>&1
    check "copied the working tree ($(cd "$REPO" && git rev-parse --short HEAD))" \
          'test -s ~/dcsrc/lib/worker.sh && echo present' "present"
fi

# ------------------------------------------------------------------- 3. install
phase "3. Install"
if [ "$SOURCE" = stage ]; then
    vm "cd ~ && DATACORE_VERSION=latest DATACORE_RELEASE_BASE=file://\$HOME/stage DATACORE_ACCEPT_EULA=1 sh ~/install.sh 2>&1 | tail -32"
else
    vm "cd ~ && DATACORE_VERSION=$DATACORE_VERSION DATACORE_ACCEPT_EULA=1 sh ~/install.sh 2>&1 | tail -32"
fi
check "runtime answers on its health endpoint" \
      'curl -fsS -m 10 http://127.0.0.1:43123/health || echo UNREACHABLE' \
      '"status"'
if ! vm_quiet 'test -x ~/.datacore/bin/datacore && echo yes' | grep -q yes; then
    fail "the install did not complete — skipping the checks that depend on it"
    printf '\n══════════════════════════════════════════\nRESULT: %s check(s) failed (install aborted)\n' "$FAILURES"
    exit "$FAILURES"
fi

check "doctor reports no blocking failures" \
      '~/.datacore/bin/datacore doctor 2>&1 | tail -1' \
      '0 fail'
vm '~/.datacore/bin/datacore doctor 2>&1 | grep -A2 "FAIL" | head -20' 2>/dev/null

# ------------------------------------------------------------- 4. what it minted
phase "4. Credentials and identities"
vm 'echo "  tokens minted : $(grep -c "_TOKEN=" ~/.datacore/current/generated/client-tokens.env 2>/dev/null)"
    echo "  agent ids     : $(grep -c "_AGENT_ID=" ~/.datacore/current/.env 2>/dev/null)"'
check "no identity was left empty" \
      'grep -E "^DATACORE_(COORDINATOR|LOCAL_WORKER|GATEWAY|CLAUDE_CODE)_AGENT_ID=$" ~/.datacore/current/.env | wc -l' \
      "0"
check "data landed under the install root, not a shared path" \
      'ls -d ~/.datacore-local >/dev/null 2>&1 && echo SHARED_PATH_CREATED || echo isolated' \
      "isolated"

# --------------------------------------------------------------- 5. the workers
phase "5. Workers"
vm 'cd ~ && ~/.datacore/bin/datacore worker list 2>&1 | head -20'

# ------------------------------------------- 6. enabling one provisions it fully
# A stub stands in for a real worker CLI: the installer only enables a family whose
# command it can resolve, and a stub keeps the run deterministic and login-free.
phase "6. Enabling a worker provisions it on demand"
vm 'mkdir -p ~/bin && printf "#!/bin/sh\nexit 0\n" > ~/bin/codex && chmod +x ~/bin/codex' >/dev/null 2>&1
vm 'cd ~ && PATH="$HOME/bin:$PATH" ~/.datacore/bin/datacore worker add codex-worker 2>&1 | tail -12'
check "the worker reached the registry the bridge reads" \
      'grep -o "codex-worker" ~/.datacore/data/runtime/worker-registry.json 2>/dev/null | head -1' \
      "codex-worker"
check "all registry copies agree" \
      '~/.datacore/bin/datacore doctor 2>&1 | tail -1' \
      '0 fail'

# ------------------------------------------------- 6b. can it actually be dispatched to?
# Enabling a worker is not the same as the Coordinator being able to reach it. The
# Coordinator dispatches from an executor config; if that still points at the bundle's
# curated example, only the agent ids that example happens to list are reachable, and
# every other enabled worker fails at dispatch with no obvious cause.
phase "6b. Dispatch readiness"
vm 'sudo cat ~/.datacore/data/coordinator/executor-capability-projection.json 2>/dev/null |
    python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(\"  no capability projection written\"); raise SystemExit
src = (d.get(\"source\") or {}).get(\"executor_config_path\", \"?\")
caps = d.get(\"capabilities\", [])
print(\"  executor_config_path :\", src)
print(\"  profiles projected   :\", len(caps))
print(\"  example-derived      :\", \"yes\" if \"example\" in src else \"no\")
"'
check "the Coordinator reads generated profiles, not the bundle example" \
      'src=$(sudo cat ~/.datacore/data/coordinator/executor-capability-projection.json 2>/dev/null |
             tr "," "\n" | sed -n "s/.*executor_config_path[^:]*:[^\"]*\"\\([^\"]*\\)\".*/\\1/p" | head -1)
       if [ -z "$src" ]; then echo "no projection"
       elif echo "$src" | grep -q example; then echo "example: $src"
       else echo generated; fi' \
      "generated"
check "every enabled worker has a matching executor profile" \
      'sudo python3 -c "
import json
reg = json.load(open(\"/home/lima.guest/.datacore/data/runtime/worker-registry.json\"))
proj = json.load(open(\"/home/lima.guest/.datacore/data/coordinator/executor-capability-projection.json\"))
rows = reg.get(\"workers\", []) if isinstance(reg, dict) else reg
workers = {w.get(\"agent_id\") for w in rows if w.get(\"enabled\") and (w.get(\"phases\") or w.get(\"family\"))}
targets = {c.get(\"target_agent\") for c in proj.get(\"capabilities\", [])}
missing = sorted(w for w in workers if w and w not in targets)
print(\"UNREACHABLE: \" + \", \".join(missing) if missing else \"all enabled workers reachable\")
" 2>/dev/null || echo "could not compare"' \
      "all enabled workers reachable"

# ------------------------------------------------------------------ 7. teardown
phase "7. Uninstall leaves nothing behind"
vm 'cd ~ && ~/.datacore/bin/datacore uninstall 2>&1 | tail -6'
check "install tree is gone" \
      'test -d ~/.datacore/current && echo STILL_THERE || echo removed' \
      "removed"
check "no containers left running" \
      'docker ps -q | wc -l' "0"

# -------------------------------------------------------------------- verdict
printf '\n══════════════════════════════════════════\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'RESULT: every phase passed\n'
else
    printf 'RESULT: %s check(s) failed\n' "$FAILURES"
fi
printf 'Finished: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
exit "$FAILURES"
