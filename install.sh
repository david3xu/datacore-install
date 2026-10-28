#!/bin/sh
# Datacore installer.
#
# Usage:  curl -fsSL https://raw.githubusercontent.com/david3xu/datacore-install/v0.1.79/install.sh | sh
#
# Environment overrides:
#   DATACORE_VERSION        version to install (default: the release this installer ships with,
#                           printed below as PINNED_RELEASE; pass `latest` to track the newest)
#   DATACORE_RELEASE_BASE   base URL for release artifacts
#   DATACORE_INSTALL_ROOT   where versions are kept (default: ~/.datacore)
#   DATACORE_HOME           runtime data directory (default: ~/.datacore-local)
#   DATACORE_ACCEPT_EULA=1  skip the interactive licence prompt (CI)
#   DATACORE_COMPOSE_PROJECT         Compose project for this install (default: datacore-local).
#                                    Give a second install on the same machine its own, or it
#                                    reconciles the first install's containers to its own config.
#   DATACORE_SKIP_CLIENT_REGISTRATION=1  do not touch AI client config (proof runs)
#   DATACORE_SKIP_START=1   install and configure, but start no containers (proof runs)
#

set -eu

# The release this installer was cut with. Defaulting to `latest` made the install
# irreproducible by construction: the same command run on two days installed different
# software, and nothing recorded which. An installer fetched at a tag now installs the
# bundle from that same tag, so a command that worked once works the same way forever.
# Release tooling rewrites this line; `latest` remains available on request.
PINNED_RELEASE="v0.1.79"
VERSION="${DATACORE_VERSION:-$PINNED_RELEASE}"
RELEASE_BASE="${DATACORE_RELEASE_BASE:-https://github.com/david3xu/datacore-install/releases}"
INSTALL_ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
# Data lives under the install root by default, not in a fixed $HOME/.datacore-local. That shared
# path is what both the bundle's generator and this installer used to default to, so a second
# install silently adopted the first one's database. Set DATACORE_HOME explicitly to point a new
# install at existing data on purpose.
DATA_HOME="${DATACORE_HOME:-$INSTALL_ROOT/data}"
COMPOSE_PROJECT="${DATACORE_COMPOSE_PROJECT:-datacore-local}"
# The bundle's scripts resolve their compose project and workspace from this, so it has to be set
# before any of them run, not only when .env is written.
DATACORE_LOCAL_COMPOSE_PROJECT="$COMPOSE_PROJECT"; export DATACORE_LOCAL_COMPOSE_PROJECT
BIN_DIR="$INSTALL_ROOT/bin"

# The bundle's own scripts run on bun, so a machine with only Docker cannot start Datacore.
# The installer provisions a private copy rather than asking the user to install a toolchain.
# Keep these in step with the bun the bundle's JavaScript was built with.
BUN_IMAGE="${DATACORE_BUN_IMAGE:-oven/bun:1.3}"
BUN_VERSION="${DATACORE_BUN_VERSION:-1.3.13}"

# Resolve our own directory before anything cd's: $0 may be relative, and later steps change
# the working directory. BUNDLE_DIR is the real versioned path; never drive the bundle through
# the 'current' symlink, because its own tooling re-points that symlink from basename($PWD).
SELF_DIR=""
[ -f "$0" ] && SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || true
BUNDLE_DIR=""
SUMS_FILE=""
PREVIOUS_DIR=""
WORKERS_SUMMARY="left as generated"

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m'); else B=''; D=''; R=''; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$B" "$R" "$*"; }
info() { printf '  %s·%s %s\n' "$D" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$B" "$R" "$*"; }
die()  {
  printf '\n%sInstall stopped.%s %s\n\n' "$B" "$R" "$1" >&2
  shift
  while [ $# -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done
  printf '\n' >&2
  exit 1
}
step() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }

# ---------------------------------------------------------------- 1. platform

detect_platform() {
  os=$(uname -s); arch=$(uname -m)
  case "$os" in
    Darwin) PLATFORM_OS=macos ;;
    Linux)  PLATFORM_OS=linux ;;
    *) die "Unsupported operating system: $os" "Datacore supports macOS, and Linux where noted. See the README for current platform support." ;;
  esac
  case "$arch" in
    arm64|aarch64) PLATFORM_ARCH=arm64 ;;
    x86_64|amd64)  PLATFORM_ARCH=amd64 ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
  ok "$PLATFORM_OS/$PLATFORM_ARCH"
}

# ---------------------------------------------------------------- 2. container runtime

docker_install_hint() {
  if [ "$PLATFORM_OS" = macos ]; then
    printf 'Install one of these, then run this installer again:\n\n  brew install colima docker && colima start\n\nor install Docker Desktop from https://docker.com/products/docker-desktop\n'
  else
    printf 'Install Docker Engine, then run this installer again:\n\n  https://docs.docker.com/engine/install/\n'
  fi
}

ensure_container_runtime() {
  command -v docker >/dev/null 2>&1 || die "No container runtime found." "$(docker_install_hint)"
  if docker info >/dev/null 2>&1; then ok "container runtime is running"; return; fi

  # A fresh Docker Engine install leaves the socket root-owned, so the daemon is running and the
  # user still cannot talk to it. Saying "install Docker" here sends people down the wrong path.
  case "$(docker info 2>&1 || true)" in
    *"permission denied"*)
      die "Docker is running, but your user is not allowed to use it." \
          "Add yourself to the docker group, then start a new shell and run this installer again:

  sudo usermod -aG docker \"$(id -un)\"

(Docker's own post-install step: https://docs.docker.com/engine/install/linux-postinstall/)" ;;
  esac
  if command -v colima >/dev/null 2>&1; then
    info "colima is installed but not running — starting it (this takes a minute)"
    colima start >/dev/null 2>&1 || die "colima failed to start." "Run 'colima start' yourself to see why."
    docker info >/dev/null 2>&1 || die "Docker is still unreachable after starting colima."
    ok "started colima"
    return
  fi
  die "Docker is installed but its daemon is not reachable." "$(docker_install_hint)"
}

# ---------------------------------------------------------------- 2b. bun

# Linux: take the binary out of the official bun image. Docker is already required, the image
# carries a glibc build for the host architecture, and this needs no unzip and no package manager.
bun_from_docker() {
  _log=$(mktemp) || return 1
  if ! docker pull -q "$BUN_IMAGE" >"$_log" 2>&1; then
    BUN_FETCH_ERR="docker pull $BUN_IMAGE: $(tail -2 "$_log")"; rm -f "$_log"; return 1
  fi
  if ! _cid=$(docker create "$BUN_IMAGE" 2>"$_log"); then
    BUN_FETCH_ERR="docker create $BUN_IMAGE: $(tail -2 "$_log")"; rm -f "$_log"; return 1
  fi
  if ! docker cp "$_cid:/usr/local/bin/bun" "$BIN_DIR/bun.new" >"$_log" 2>&1; then
    BUN_FETCH_ERR="docker cp: $(tail -2 "$_log")"
    docker rm -f "$_cid" >/dev/null 2>&1 || true
    rm -f "$_log"; return 1
  fi
  docker rm -f "$_cid" >/dev/null 2>&1 || true
  rm -f "$_log"
}

# macOS: the official zip. unzip ships with macOS, so nothing has to be installed first.
bun_from_release() {
  case "$PLATFORM_ARCH" in
    arm64) _zip=bun-darwin-aarch64 ;;
    amd64) _zip=bun-darwin-x64 ;;
    *) BUN_FETCH_ERR="no bun build for $PLATFORM_OS/$PLATFORM_ARCH"; return 1 ;;
  esac
  _tmp=$(mktemp -d) || return 1
  _url="https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/$_zip.zip"
  if ! fetch "$_url" "$_tmp/bun.zip" 2>"$_tmp/err"; then
    BUN_FETCH_ERR="download $_url: $(tail -2 "$_tmp/err")"; rm -rf "$_tmp"; return 1
  fi
  if ! unzip -q -o -j "$_tmp/bun.zip" "$_zip/bun" -d "$_tmp" 2>"$_tmp/err"; then
    BUN_FETCH_ERR="unzip: $(tail -2 "$_tmp/err")"; rm -rf "$_tmp"; return 1
  fi
  mv "$_tmp/bun" "$BIN_DIR/bun.new" || { rm -rf "$_tmp"; return 1; }
  rm -rf "$_tmp"
}

ensure_bun() {
  if command -v bun >/dev/null 2>&1; then ok "bun $(bun --version 2>/dev/null)"; return; fi

  mkdir -p "$BIN_DIR"
  if [ -x "$BIN_DIR/bun" ] && "$BIN_DIR/bun" --version >/dev/null 2>&1; then
    PATH="$BIN_DIR:$PATH"; export PATH
    ok "bun $("$BIN_DIR/bun" --version) (private copy from an earlier install)"
    return
  fi

  info "bun is not installed — fetching a private copy into $BIN_DIR (nothing system-wide)"
  BUN_FETCH_ERR=""
  if [ "$PLATFORM_OS" = linux ]; then _got_bun=bun_from_docker; else _got_bun=bun_from_release; fi
  if ! $_got_bun; then
    die "Could not obtain bun." "${BUN_FETCH_ERR:-no further detail}

Datacore's own scripts run on bun. Retry, or install it yourself and run this installer again:

  curl -fsSL https://bun.sh/install | bash"
  fi

  chmod +x "$BIN_DIR/bun.new"
  mv -f "$BIN_DIR/bun.new" "$BIN_DIR/bun"
  PATH="$BIN_DIR:$PATH"; export PATH
  _ver=$("$BIN_DIR/bun" --version 2>&1) || die "The bun copy we fetched does not run on this machine." \
    "$BIN_DIR/bun --version said:
     $_ver"
  ok "bun $_ver (private copy, $BIN_DIR)"
}

# ---------------------------------------------------------------- 3. download + verify

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else die "Neither shasum nor sha256sum is available; cannot verify the download."; fi
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

# Move the `current` pointer to a version directory and prove it resolves there.
#
# `mv` onto an existing symlink-to-a-directory follows the link and moves the source *inside* the
# target directory, so a plain `mv -f current.new current` only ever worked on a first install;
# on an upgrade it left `current` pointing at the old version with a stray `current.new` inside
# it. `mv -h` is the BSD spelling of "do not follow the destination", `-T` the GNU one; unlinking
# first is the portable last resort. Both the upgrade swap and the rollback go through here.
point_current_at() {
  _target=$1
  ln -sfn "$_target" "$INSTALL_ROOT/current.new"
  if ! mv -h "$INSTALL_ROOT/current.new" "$INSTALL_ROOT/current" 2>/dev/null \
     && ! mv -T "$INSTALL_ROOT/current.new" "$INSTALL_ROOT/current" 2>/dev/null; then
    if [ -e "$INSTALL_ROOT/current" ] && [ ! -L "$INSTALL_ROOT/current" ]; then
      rm -f "$INSTALL_ROOT/current.new"
      die "$INSTALL_ROOT/current is a real directory, not the version pointer." \
          "Move it aside and run the installer again."
    fi
    rm -f "$INSTALL_ROOT/current"
    mv "$INSTALL_ROOT/current.new" "$INSTALL_ROOT/current"
  fi
  _resolved=$(cd "$INSTALL_ROOT/current" 2>/dev/null && pwd -P || true)
  [ "$_resolved" = "$(cd "$_target" && pwd -P)" ] \
    || die "The 'current' pointer does not resolve to the installed version." \
           "expected $_target
     resolved $_resolved"
}

download_and_verify() {
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  if [ "$VERSION" = latest ]; then rel="$RELEASE_BASE/latest/download"; else rel="$RELEASE_BASE/download/$VERSION"; fi

  # One release carries one archive per architecture: the bundle ships Docker images, and an
  # arm64 image cannot run on an x86_64 host. detect_platform set PLATFORM_ARCH.
  archive="datacore-local-edition-${PLATFORM_ARCH}.tar.gz"
  info "downloading $VERSION ($PLATFORM_ARCH)"
  # A release can be published carrying only one architecture. The user on the other one sees a
  # download failure and has no way to tell it apart from a network problem, so name the release
  # and the architecture rather than leaving them to guess.
  fetch "$rel/$archive" "$TMP/$archive" || die \
    "Could not download $archive from $VERSION." \
    "Either the network is unavailable, or this release does not carry a build for $PLATFORM_ARCH." \
    "Check which architectures it has: $RELEASE_BASE/tag/$VERSION"
  fetch "$rel/SHA256SUMS" "$TMP/SHA256SUMS" || die "Could not download SHA256SUMS. Refusing to install an unverified archive."
  SUMS_FILE="$TMP/SHA256SUMS"

  want=$(grep " $archive\$" "$TMP/SHA256SUMS" | cut -d' ' -f1 || true)
  [ -n "$want" ] || die "SHA256SUMS does not list $archive." \
       "This release has no $PLATFORM_ARCH build. Published archives:
$(sed -n 's/^[0-9a-f]* \{1,2\}/       /p' "$TMP/SHA256SUMS")"
  got=$(sha256_of "$TMP/$archive")
  [ "$want" = "$got" ] || die "Checksum mismatch — refusing to install." "expected $want
     actual $got"
  ok "archive verified (sha256 ${got%"${got#??????????}"}…)"

  # Resolve the install we are replacing before the pointer moves. A new version lands in its own
  # directory with a template .env, so without this the upgrade would mint fresh secrets and no
  # longer match the existing database, bridge token or client tokens.
  if [ -d "$INSTALL_ROOT/current" ]; then
    PREVIOUS_DIR=$(cd "$INSTALL_ROOT/current" 2>/dev/null && pwd -P || true)
  fi

  mkdir -p "$INSTALL_ROOT/versions"
  tar -xzf "$TMP/$archive" -C "$INSTALL_ROOT/versions"
  # Take the bundle directory from the archive itself. Scanning versions/ and keeping the
  # lexically-last name picks the wrong install as soon as a second version is present — and
  # 0.1.9 sorts after 0.1.10 — so an upgrade, or a deliberate DATACORE_VERSION downgrade, would
  # configure and start a directory this run never unpacked.
  _name=$(tar -tzf "$TMP/$archive" | sed -n 's|^\(datacore-local-edition-[^/]*\)/.*|\1|p' | head -1)
  [ -n "$_name" ] || die "The archive did not contain a bundle directory."
  BUNDLE_DIR="$INSTALL_ROOT/versions/$_name"
  [ -d "$BUNDLE_DIR" ] || die "The archive did not unpack to $BUNDLE_DIR."

  point_current_at "$BUNDLE_DIR"
  # Same version re-installed, or no previous install: nothing to inherit.
  if [ "$PREVIOUS_DIR" = "$BUNDLE_DIR" ] || [ ! -f "$PREVIOUS_DIR/.env" ]; then PREVIOUS_DIR=''; fi
  if [ -n "$PREVIOUS_DIR" ]; then
    ok "installed $(basename "$BUNDLE_DIR") (upgrade from $(basename "$PREVIOUS_DIR"))"
  else
    ok "installed $(basename "$BUNDLE_DIR")"
  fi
}

# ---------------------------------------------------------------- 4. licence

# Record acceptance however it was given. Accepting through the environment used to leave no
# record, so a later `datacore update` — which sets no variables and has no terminal to prompt on
# — stopped with "cannot prompt for licence acceptance when piped".
record_eula_acceptance() {
  mkdir -p "$INSTALL_ROOT"
  printf '%s accepted-via=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$INSTALL_ROOT/.eula-accepted"
}

accept_eula() {
  [ -f "$INSTALL_ROOT/.eula-accepted" ] && { ok "licence already accepted"; return; }
  if [ "${DATACORE_ACCEPT_EULA:-0}" = 1 ]; then
    record_eula_acceptance environment
    ok "licence accepted (DATACORE_ACCEPT_EULA)"
    return
  fi
  eula="$BUNDLE_DIR/EULA.md"
  [ -f "$eula" ] && say "" && cat "$eula"
  [ -t 0 ] || die "Cannot prompt for licence acceptance when piped." "Re-run with DATACORE_ACCEPT_EULA=1 once you have read $eula"
  printf '\nAccept these terms? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) : ;; *) die "Licence not accepted." ;; esac
  record_eula_acceptance prompt
  ok "licence accepted"
}

# ---------------------------------------------------------------- 5. configure + start

prepare_env() {
  cd "$BUNDLE_DIR"
  if [ -n "$PREVIOUS_DIR" ]; then
    # The new bundle's update step merges its own template with the previous install's real values.
    # Touching .env here would make that step treat it as hand-edited and skip the merge.
    info "upgrade: configuration will be inherited from $(basename "$PREVIOUS_DIR")"
    return
  fi
  # Let the bundle write its own .env. It mints the six required identities
  # (DATACORE_{COORDINATOR,LOCAL_WORKER,GATEWAY,GATEWAY_CALLER,CLAUDE_DESKTOP,CLAUDE_CODE}_AGENT_ID)
  # along with its secrets, and only when .env is absent. Copying .env.example over it — which this
  # installer used to do — left all six empty, and the bundle's own preflight then refused to start
  # with "Missing DATACORE_COORDINATOR_AGENT_ID in bundle .env". That broke every install on a
  # genuinely clean machine.
  #
  # The generating run stops at preflight because the worker project map is not set yet, which is
  # the next thing this function does. Preflight runs before any docker work, so that first pass
  # costs nothing and leaves a complete .env behind; start_stack runs the same script again once the
  # map is in place.
  if [ ! -f .env ]; then
    _envlog="${TMPDIR:-/tmp}/datacore-env.$$.log"
    DATACORE_HOME="$DATA_HOME" DATACORE_LOCAL_EDITION_SKIP_DOCTOR_GATE=1 \
      ./install-datacore-local.sh >"$_envlog" 2>&1 || true
    if [ ! -f .env ]; then
      die "The bundle did not write its configuration." "$(tail -12 "$_envlog")

Full output: $_envlog"
    fi
    rm -f "$_envlog"
    info "generated configuration and identities"
  fi

  # The installer owns DATACORE_HOME; the user never sees it. Set it unconditionally rather than only
  # replacing the .env.example placeholder: the bundle's own generator writes
  # DATACORE_HOME=$HOME/.datacore-local, which is a path another Datacore install may already own, so
  # honouring it would point a new install at an existing install's data.
  if grep -q '^DATACORE_HOME=' .env 2>/dev/null; then
    tmp_env=$(mktemp)
    sed "s|^DATACORE_HOME=.*|DATACORE_HOME=$DATA_HOME|" .env > "$tmp_env" && mv "$tmp_env" .env
  else
    printf 'DATACORE_HOME=%s\n' "$DATA_HOME" >> .env
  fi
  # Create the bind-mount targets before anything starts. Docker creates a missing bind
  # source itself, as root, and then nothing running as the user can write into it -- which
  # is why generated executor profiles failed with EACCES on a fresh install while the
  # Coordinator quietly fell back to the example list baked into the image.
  mkdir -p "$DATA_HOME" "$DATA_HOME/coordinator" "$DATA_HOME/runtime"

  # The bundle's preflight hard-fails without a worker project map, even though a minimal
  # install never reads it. Supply a valid default so the user is never asked to write JSON.
  if ! grep -q '^DATACORE_WORKER_PROJECT_WORKSPACES=.\+' .env 2>/dev/null; then
    printf '\nDATACORE_WORKER_PROJECT_WORKSPACES=%s\n' "'{\"default\":\"$HOME\"}'" >> .env
    info "set a placeholder worker project map (edit DATACORE_WORKER_PROJECT_WORKSPACES in .env)"
  fi

  # Compose derives its project name from the directory, which is the 'current' symlink. Pinning it
  # stops a hand-run 'docker compose' here from forking a second stack. It does not rename the
  # bundle's own stack, which uses a fixed project name of its own.
  grep -q '^COMPOSE_PROJECT_NAME=' .env || printf 'COMPOSE_PROJECT_NAME=%s\n' "$COMPOSE_PROJECT" >> .env
  # COMPOSE_PROJECT_NAME in .env only governs a hand-run `docker compose` in the bundle directory.
  # The bundle's own scripts read DATACORE_LOCAL_COMPOSE_PROJECT, so without exporting it the
  # DATACORE_COMPOSE_PROJECT knob renamed nothing and two installs still drove one set of
  # containers: the second install reconciled the first install's running stack to its own config.
  # The default is unchanged, so an existing install's containers keep their names across an upgrade.
  DATACORE_LOCAL_COMPOSE_PROJECT="$COMPOSE_PROJECT"; export DATACORE_LOCAL_COMPOSE_PROJECT
  ok "configuration prepared (nothing for you to edit)"
}

start_stack() {
  cd "$BUNDLE_DIR"
  if [ -n "$PREVIOUS_DIR" ]; then
    # The bundle's own upgrade path: start this version's .env from its template, inherit the
    # previous install's secrets and generated state, install, then relabel client config.
    _cmd=./update-datacore-local.sh; set -- "$PREVIOUS_DIR"
  elif [ -f "$DATA_HOME/.last-good-bundle" ]; then
    _cmd=./start-datacore-local.sh; set --
  else
    _cmd=./install-datacore-local.sh; set --
  fi

  # Two things about this call. The bundle's doctor gate fails when the claude or codex CLI is
  # merely absent, but worker families are opt-in, so skip that gate and apply our own below —
  # a real inconsistency still stops the install. And keep the output: "run doctor.sh" is useless
  # advice when the reason is already on screen, and doctor cannot explain a failure that happened
  # while loading images.
  _log="${TMPDIR:-/tmp}/datacore-start.$$.log"
  if ! DATACORE_LOCAL_EDITION_SKIP_DOCTOR_GATE=1 "$_cmd" "$@" >"$_log" 2>&1; then
    # An upgrade that cannot start must not leave `current` pointing at the new version: put the
    # pointer back so `datacore start` and the login agent keep using the install that worked.
    if [ -n "$PREVIOUS_DIR" ]; then
      point_current_at "$PREVIOUS_DIR"
      die "The upgrade failed; rolled back to $(basename "$PREVIOUS_DIR")." "$(tail -12 "$_log")

Full output: $_log
The previous version is still installed. Start it with: datacore start"
    fi
    die "Datacore failed to start." "$(tail -12 "$_log")

Full output: $_log
Diagnose:    $BIN_DIR/datacore doctor"
  fi
  rm -f "$_log"

  port=$(grep '^DATACORE_HTTP_PORT=' .env | cut -d= -f2)
  RUNTIME_URL="http://127.0.0.1:${port:-53123}"
  i=0
  while [ $i -lt 60 ]; do
    curl -fsS -m 3 "$RUNTIME_URL/health" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
  done
  [ $i -lt 60 ] || die "Datacore started but never reported healthy." "Run: $BIN_DIR/datacore doctor"
  ok "runtime healthy at $RUNTIME_URL"
  gate_on_doctor
}

# Checks that only describe an unconfigured optional worker CLI. Everything else is blocking.
WORKER_LAUNCHER_CHECK='^bridge_dispatch:launcher:'

# ---------------------------------------------------------------- 5b. trim the worker registry
#
# The bundle writes its worker registry as the full cartesian product of worker CLI x model alias x
# role: 29 entries, every one with a live token, on a machine that may have none of those CLIs
# installed. Fourteen of them are for a CLI the bundle's own catalogue flags as outside the default
# profile. That is not a configuration anybody chose, and it is the first thing a new user sees when
# they ask what workers they have.
#
# `datacore worker prune` keeps one worker per default-profile family, for the CLIs actually
# installed here, and moves the rest to a catalogue file beside the registry so `datacore worker
# add` can enable any of them later without minting anything.
lean_workers() {
  _w="$BIN_DIR/lib/worker.sh"
  if [ ! -f "$_w" ]; then
    info "worker registry left as generated — this release does not carry lib/worker.sh"
    return 0
  fi
  # An older lib/worker.sh has no `prune` verb. Losing the trim is cosmetic, so report and move on
  # rather than fail an install whose runtime is already up and healthy.
  if ! _out=$(DATACORE_INSTALL_ROOT="$INSTALL_ROOT" DATACORE_HOME="$DATA_HOME" sh "$_w" prune 2>/dev/null); then
    info "worker registry left as generated (trim it with: datacore worker prune)"
    return 0
  fi
  printf '%s\n' "$_out"
  # Executor profiles are what the Coordinator dispatches from, and they used to be written only
  # as a side effect of enabling a worker through this helper. An install whose registry came
  # from the bundle's generator produced none, so the Coordinator silently fell back to the
  # example list in the image and workers outside it were undispatchable. Sync unconditionally:
  # it is idempotent, and it makes the profiles agree with the registry however the registry
  # was produced. An older helper has no `sync` verb, so a failure here is reported, not fatal.
  if ! DATACORE_INSTALL_ROOT="$INSTALL_ROOT" DATACORE_HOME="$DATA_HOME" sh "$_w" sync >/dev/null 2>&1; then
    info "executor profiles not synced (this release's lib/worker.sh has no 'sync')"
  fi
  _n=$(printf '%s\n' "$_out" | sed -n 's/^  \([0-9]\{1,\}\) worker(s) enabled.*/\1/p' | tail -1)
  if [ "${_n:-0}" = 0 ]; then
    WORKERS_SUMMARY="none — no worker CLI installed (claude, codex, agy)"
  else
    WORKERS_SUMMARY="$_n enabled"
  fi
}

gate_on_doctor() {
  _dlog="${TMPDIR:-/tmp}/datacore-doctor.$$.log"
  "$BUNDLE_DIR/doctor.sh" >"$_dlog" 2>&1 || true
  _fails=$(grep ' FAIL ' "$_dlog" | sed 's/.* FAIL //' | awk '{print $1}' || true)
  _blocking=$(printf '%s\n' "$_fails" | grep -v "$WORKER_LAUNCHER_CHECK" | grep -v '^$' || true)
  _workers=$(printf '%s\n' "$_fails" | grep "$WORKER_LAUNCHER_CHECK" | grep -c . || true)

  if [ -n "$_blocking" ]; then
    die "Datacore started, but doctor reports a problem." "$_blocking

Full report: $_dlog
Re-run:      $BIN_DIR/datacore doctor"
  fi
  rm -f "$_dlog"
  if [ "${_workers:-0}" -gt 0 ]; then
    ok "doctor: no blocking failures ($_workers optional worker CLI not installed)"
  else
    ok "doctor: no blocking failures"
  fi
}

# ---------------------------------------------------------------- 6. register AI clients

# Probe (token, bundle) with a real JSON-RPC initialize. Which tool bundle a minted token may use
# depends on the identity it authenticates as, which varies between installs, so never assume:
# try the richest bundle first and register only what a real handshake accepts.
mcp_bundle_works() {
  curl -fsS -m 10 -X POST "$RUNTIME_URL/mcp" \
    -H "Authorization: Bearer $1" \
    -H "X-Datacore-MCP-Tool-Bundle: $2" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"datacore-install","version":"1"}}}' \
    2>/dev/null | grep -q '"result"'
}

register_clients() {
  if [ "${DATACORE_SKIP_CLIENT_REGISTRATION:-0}" = 1 ]; then
    info "skipping client registration (DATACORE_SKIP_CLIENT_REGISTRATION)"
    return
  fi
  tokens="$BUNDLE_DIR/generated/client-tokens.env"
  [ -f "$tokens" ] || { info "no client tokens generated; skipping client registration"; return; }
  # shellcheck disable=SC1090
  set -a; . "$tokens"; set +a

  BUNDLE=''
  for candidate in lifecycle_operator front_door; do
    if mcp_bundle_works "$CLAUDE_CODE_TOKEN" "$candidate"; then BUNDLE="$candidate"; break; fi
  done
  [ -n "$BUNDLE" ] && ok "verified MCP access (bundle: $BUNDLE)" \
                   || { info "no tool bundle this identity may use; skipping registration"; return; }

  if command -v claude >/dev/null 2>&1; then
    claude mcp remove datacore -s user >/dev/null 2>&1 || true
    if claude mcp add --transport http --scope user datacore "$RUNTIME_URL/mcp" \
         --header "Authorization: Bearer $CLAUDE_CODE_TOKEN" \
         --header "X-Datacore-MCP-Tool-Bundle: $BUNDLE" >/dev/null 2>&1; then
      ok "registered with Claude Code"; REGISTERED='Claude Code'
    else
      info "could not register with Claude Code"
    fi
  else
    info "Claude Code not found — run 'datacore connect' after installing it"
  fi

  if [ -d "$HOME/Library/Application Support/Claude" ] && [ -x "$BUNDLE_DIR/write-claude-desktop-config.sh" ]; then
    "$BUNDLE_DIR/write-claude-desktop-config.sh" >/dev/null 2>&1 \
      && { ok "registered with Claude Desktop"; REGISTERED="${REGISTERED:+$REGISTERED, }Claude Desktop"; } \
      || info "could not register with Claude Desktop"
  fi
}

# ---------------------------------------------------------------- 7. front-door command

# The front door is three files: the `datacore` dispatcher and the two lib scripts it execs for
# `provider` and `worker`. Installing only the dispatcher leaves those verbs dead, so place all
# three. Prefer siblings of this script (local run / dev); otherwise take them from the release.
CLI_FILES="datacore lib/provider.sh lib/worker.sh lib/uninstall.sh lib/uninstall-desktop-entry.py"

install_command() {
  mkdir -p "$BIN_DIR/lib"
  if [ "$VERSION" = latest ]; then _rel="$RELEASE_BASE/latest/download"
  else _rel="$RELEASE_BASE/download/$VERSION"; fi

  # `datacore` itself has to be there; the lib/ helpers back one verb each. This script is served
  # from main, so it can name a helper a release does not carry yet — losing `datacore uninstall`
  # on such a release is worth reporting, not worth aborting an install whose stack is already up.
  _downloaded=0
  _missing=''
  for _f in $CLI_FILES; do
    case "$_f" in datacore) _required=1 ;; *) _required=0 ;; esac
    # Under `curl | sh` there is no script file: $0 is "sh", so dirname gives the user's CWD and a
    # stray file of the same name there would be installed. Only trust a sibling when $0 is a file.
    if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$_f" ]; then
      cp "$SELF_DIR/$_f" "$BIN_DIR/$_f"
      continue
    fi
    _name=$(basename "$_f")
    _why=''
    # An optional helper a release does not carry is reported by the line below, so keep curl's own
    # "404" off the screen; a required file still shows curl's reason before the install stops.
    if [ "$_required" = 1 ]; then _fetch_err=/dev/stderr; else _fetch_err=/dev/null; fi
    if ! fetch "$_rel/$_name" "$BIN_DIR/$_f" 2>"$_fetch_err"; then
      _why="this release does not carry $_name"
    else
      # These land on the user's PATH, so hold them to the same standard as the archive.
      _want=$(grep " $_name\$" "$SUMS_FILE" 2>/dev/null | cut -d' ' -f1 || true)
      _got=$(sha256_of "$BIN_DIR/$_f")
      if [ -z "$_want" ]; then _why="SHA256SUMS does not list $_name"
      elif [ "$_want" != "$_got" ]; then _why="checksum mismatch on $_name (expected $_want, actual $_got)"
      fi
    fi
    if [ -z "$_why" ]; then
      _downloaded=1
      continue
    fi
    rm -f "$BIN_DIR/$_f"
    [ "$_required" = 0 ] || die "Could not install $_name: $_why." \
        "Check your network, or re-run the installer."
    _missing="${_missing:+$_missing, }$_name"
  done
  chmod +x "$BIN_DIR/datacore"

  if [ "$_downloaded" = 1 ]; then info "downloaded the datacore command from the release"; fi
  ok "installed the datacore command to $BIN_DIR"
  if [ -n "$_missing" ]; then
    warn "not installed: $_missing — the matching 'datacore' subcommand will say it is unavailable"
  fi
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) info "add to PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
}

# ---------------------------------------------------------------- 7. autostart at login
#
# Without this, Datacore only runs when the user remembers to start it — and an AI client launched
# while it is down cannot reach the MCP server for that entire session, with no way to recover but
# restarting the client. So autostart is the default, not an extra.
#
# The bundle ships a launchd agent, but its plist hardcodes a PATH of homebrew and system
# directories. Every bundle script is `exec bun`, and a machine that had no bun got a private copy
# in $BIN_DIR, which is on none of those paths — so the agent would fail at every login with
# "exec: bun: not found". Install it, then prepend the directories that actually hold bun and the
# worker CLIs.
install_login_agent() {
  [ "${DATACORE_SKIP_LOGIN_AGENT:-0}" = 1 ] && { info "autostart skipped (DATACORE_SKIP_LOGIN_AGENT)"; return 0; }
  if [ "$PLATFORM_OS" != darwin ]; then
    info "autostart at login is macOS-only here; start it yourself with: datacore start"
    return 0
  fi
  _agent="$BUNDLE_DIR/install-macos-login-agent.sh"
  [ -x "$_agent" ] || { info "this bundle ships no login agent; start with: datacore start"; return 0; }

  _plist="$HOME/Library/LaunchAgents/com.datacore.local-edition.plist"
  _alog="${TMPDIR:-/tmp}/datacore-login-agent.$$.log"
  if ! ( cd "$BUNDLE_DIR" && "$_agent" ) >"$_alog" 2>&1; then
    warn "could not install the login agent; start Datacore yourself with: datacore start"
    info "$(tail -2 "$_alog" | tr '\n' ' ')"
    rm -f "$_alog"; return 0
  fi
  rm -f "$_alog"

  if [ -f "$_plist" ] && command -v plutil >/dev/null 2>&1; then
    _bun=$(command -v bun 2>/dev/null || true)
    [ -n "$_bun" ] && _bundir=$(dirname "$_bun") || _bundir="$BIN_DIR"
    _oldpath=$(plutil -extract EnvironmentVariables.PATH raw "$_plist" 2>/dev/null || true)
    [ -n "$_oldpath" ] || _oldpath="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    case ":$_oldpath:" in
      *":$_bundir:"*) ;;
      *)
        if plutil -replace EnvironmentVariables.PATH -string "$_bundir:$HOME/.local/bin:$_oldpath" "$_plist" 2>/dev/null; then
          _uid=$(id -u)
          launchctl bootout "gui/$_uid" "$_plist" >/dev/null 2>&1 || true
          launchctl bootstrap "gui/$_uid" "$_plist" >/dev/null 2>&1 || true
        else
          warn "could not add $_bundir to the login agent PATH; it may fail to start at login"
        fi
        ;;
    esac
  fi
  ok "starts automatically at login (remove it with: datacore uninstall)"
}

# ---------------------------------------------------------------- main

main() {
  say ""; say "${B}Installing Datacore${R}"
  step "Checking your machine";      detect_platform; ensure_container_runtime; ensure_bun
  step "Downloading";                download_and_verify
  step "Licence";                    accept_eula
  step "Installing the command";     install_command
  step "Configuring";                prepare_env
  if [ "${DATACORE_SKIP_START:-0}" = 1 ]; then
    step "Starting"; info "skipped (DATACORE_SKIP_START)"; RUNTIME_URL="(not started)"
  else
    step "Starting"; start_stack
  fi
  step "Workers";                    lean_workers
  step "Connecting your AI clients"; register_clients
  step "Finishing";                  install_login_agent

  ver=$(basename "$BUNDLE_DIR" | sed 's/^datacore-local-edition-//')
  cat <<EOF

${B}✓ Datacore $ver is running${R}

  Runtime    $RUNTIME_URL
  MCP        ${REGISTERED:-not registered}
  Workers    ${WORKERS_SUMMARY}
  Gateway    off

  Next: restart ${REGISTERED:-your AI client}, then ask it "what tasks do I have?"
  Later: datacore worker list    (see them), datacore worker add <name>    (enable more)

EOF
}

main "$@"
