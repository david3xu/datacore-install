#!/bin/sh
# Datacore uninstall — undo everything the installer did.
#
# Usage (via datacore front door):
#   datacore uninstall [--purge-data] [--purge-images] [--yes]
#
# The bundle's own uninstall removes containers and stops helpers. It does not remove the MCP
# entries the installer wrote into AI clients, the macOS login agent, the loaded images, or the
# install tree itself — so this does those, and the two together make "uninstall" mean it.
#
# Environment overrides:
#   DATACORE_INSTALL_ROOT   where versions are kept (default: ~/.datacore)

set -eu

LIB_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || LIB_DIR=.
ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
C="$ROOT/current"
LOGIN_AGENT_LABEL=com.datacore.local-edition

PURGE_DATA=0
PURGE_IMAGES=0
ASSUME_YES=0
usage() {
  cat <<'USAGE'
Usage: datacore uninstall [options]

Removes the containers, the MCP entry this install added to your AI clients, the macOS
login agent, and the install itself. Your data directory is kept unless you ask for it.

  --purge-data     also delete the data directory (asks first, unless --yes)
  --purge-images   also delete the Datacore container images
  --yes, -y        do not ask for confirmation
  -h, --help       show this
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --purge-data)   PURGE_DATA=1 ;;
    --purge-images) PURGE_IMAGES=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) printf 'datacore uninstall: unknown option %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- output helpers

# Prints every argument, one per line: a die() that printed only "$1" silently dropped the
# explanation lines its callers pass, leaving the user a bare refusal and no remedy.
die()  { while [ $# -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done; exit 1; }
say()  { printf '%s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
step() { printf '\n%s\n' "$*"; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || die "Cannot prompt here. Re-run with --yes once you are sure: $1"
  printf '%s [y/N] ' "$1"
  read -r reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- what is installed

BUNDLE_DIR=''
[ -d "$C" ] && BUNDLE_DIR=$(cd "$C" 2>/dev/null && pwd -P || true)

DATA_HOME="${DATACORE_HOME:-}"
if [ -z "$DATA_HOME" ] && [ -n "$BUNDLE_DIR" ] && [ -f "$BUNDLE_DIR/.env" ]; then
  DATA_HOME=$(grep '^DATACORE_HOME=' "$BUNDLE_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
# Deliberately no fallback. The old default was the fixed $HOME/.datacore-local, which several
# installs could share -- so an uninstall whose own .env had gone missing would aim --purge-data
# at whichever install owned that path. Guessing is fine for reporting and fatal for deleting, so
# an unknown data directory is left empty and purge_data refuses rather than picking one.
DATA_HOME_KNOWN=1
[ -n "$DATA_HOME" ] || DATA_HOME_KNOWN=0

[ -n "$BUNDLE_DIR" ] || [ -d "$ROOT" ] || die "Datacore is not installed at $ROOT; nothing to remove."

# ---------------------------------------------------------------- 1. containers and helpers

remove_containers() {
  if [ -n "$BUNDLE_DIR" ] && [ -x "$BUNDLE_DIR/uninstall-datacore-local.sh" ]; then
    if "$BUNDLE_DIR/uninstall-datacore-local.sh" >/dev/null 2>&1; then
      ok "containers removed, helpers stopped"
    else
      info "the bundle's uninstall reported a problem; continuing"
    fi
  else
    info "no installed bundle found; skipping container removal"
  fi
}

# ---------------------------------------------------------------- 2. AI client registration

# Only disconnect a registration that points at THIS install. A second install on another port
# must keep working, and a user who removes a test install should not lose their real one.
remove_client_entries() {
  port=''
  [ -n "$BUNDLE_DIR" ] && [ -f "$BUNDLE_DIR/.env" ] \
    && port=$(grep '^DATACORE_HTTP_PORT=' "$BUNDLE_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2 || true)
  [ -n "$port" ] || port=43123
  url="http://127.0.0.1:$port/mcp"
  removed=''

  if command -v claude >/dev/null 2>&1; then
    entry=$(claude mcp get datacore 2>/dev/null || true)
    case "$entry" in
      *"$url"*)
        # The scope matters: an entry added per-project cannot be removed with -s user. `claude mcp
        # get` prints the exact removal command, so take the scope from there rather than guessing.
        scope=$(printf '%s\n' "$entry" | sed -n 's/.*claude mcp remove datacore -s \([a-z]*\).*/\1/p' | head -1)
        [ -n "$scope" ] || scope=user
        claude mcp remove datacore -s "$scope" >/dev/null 2>&1 && removed='Claude Code'
        ;;
      *) if [ -n "$entry" ]; then info "left the Claude Code entry alone; it points at another install"; fi ;;
    esac
  fi

  cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  if [ -f "$cfg" ] && grep -q '"datacore"' "$cfg" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1; then
      cp "$cfg" "$cfg.datacore-uninstall-backup"
      _derr=$(python3 "$LIB_DIR/uninstall-desktop-entry.py" "$cfg" "$port" 2>&1); _dstatus=$?
      # The exit code matters: discarding the backup on *any* failure threw it away in the one
      # case it is needed -- a rewrite that did not complete.
      case "$_dstatus" in
        0) removed="${removed:+$removed, }Claude Desktop"
           # Keep the backup. We just edited a file holding the user's other MCP servers; if we
           # matched the wrong entry, this is their only way back.
           _desktop_backup="$cfg.datacore-uninstall-backup" ;;
        1) rm -f "$cfg.datacore-uninstall-backup"
           info "left the Claude Desktop entry alone; it does not point at this install" ;;
        *) warn "could not remove the Claude Desktop entry from $cfg"
           [ -n "$_derr" ] && say "  $_derr"
           say "  Your configuration was backed up first: $cfg.datacore-uninstall-backup"
           say "  Compare the two, then remove the \"datacore\" entry yourself." ;;
      esac
    else
      info "python3 not available; remove the \"datacore\" entry from $cfg yourself"
    fi
  fi

  if [ -n "$removed" ]; then
    ok "removed the Datacore entry from $removed"
    [ -n "${_desktop_backup:-}" ] && info "previous Claude Desktop config kept at $_desktop_backup"
  else
    info "no AI client entry for this install"
  fi
}

# ---------------------------------------------------------------- 3. macOS login agent

remove_login_agent() {
  [ "$(uname -s)" = Darwin ] || return 0
  plist="$HOME/Library/LaunchAgents/$LOGIN_AGENT_LABEL.plist"
  [ -f "$plist" ] || { info "no login agent installed"; return 0; }
  launchctl bootout "gui/$(id -u)/$LOGIN_AGENT_LABEL" >/dev/null 2>&1 \
    || launchctl unload "$plist" >/dev/null 2>&1 || true
  rm -f "$plist"
  ok "login agent removed"
}

# ---------------------------------------------------------------- 4. images

remove_images() {
  [ "$PURGE_IMAGES" = 1 ] || { info "images kept (remove them with --purge-images)"; return 0; }
  command -v docker >/dev/null 2>&1 || return 0
  count=0
  for image in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
                 | grep -E '^datacore-local-(runtime|coordinator|gateway):' || true); do
    docker rmi -f "$image" >/dev/null 2>&1 && count=$((count + 1))
  done
  ok "removed $count Datacore image(s); shared images such as postgres were left alone"
}

# ---------------------------------------------------------------- 5. data

# Refuse to hand rm -rf anything that is not recognisably a Datacore data directory. The removal
# below also runs as root inside a container with the parent directory mounted, so a wrong value
# here is not a small mistake.
assert_safe_to_delete() {
  _t=$1
  case "$_t" in
    /|"$HOME"|"$HOME"/|/usr|/etc|/var|/opt|/home|/Users|"") 
      die "Refusing to delete $_t: that is not a Datacore data directory." ;;
    /*) ;;
    *)  die "Refusing to delete a relative path: $_t" ;;
  esac
  # A Datacore data directory carries the runtime's own state. Requiring one of these means a
  # misconfigured DATACORE_HOME pointing at, say, a documents folder is refused rather than erased.
  for _m in postgres runtime coordinator; do
    [ -e "$_t/$_m" ] && return 0
  done
  die "Refusing to delete $_t: it does not look like a Datacore data directory." \
      "Expected one of postgres/, runtime/ or coordinator/ inside it." \
      "If you are certain, remove it yourself."
}

remove_data() {
  # Establish *which* directory before asking whether it exists: an unknown location used to
  # fall back to the shared $HOME/.datacore-local, which another install may own.
  if [ "$DATA_HOME_KNOWN" != 1 ]; then
    if [ "$PURGE_DATA" = 1 ]; then
      die "Cannot find this install's data directory, so --purge-data has nothing it can safely delete." \
          "The install's .env is missing or unreadable. Pass DATACORE_HOME=<path> to say which" \
          "directory to remove, after checking it is the right one."
    fi
    info "data directory unknown (this install's .env is missing); nothing removed"
    return 0
  fi
  [ -d "$DATA_HOME" ] || { info "no data directory at $DATA_HOME"; return 0; }

  size=$(du -sh "$DATA_HOME" 2>/dev/null | cut -f1)
  if [ "$PURGE_DATA" != 1 ]; then
    info "data kept at $DATA_HOME ($size)"
    info "remove it with: datacore uninstall --purge-data"
    return 0
  fi
  confirm "Permanently delete your Datacore data at $DATA_HOME ($size)? This cannot be undone." \
    || { info "data kept at $DATA_HOME"; return 0; }
  assert_safe_to_delete "$DATA_HOME"
  # Postgres writes as root inside its container, so parts of the tree are root-owned and a plain
  # rm fails. Do the removal from a container, which runs as root, before falling back to sudo.
  if ! rm -rf "$DATA_HOME" 2>/dev/null; then
    parent=$(dirname "$DATA_HOME"); base=$(basename "$DATA_HOME")
    if command -v docker >/dev/null 2>&1 \
       && docker run --rm -v "$parent:/host" alpine:3.20 rm -rf "/host/$base" >/dev/null 2>&1; then
      :
    else
      die "Could not remove $DATA_HOME — parts of it are owned by root.
Remove it yourself with:  sudo rm -rf \"$DATA_HOME\""
    fi
  fi
  ok "data removed"
}

# ---------------------------------------------------------------- 6. the install itself

remove_install_tree() {
  # This script lives inside the tree it is deleting. POSIX keeps a running script's file alive
  # through unlink, so the removal completes; nothing below may read from the tree afterwards.
  rm -rf "$ROOT/versions" "$ROOT/current" "$ROOT/bin" "$ROOT/.eula-accepted"
  rmdir "$ROOT" 2>/dev/null || true
  ok "install tree removed from $ROOT"
}

# ---------------------------------------------------------------- main

say ""
say "Uninstalling Datacore"
step "Stopping and removing containers"; remove_containers
step "Disconnecting AI clients";         remove_client_entries
step "Removing the login agent";         remove_login_agent
step "Images";                           remove_images
step "Data";                             remove_data
step "Removing the install";             remove_install_tree

say ""
say "Datacore is uninstalled."
[ -d "$DATA_HOME" ] && say "Your data is still at $DATA_HOME" || true
say ""
