#!/bin/sh
# Datacore worker management — add, list, remove AI coding tool workers.
# Usage: datacore worker add [name|--all] | list | remove <name>
# DATACORE_HOME   runtime data directory (default: ~/.datacore-local)

set -eu

DATA_HOME="${DATACORE_HOME:-$HOME/.datacore-local}"
WORKERS_DIR="$DATA_HOME/workers"
PROVIDERS_DIR="$DATA_HOME/providers"

# ---------------------------------------------------------------- helpers

die()  { printf '%s\n' "$1" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

ensure_workers_dir() { mkdir -p "$WORKERS_DIR"; chmod 700 "$WORKERS_DIR"; }

read_field() {
  grep "\"$2\"" "$1" | sed 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/' | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------- JSON writers

write_worker_cli() {
  ensure_workers_dir; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > "$WORKERS_DIR/$1.json" <<ENDJSON
{
  "name": "$1",
  "kind": "cli",
  "binary": "$2",
  "version": "$3",
  "model_alias": "",
  "auth": "external",
  "role": "both",
  "registered_at": "$ts"
}
ENDJSON
}

write_worker_api() {
  ensure_workers_dir; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cat > "$WORKERS_DIR/$1.json" <<ENDJSON
{
  "name": "$1",
  "kind": "api",
  "provider": "$2",
  "model": "$3",
  "auth": "datacore",
  "role": "both",
  "registered_at": "$ts"
}
ENDJSON
}

# ---------------------------------------------------------------- detection
# Each detector prints pipe-delimited records: kind|name|detail|extra

detect_cli() {
  for _n in claude codex agy; do
    _b=$(command -v "$_n" 2>/dev/null) || continue
    _abs=$(cd "$(dirname "$_b")" 2>/dev/null && pwd)/"$(basename "$_b")" || _abs="$_b"
    _v=$("$_abs" --version 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//') || _v=""
    printf 'cli|%s|%s|%s\n' "$_n" "$_abs" "${_v:-version unknown}"
  done
}

detect_api() {
  [ -d "$PROVIDERS_DIR" ] || return 0
  for _c in "$PROVIDERS_DIR"/*.json; do
    [ -f "$_c" ] || continue
    _pn=$(read_field "$_c" name); [ -n "$_pn" ] || continue
    printf 'api|%s|API provider|%s\n' "$_pn" "$(read_field "$_c" model)"
  done
}

# ---------------------------------------------------------------- registration

# Register one pipe-delimited record. Returns 1 on unknown kind (safe for --all).
register_one() {
  _k=$(printf '%s' "$1" | cut -d'|' -f1)
  _rn=$(printf '%s' "$1" | cut -d'|' -f2)
  _dt=$(printf '%s' "$1" | cut -d'|' -f3)
  _ex=$(printf '%s' "$1" | cut -d'|' -f4)
  case "$_k" in
    cli) write_worker_cli "$_rn" "$_dt" "$_ex"
         ok "worker '$_rn' registered (cli — no credential stored, uses your own login)" ;;
    api) write_worker_api "$_rn" "$_rn" "$_ex"
         ok "worker '$_rn' registered (api — key held by Datacore)" ;;
    *)   warn "unknown kind '$_k' for '$_rn' — skipped"; return 1 ;;
  esac
}

# Register every line in a file; report failures but do not abort.
register_all_from() {
  _errs=0
  while IFS= read -r _ln; do
    [ -n "$_ln" ] || continue
    register_one "$_ln" || _errs=$((_errs + 1))
  done < "$1"
  [ "$_errs" -eq 0 ] || warn "$_errs registration(s) failed. Others were saved."
  say "  Run: datacore worker list"
}

# Print numbered menu lines to stdout.
print_menu() {
  _i=0
  while IFS= read -r _ln; do
    [ -n "$_ln" ] || continue
    _i=$((_i + 1))
    printf '  %d  %-10s  %-38s  %s\n' "$_i" \
      "$(printf '%s' "$_ln" | cut -d'|' -f2)" \
      "$(printf '%s' "$_ln" | cut -d'|' -f3)" \
      "$(printf '%s' "$_ln" | cut -d'|' -f4)"
  done < "$1"
}

# ---------------------------------------------------------------- subcommand: add

cmd_add() {
  arg="${1:-}"
  _tmp=$(mktemp)
  trap 'rm -f "$_tmp"' EXIT INT TERM

  detect_cli >> "$_tmp"
  detect_api >> "$_tmp"

  _total=$(grep -c '' "$_tmp" 2>/dev/null) || _total=0

  if [ "$_total" -eq 0 ]; then
    say "Nothing found on this machine."
    say "  Install a CLI (claude, codex, agy) or run: datacore provider add meta"
    say "  Then retry: datacore worker add"
    rm -f "$_tmp"; trap - EXIT INT TERM; exit 0
  fi

  # --all
  if [ "$arg" = "--all" ]; then
    register_all_from "$_tmp"
    rm -f "$_tmp"; trap - EXIT INT TERM; return 0
  fi

  # named argument
  if [ -n "$arg" ]; then
    _m=$(grep "^[^|]*|$arg|" "$_tmp") || true
    rm -f "$_tmp"; trap - EXIT INT TERM
    [ -n "$_m" ] || { printf "No detected worker named '%s'. Run: datacore worker add\n" "$arg" >&2; exit 1; }
    register_one "$_m" && say "  Run: datacore worker list"
    return 0
  fi

  # non-interactive stdin: list and advise
  if [ ! -t 0 ]; then
    say "Found on this machine:"; say ""
    print_menu "$_tmp"; say ""
    say "Re-run with a name or '--all':  datacore worker add --all"
    rm -f "$_tmp"; trap - EXIT INT TERM; exit 0
  fi

  # interactive menu
  say ""; say "Found on this machine:"; say ""
  print_menu "$_tmp"
  say ""; printf "Add which? [number, or 'all']: " >&2
  read -r _ch

  if [ "$_ch" = "all" ]; then
    register_all_from "$_tmp"
    rm -f "$_tmp"; trap - EXIT INT TERM; return 0
  fi

  case "$_ch" in
    *[!0-9]*|'') rm -f "$_tmp"; trap - EXIT INT TERM
                 die "Invalid choice '$_ch'. Run: datacore worker add" ;;
  esac
  if [ "$_ch" -lt 1 ] || [ "$_ch" -gt "$_total" ]; then
    rm -f "$_tmp"; trap - EXIT INT TERM
    die "Choice $_ch out of range (1–$_total). Run: datacore worker add"
  fi

  _sel=$(sed -n "${_ch}p" "$_tmp")
  rm -f "$_tmp"; trap - EXIT INT TERM
  register_one "$_sel" && say "  Run: datacore worker list"
}

# ---------------------------------------------------------------- subcommand: list

cmd_list() {
  _found=0
  if [ -d "$WORKERS_DIR" ]; then
    for _c in "$WORKERS_DIR"/*.json; do
      [ -f "$_c" ] || continue; _found=$((_found + 1))
      _name=$(read_field "$_c" name); _kind=$(read_field "$_c" kind)
      if [ "$_kind" = "cli" ]; then
        printf '  %-12s  cli  %s  (%s)\n' "$_name" "$(read_field "$_c" binary)" "$(read_field "$_c" version)"
        say "               auth: no credential stored — uses your own login"
      elif [ "$_kind" = "api" ]; then
        printf '  %-12s  api  provider=%s  model=%s\n' "$_name" "$(read_field "$_c" provider)" "$(read_field "$_c" model)"
        say "               auth: datacore (key held by Datacore)"
      else
        printf '  %-12s  (unknown kind)\n' "$_name"
      fi
      printf '               registered: %s\n' "$(read_field "$_c" registered_at)"
    done
  fi
  if [ "$_found" -eq 0 ]; then
    say "No workers registered.  Run: datacore worker add"; exit 0
  fi
}

# ---------------------------------------------------------------- subcommand: remove

cmd_remove() {
  _name="${1:-}"
  [ -n "$_name" ] || { say "Usage: datacore worker remove <name>" >&2; exit 2; }
  _c="$WORKERS_DIR/$_name.json"
  if [ ! -f "$_c" ]; then
    printf "No worker named '%s'. Run: datacore worker list\n" "$_name" >&2; exit 1
  fi
  rm -f "$_c"
  ok "removed worker '$_name'"; say "  Run: datacore worker list"
}

# ---------------------------------------------------------------- usage

usage() {
  cat <<'EOF'
Usage: datacore worker <subcommand> [args...]

Subcommands:
  add [name|--all]   detect and register AI coding tool workers
  list               list registered workers
  remove <name>      unregister a worker

Workers are optional. A worker is either:
  cli  — a local AI CLI (claude, codex, agy); Datacore never stores its credentials.
  api  — a configured provider (from `datacore provider add`); Datacore holds the key.
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
  *) printf 'Unknown subcommand: %s\nRun: datacore worker --help\n' "$subcmd" >&2; exit 2 ;;
esac
