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

ROOT="${DATACORE_INSTALL_ROOT:-$HOME/.datacore}"
C="$ROOT/current"
LOGIN_AGENT_LABEL=com.datacore.local-edition

PURGE_DATA=0
PURGE_IMAGES=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --purge-data)   PURGE_DATA=1 ;;
    --purge-images) PURGE_IMAGES=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    *) printf 'datacore uninstall: unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- output helpers

die()  { printf '%s\n' "$1" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
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
[ -n "$DATA_HOME" ] || DATA_HOME="$HOME/.datacore-local"

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

remove_client_entries() {
  removed=''
  if command -v claude >/dev/null 2>&1; then
    if claude mcp remove datacore -s user >/dev/null 2>&1; then removed='Claude Code'; fi
  fi

  cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  if [ -f "$cfg" ] && grep -q '"datacore"' "$cfg" 2>/dev/null; then
    if command -v python3 >/dev/null 2>&1; then
      cp "$cfg" "$cfg.datacore-uninstall-backup"
      python3 - "$cfg" <<'PY' && removed="${removed:+$removed, }Claude Desktop"
import json, sys
path = sys.argv[1]
with open(path) as fh:
    config = json.load(fh)
servers = config.get("mcpServers")
if isinstance(servers, dict) and servers.pop("datacore", None) is not None:
    with open(path, "w") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")
PY
    else
      info "python3 not available; remove the \"datacore\" entry from $cfg yourself"
    fi
  fi

  [ -n "$removed" ] && ok "removed the Datacore entry from $removed" \
                    || info "no AI client entries to remove"
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

remove_data() {
  [ -d "$DATA_HOME" ] || { info "no data directory at $DATA_HOME"; return 0; }
  size=$(du -sh "$DATA_HOME" 2>/dev/null | cut -f1)
  if [ "$PURGE_DATA" != 1 ]; then
    info "data kept at $DATA_HOME ($size)"
    info "remove it with: datacore uninstall --purge-data"
    return 0
  fi
  confirm "Permanently delete your Datacore data at $DATA_HOME ($size)? This cannot be undone." \
    || { info "data kept at $DATA_HOME"; return 0; }
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
