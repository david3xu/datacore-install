#!/usr/bin/env python3
"""Merge this install's Claude Desktop MCP entry into the user's config.

The bundle's write-claude-desktop-config.sh exits 0 having written only a snippet inside the
bundle; nothing ever merged it, so a Mac user who ran the installer never got Claude Desktop
connected and the installer could only report that it had failed. This does the merge.

The file belongs to the user: it holds every other MCP server they have. So the only key touched
is the one the snippet names, the rewrite is atomic -- a sibling temp file renamed over the
original, never a truncate-then-write -- and an existing entry is replaced rather than merged
field-by-field, because a stale entry from an older install must not keep half its old wiring.

Exit codes form a contract with the caller (install.sh):
  0  the entry is now present and matches the snippet
  1  nothing to do: the snippet names no server (file untouched)
  2  wrong usage
  3  the config or the snippet could not be read, or the config could not be rewritten
"""
import json
import os
import sys
import tempfile

MERGED, NOTHING, USAGE, ERROR = 0, 1, 2, 3


def main(config_path: str, snippet_path: str) -> int:
    try:
        with open(snippet_path) as handle:
            snippet = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"could not read {snippet_path}: {exc}", file=sys.stderr)
        return ERROR

    incoming = snippet.get("mcpServers") if isinstance(snippet, dict) else None
    if not isinstance(incoming, dict) or not incoming:
        return NOTHING

    # A config that does not exist yet is not an error: a fresh Claude Desktop install has the
    # directory and no file. Start from an empty object rather than refusing.
    config: dict = {}
    if os.path.exists(config_path):
        try:
            with open(config_path) as handle:
                config = json.load(handle)
        except (OSError, ValueError) as exc:
            print(f"could not read {config_path}: {exc}", file=sys.stderr)
            return ERROR
        if not isinstance(config, dict):
            print(f"{config_path} is not a JSON object", file=sys.stderr)
            return ERROR

    servers = config.setdefault("mcpServers", {})
    if not isinstance(servers, dict):
        print(f'{config_path} has a non-object "mcpServers"', file=sys.stderr)
        return ERROR

    before = set(servers)
    for name, entry in incoming.items():
        servers[name] = entry

    directory = os.path.dirname(os.path.abspath(config_path)) or "."
    tmp_path = None
    try:
        mode = os.stat(config_path).st_mode & 0o777 if os.path.exists(config_path) else 0o600
        fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".datacore-mcp-")
        with os.fdopen(fd, "w") as handle:
            json.dump(config, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, config_path)
    except OSError as exc:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)
        print(f"could not rewrite {config_path}: {exc}", file=sys.stderr)
        return ERROR

    # Read it back. Reporting a merge that is not in the file is the failure this whole change
    # exists to stop.
    try:
        with open(config_path) as handle:
            written = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"wrote {config_path} but could not read it back: {exc}", file=sys.stderr)
        return ERROR
    final = written.get("mcpServers", {})
    for name, entry in incoming.items():
        if final.get(name) != entry:
            print(f'"{name}" is not present as written in {config_path}', file=sys.stderr)
            return ERROR
    lost = before - set(final)
    if lost:
        print(f"these MCP servers were lost: {', '.join(sorted(lost))}", file=sys.stderr)
        return ERROR
    return MERGED


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: install-desktop-entry.py <claude_desktop_config.json> <snippet.json>",
              file=sys.stderr)
        raise SystemExit(USAGE)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
