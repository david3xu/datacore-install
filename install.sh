#!/bin/sh
# Datacore installer.
#
# Usage:  curl -fsSL https://get.datacore.dev | sh
#
# Environment overrides:
#   DATACORE_VERSION        version to install (default: latest)
#   DATACORE_RELEASE_BASE   base URL for release artifacts
#   DATACORE_INSTALL_ROOT   where versions are kept (default: ~/.datacore)
#   DATACORE_HOME           runtime data directory (default: ~/.datacore-local)
#   DATACORE_ACCEPT_EULA=1  skip the interactive licence prompt (CI)
#   DATACORE_COMPOSE_PROJECT         compose project name (default: datacore-local)
#   DATACORE_SKIP_CLIENT_REGISTRATION=1  do not touch AI client config (proof runs)
#   DATACORE_SKIP_START=1   install and configure, but start no containers (proof runs)
#
# NOTE: step 3 (download) requires the release pipeline (work unit D1). Until a release is
# published, this script fails at that step with a clear message. Every other step is live.

set -eu

VERSION="${DATACORE_VERSION:-latest}"
RELEASE_BASE="${DATACORE_RELEASE_BASE:-https://github.com/david3xu/datacore-install/releases}"
INSTALL_ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
DATA_HOME="${DATACORE_HOME:-$HOME/.datacore-local}"
COMPOSE_PROJECT="${DATACORE_COMPOSE_PROJECT:-datacore-local}"
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

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then B=$(printf '\033[1m'); D=$(printf '\033[2m'); R=$(printf '\033[0m'); else B=''; D=''; R=''; fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$B" "$R" "$*"; }
info() { printf '  %s·%s %s\n' "$D" "$R" "$*"; }
die()  { printf '\n%sInstall stopped.%s %s\n\n' "$B" "$R" "$1" >&2; [ $# -gt 1 ] && printf '%s\n\n' "$2" >&2; exit 1; }
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

download_and_verify() {
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  if [ "$VERSION" = latest ]; then rel="$RELEASE_BASE/latest/download"; else rel="$RELEASE_BASE/download/$VERSION"; fi

  # One release carries one archive per architecture: the bundle ships Docker images, and an
  # arm64 image cannot run on an x86_64 host. detect_platform set PLATFORM_ARCH.
  archive="datacore-local-edition-${PLATFORM_ARCH}.tar.gz"
  info "downloading $VERSION ($PLATFORM_ARCH)"
  fetch "$rel/$archive"   "$TMP/$archive"  || die "Could not download the release archive."
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

  mkdir -p "$INSTALL_ROOT/versions"
  tar -xzf "$TMP/$archive" -C "$INSTALL_ROOT/versions"
  BUNDLE_DIR=$(find "$INSTALL_ROOT/versions" -maxdepth 1 -name 'datacore-local-edition-*' -type d | sort | tail -1)
  [ -n "$BUNDLE_DIR" ] || die "The archive did not contain a bundle directory."

  # Write the pointer atomically, then prove it resolves to the version we just unpacked.
  ln -sfn "$BUNDLE_DIR" "$INSTALL_ROOT/current.new"
  mv -f "$INSTALL_ROOT/current.new" "$INSTALL_ROOT/current"
  resolved=$(cd "$INSTALL_ROOT/current" 2>/dev/null && pwd -P || true)
  [ "$resolved" = "$(cd "$BUNDLE_DIR" && pwd -P)" ] \
    || die "The 'current' pointer does not resolve to the installed version." \
           "expected $BUNDLE_DIR
     resolved $resolved"
  ok "installed $(basename "$BUNDLE_DIR")"
}

# ---------------------------------------------------------------- 4. licence

accept_eula() {
  [ "${DATACORE_ACCEPT_EULA:-0}" = 1 ] && { ok "licence accepted (DATACORE_ACCEPT_EULA)"; return; }
  [ -f "$INSTALL_ROOT/.eula-accepted" ] && { ok "licence already accepted"; return; }
  eula="$BUNDLE_DIR/EULA.md"
  [ -f "$eula" ] && say "" && cat "$eula"
  [ -t 0 ] || die "Cannot prompt for licence acceptance when piped." "Re-run with DATACORE_ACCEPT_EULA=1 once you have read $eula"
  printf '\nAccept these terms? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) : ;; *) die "Licence not accepted." ;; esac
  date -u +%Y-%m-%dT%H:%M:%SZ > "$INSTALL_ROOT/.eula-accepted"
  ok "licence accepted"
}

# ---------------------------------------------------------------- 5. configure + start

prepare_env() {
  cd "$BUNDLE_DIR"
  [ -f .env ] || cp .env.example .env

  # DATACORE_HOME ships as a change-me placeholder; the installer owns it, the user never sees it.
  if grep -q '^DATACORE_HOME=change-me' .env 2>/dev/null; then
    tmp_env=$(mktemp)
    sed "s|^DATACORE_HOME=change-me.*|DATACORE_HOME=$DATA_HOME|" .env > "$tmp_env" && mv "$tmp_env" .env
  fi
  mkdir -p "$DATA_HOME"

  # The bundle's preflight hard-fails without a worker project map, even though a minimal
  # install never reads it. Supply a valid default so the user is never asked to write JSON.
  if ! grep -q '^DATACORE_WORKER_PROJECT_WORKSPACES=.\+' .env 2>/dev/null; then
    printf '\nDATACORE_WORKER_PROJECT_WORKSPACES=%s\n' "'{\"default\":\"$HOME\"}'" >> .env
    info "set a default worker workspace map (change it with: datacore worker add)"
  fi

  # Compose derives its project name from the directory, which is the 'current' symlink.
  # Pinning it stops a hand-run 'docker compose' from forking a second stack.
  grep -q '^COMPOSE_PROJECT_NAME=' .env || printf 'COMPOSE_PROJECT_NAME=%s\n' "$COMPOSE_PROJECT" >> .env
  ok "configuration prepared (nothing for you to edit)"
}

start_stack() {
  cd "$BUNDLE_DIR"
  if [ -f "$DATA_HOME/.last-good-bundle" ]; then _cmd=./start-datacore-local.sh
  else _cmd=./install-datacore-local.sh; fi

  # Keep the output: "run doctor.sh" is useless advice when the reason is already on screen, and
  # doctor cannot explain a failure that happened while loading images.
  _log="${TMPDIR:-/tmp}/datacore-start.$$.log"
  if ! "$_cmd" >"$_log" 2>&1; then
    die "Datacore failed to start." "$(tail -12 "$_log")

Full output: $_log
Diagnose:    $BUNDLE_DIR/doctor.sh"
  fi
  rm -f "$_log"

  port=$(grep '^DATACORE_HTTP_PORT=' .env | cut -d= -f2)
  RUNTIME_URL="http://127.0.0.1:${port:-53123}"
  i=0
  while [ $i -lt 60 ]; do
    curl -fsS -m 3 "$RUNTIME_URL/health" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 1
  done
  [ $i -lt 60 ] || die "Datacore started but never reported healthy." "Run: $BUNDLE_DIR/doctor.sh"
  ok "runtime healthy at $RUNTIME_URL"
}

# ---------------------------------------------------------------- 6. register AI clients

# Probe (token, bundle) with a real JSON-RPC initialize. The bundle shipped in 0.1.76 requests
# a bundle its own minted token is not granted, so never assume — try richest first and verify.
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
CLI_FILES="datacore lib/provider.sh lib/worker.sh"

install_command() {
  mkdir -p "$BIN_DIR/lib"
  if [ "$VERSION" = latest ]; then _rel="$RELEASE_BASE/latest/download"
  else _rel="$RELEASE_BASE/download/$VERSION"; fi

  _downloaded=0
  for _f in $CLI_FILES; do
    # Under `curl | sh` there is no script file: $0 is "sh", so dirname gives the user's CWD and a
    # stray file of the same name there would be installed. Only trust a sibling when $0 is a file.
    if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/$_f" ]; then
      cp "$SELF_DIR/$_f" "$BIN_DIR/$_f"
    else
      _name=$(basename "$_f")
      fetch "$_rel/$_name" "$BIN_DIR/$_f" \
        || die "Could not download $_name from the release." \
               "Check your network, or re-run the installer."
      # These land on the user's PATH, so hold them to the same standard as the archive.
      _want=$(grep " $_name\$" "$SUMS_FILE" 2>/dev/null | cut -d' ' -f1 || true)
      [ -n "$_want" ] || { rm -f "$BIN_DIR/$_f"; die "SHA256SUMS does not list $_name." \
        "This release is incomplete; nothing was added to your PATH."; }
      _got=$(sha256_of "$BIN_DIR/$_f")
      [ "$_want" = "$_got" ] || { rm -f "$BIN_DIR/$_f"; die "Checksum mismatch on $_name — refusing to install." \
        "expected $_want
     actual $_got"; }
      _downloaded=1
    fi
  done
  chmod +x "$BIN_DIR/datacore"

  if [ "$_downloaded" = 1 ]; then info "downloaded the datacore command from the release"; fi
  ok "installed the datacore command to $BIN_DIR"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) info "add to PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
}

# ---------------------------------------------------------------- main

main() {
  say ""; say "${B}Installing Datacore${R}"
  step "Checking your machine";      detect_platform; ensure_container_runtime; ensure_bun
  step "Downloading";                download_and_verify
  step "Licence";                    accept_eula
  step "Configuring";                prepare_env
  if [ "${DATACORE_SKIP_START:-0}" = 1 ]; then
    step "Starting"; info "skipped (DATACORE_SKIP_START)"; RUNTIME_URL="(not started)"
  else
    step "Starting"; start_stack
  fi
  step "Connecting your AI clients"; register_clients
  step "Finishing";                  install_command

  ver=$(basename "$BUNDLE_DIR" | sed 's/^datacore-local-edition-//')
  cat <<EOF

${B}✓ Datacore $ver is running${R}

  Runtime    $RUNTIME_URL
  MCP        ${REGISTERED:-not registered}
  Profile    minimal — workers off, gateway off

  Next: restart ${REGISTERED:-your AI client}, then ask it "what tasks do I have?"
  Later: datacore worker add codex    (let Datacore drive coding agents)

EOF
}

main "$@"
