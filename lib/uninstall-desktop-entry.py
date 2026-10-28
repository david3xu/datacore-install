#!/usr/bin/env python3
"""Remove the Claude Desktop MCP entry for one Datacore install.

The file belongs to the user, not to us: it holds every other MCP server they have configured.
So the entry is only touched when it demonstrably points at *this* install, and the rewrite is
atomic -- an earlier version truncated the file before writing, which turned any failure
mid-write into the loss of the user's whole MCP configuration.

Exit codes form a contract with the caller (lib/uninstall.sh), which keeps or discards its
backup based on them:
  0  the entry was ours and has been removed
  1  nothing to do: no entry, or it points at another install (file untouched)
  2  wrong usage
  3  the file could not be read or rewritten (caller must keep its backup)
"""
import json
import os
import re
import sys
import tempfile

REMOVED, NOT_OURS, USAGE, ERROR = 0, 1, 2, 3


def belongs_to_install(entry: object, port: str, root: str = "") -> bool:
    """True when the entry demonstrably belongs to the install identified by `port`/`root`.

    Port first, matched as a number: a plain substring test claimed too much, so uninstalling
    the install on port 3123 would take the entry of the one on 43123.

    But the entry this project's installer writes is `{"command": ".../support/..."}` with no
    port in it at all, so a port-only test could never recognise our own entry -- the installer
    would add something the uninstaller then refused to remove. When the caller knows the
    install root, an entry pointing inside it is ours.
    """
    serialized = json.dumps(entry)
    if port and re.search(rf"(?<!\d){re.escape(port)}(?!\d)", serialized):
        return True
    if root:
        normalized = os.path.normpath(root)
        if normalized not in ("", "/") and f'"{normalized}' in serialized.replace("\\/", "/"):
            return True
        if normalized not in ("", "/") and normalized in json.loads(serialized).get("command", ""):
            return True
    return False


def main(path: str, port: str, root: str = "") -> int:
    try:
        with open(path) as handle:
            config = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"could not read {path}: {exc}", file=sys.stderr)
        return ERROR

    servers = config.get("mcpServers") if isinstance(config, dict) else None
    if not isinstance(servers, dict):
        return NOT_OURS
    entry = servers.get("datacore")
    if entry is None or not belongs_to_install(entry, port, root):
        return NOT_OURS

    del servers["datacore"]
    # Write a sibling temp file and rename over the original, so the config is either the old
    # one or the new one and never a half-written file.
    directory = os.path.dirname(os.path.abspath(path)) or "."
    tmp_path = None
    try:
        mode = os.stat(path).st_mode & 0o777
        fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".datacore-mcp-")
        with os.fdopen(fd, "w") as handle:
            json.dump(config, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
    except OSError as exc:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)
        print(f"could not rewrite {path}: {exc}", file=sys.stderr)
        return ERROR
    return REMOVED


if __name__ == "__main__":
    # The third argument is optional so an older caller keeps working.
    if len(sys.argv) not in (3, 4):
        print("usage: uninstall-desktop-entry.py <claude_desktop_config.json> <port> [install-root]",
              file=sys.stderr)
        raise SystemExit(USAGE)
    raise SystemExit(main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else ""))
