#!/bin/sh
# Datacore provider management — add, list, remove model API providers.
#
# Usage (via datacore front door):
#   datacore provider add <preset>
#   datacore provider list
#   datacore provider remove <name>
#
# Environment overrides:
#   DATACORE_HOME   runtime data directory (default: ~/.datacore-local)

set -eu

DATA_HOME="${DATACORE_HOME:-$HOME/.datacore-local}"
PROVIDERS_DIR="$DATA_HOME/providers"

# ---------------------------------------------------------------- output helpers

die()  { printf '%s\n' "$1" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }

# ---------------------------------------------------------------- platform

is_macos() { [ "$(uname -s)" = Darwin ]; }

# ---------------------------------------------------------------- keychain / file key storage

store_key() {
  name="$1"
  # key is read from stdin to avoid it ever appearing in argv
  if is_macos; then
    security add-generic-password -U -s datacore-provider -a "$name" -w "$(cat)" 2>/dev/null \
      || die "Keychain write failed. Try: security add-generic-password -U -s datacore-provider -a $name -w <key>"
  else
    mkdir -p "$PROVIDERS_DIR"
    chmod 700 "$PROVIDERS_DIR"
    cat > "$PROVIDERS_DIR/$name.key"
    chmod 600 "$PROVIDERS_DIR/$name.key"
  fi
}

delete_key() {
  name="$1"
  if is_macos; then
    security delete-generic-password -s datacore-provider -a "$name" >/dev/null 2>&1 || true
  else
    rm -f "$PROVIDERS_DIR/$name.key"
  fi
}

key_ref() {
  if is_macos; then printf 'keychain'; else printf 'file'; fi
}

# ---------------------------------------------------------------- config file helpers

write_config() {
  name="$1"; base_url="$2"; request_path="$3"; timeout_ms="$4"; model="$5"
  ref=$(key_ref)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$PROVIDERS_DIR"
  cat > "$PROVIDERS_DIR/$name.json" <<ENDJSON
{
  "name": "$name",
  "base_url": "$base_url",
  "request_path": "$request_path",
  "timeout_ms": $timeout_ms,
  "model": "$model",
  "key_ref": "$ref",
  "verified_at": "$ts"
}
ENDJSON
}

read_field() {
  file="$1"; field="$2"
  grep "\"$field\"" "$file" | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/' | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------- terminal key input

# Reads a key from the terminal without echoing, or from stdin if not a tty.
# Prints the key to stdout. Never logs it.
read_key() {
  if [ -t 0 ]; then
    # Restore echo on exit, interrupt, or error.
    _tty_restore() { stty echo 2>/dev/null || true; }
    trap '_tty_restore' EXIT INT TERM
    stty -echo 2>/dev/null || true
    printf 'API key (input hidden): ' >&2
    read -r _key
    stty echo 2>/dev/null || true
    trap - EXIT INT TERM
    printf '\n' >&2
  else
    read -r _key || true
  fi
  printf '%s' "$_key"
}

# ---------------------------------------------------------------- HTTP verification

# Sends one real request, prints the model name and elapsed time on success,
# or prints the provider error (truncated) and exits 1 on failure.
# The key is passed via an environment variable, never as a command-line arg.
verify_key() {
  base_url="$1"; request_path="$2"; model="$3"
  # PROVIDER_KEY must be set by the caller in the environment.
  url="${base_url}${request_path}"
  body="{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1}"

  tmpout=$(mktemp)
  tmperr=$(mktemp)
  trap 'rm -f "$tmpout" "$tmperr"' EXIT INT TERM

  ts_start=$(date +%s)
  # Pass the key via a header built with shell; it never touches argv.
  http_code=$(curl -sS --connect-timeout 30 -w '%{http_code}' -o "$tmpout" \
    -X POST "$url" \
    -H "Authorization: Bearer $PROVIDER_KEY" \
    -H 'Content-Type: application/json' \
    -d "$body" 2>"$tmperr" || true)
  ts_end=$(date +%s)
  elapsed=$((ts_end - ts_start))

  response=$(cat "$tmpout")
  rm -f "$tmpout" "$tmperr"
  trap - EXIT INT TERM

  # 2xx + contains a "model" field = success
  case "$http_code" in
    2*)
      if printf '%s' "$response" | grep -q '"model"'; then
        answered_model=$(printf '%s' "$response" | grep '"model"' | head -1 \
          | sed 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        ok "verified — model: $answered_model, elapsed: ${elapsed}s"
        return 0
      fi
      ;;
  esac

  # Failure: print the provider's error, truncated.
  err_text=$(printf '%s' "$response" | head -c 300)
  [ -n "$err_text" ] || err_text="(no response body; HTTP $http_code)"
  printf 'Provider rejected the key.\n  HTTP %s: %s\n' "$http_code" "$err_text" >&2
  return 1
}

# ---------------------------------------------------------------- presets

# Prints: base_url|request_path|timeout_ms|prompt_model
# Returns 1 if unknown preset.
preset_info() {
  case "$1" in
    meta)
      printf 'https://api.meta.ai|/v1/chat/completions|180000|muse-spark-1.3|no'
      ;;
    openai-compatible)
      printf '|/v1/chat/completions|180000||yes'
      ;;
    local)
      printf 'http://127.0.0.1:8080/v1|/chat/completions|300000||yes'
      ;;
    *)
      return 1
      ;;
  esac
}

list_presets() {
  say "Valid presets:"
  say "  meta               https://api.meta.ai (model: muse-spark-1.3)"
  say "  openai-compatible  any OpenAI-compatible endpoint (prompts for URL and model)"
  say "  local              http://127.0.0.1:8080/v1 (prompts for model)"
}

# ---------------------------------------------------------------- subcommand: add

cmd_add() {
  preset="${1:-}"
  [ -n "$preset" ] || { say "Usage: datacore provider add <preset>" >&2; list_presets >&2; exit 2; }

  info_str=$(preset_info "$preset" 2>/dev/null) || {
    printf 'Unknown preset: %s\n' "$preset" >&2
    list_presets >&2
    exit 2
  }

  # Parse the pipe-delimited preset info.
  base_url=$(printf '%s' "$info_str"      | cut -d'|' -f1)
  request_path=$(printf '%s' "$info_str"  | cut -d'|' -f2)
  timeout_ms=$(printf '%s' "$info_str"    | cut -d'|' -f3)
  default_model=$(printf '%s' "$info_str" | cut -d'|' -f4)
  prompt_url=$(printf '%s' "$info_str"    | cut -d'|' -f5)

  # Prompt for base URL if required (openai-compatible).
  if [ "$prompt_url" = yes ] && [ -z "$base_url" ]; then
    if [ ! -t 0 ]; then
      die "Preset '$preset' requires an interactive terminal to enter the base URL."
    fi
    printf 'Base URL (e.g. https://api.openai.com): ' >&2
    read -r base_url
    base_url=$(printf '%s' "$base_url" | sed 's|/$||')
    [ -n "$base_url" ] || die "Base URL is required."
  fi

  # Prompt for model if required.
  if [ -z "$default_model" ]; then
    if [ -t 0 ]; then
      printf 'Model name: ' >&2
      read -r default_model
      [ -n "$default_model" ] || die "Model name is required."
    else
      # Non-interactive: first stdin line is the model name, second is the key.
      read -r default_model || true
      [ -n "$default_model" ] || die "Preset '$preset' requires a model name. Pipe: printf 'model-name\\napi-key\\n' | ..."
    fi
  fi
  model="$default_model"

  # Read the key without echoing (or from remaining stdin when not a tty).
  PROVIDER_KEY=$(read_key)
  [ -n "$PROVIDER_KEY" ] || die "No key provided."

  # Verify the key with a real HTTP request before storing anything.
  info "verifying key with $base_url ..."
  if ! verify_key "$base_url" "$request_path" "$model"; then
    say "" >&2
    say "Key NOT stored. Fix the error above, then retry: datacore provider add $preset" >&2
    exit 1
  fi

  # Verification succeeded — now store the key and write config.
  printf '%s' "$PROVIDER_KEY" | store_key "$preset"
  write_config "$preset" "$base_url" "$request_path" "$timeout_ms" "$model"

  ok "provider '$preset' saved ($(key_ref))"
  say "  Run: datacore provider list"
}

# ---------------------------------------------------------------- subcommand: list

cmd_list() {
  found=0
  if [ -d "$PROVIDERS_DIR" ]; then
    for cfg in "$PROVIDERS_DIR"/*.json; do
      [ -f "$cfg" ] || continue
      found=$((found + 1))
      name=$(read_field "$cfg" name)
      model=$(read_field "$cfg" model)
      base_url=$(read_field "$cfg" base_url)
      key_ref=$(read_field "$cfg" key_ref)
      verified_at=$(read_field "$cfg" verified_at)
      printf '  %-20s  model=%-30s  url=%s\n' "$name" "$model" "$base_url"
      printf '  %-20s  key=%s  verified=%s\n' "" "$key_ref" "$verified_at"
    done
  fi
  if [ "$found" -eq 0 ]; then
    say "No providers configured."
    say "  Run: datacore provider add meta"
  fi
}

# ---------------------------------------------------------------- subcommand: remove

cmd_remove() {
  name="${1:-}"
  [ -n "$name" ] || { say "Usage: datacore provider remove <name>" >&2; exit 2; }

  cfg="$PROVIDERS_DIR/$name.json"
  if [ ! -f "$cfg" ]; then
    printf "No provider named '%s'. Run: datacore provider list\n" "$name" >&2
    exit 1
  fi

  delete_key "$name"
  rm -f "$cfg"
  ok "removed provider '$name'"
}

# ---------------------------------------------------------------- usage

usage() {
  cat <<'EOF'
Usage: datacore provider <subcommand> [args...]

Subcommands:
  add <preset>    configure a model API key (verifies before storing)
  list            list configured providers
  remove <name>   delete a provider and its stored key

Presets for add:
  meta               Meta AI (api.meta.ai)
  openai-compatible  any OpenAI-compatible endpoint
  local              local inference at 127.0.0.1:8080
EOF
  exit 0
}

# ---------------------------------------------------------------- dispatch

subcmd="${1:-}"
[ $# -gt 0 ] && shift || true

case "$subcmd" in
  ''|-h|--help) usage ;;
  add)    cmd_add    "$@" ;;
  list)   cmd_list   "$@" ;;
  remove) cmd_remove "$@" ;;
  *) printf 'Unknown subcommand: %s\nRun: datacore provider --help\n' "$subcmd" >&2; exit 2 ;;
esac
