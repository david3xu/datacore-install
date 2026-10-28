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


def belongs_to_port(entry: object, port: str) -> bool:
    """True when `port` appears in the entry as a port, not as part of a longer number.

    A plain substring test matched too much: uninstalling the install on port 3123 would claim
    the entry of the one on 43123.
    """
    return re.search(rf"(?<!\d){re.escape(port)}(?!\d)", json.dumps(entry)) is not None


def main(path: str, port: str) -> int:
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
    if entry is None or not belongs_to_port(entry, port):
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
    if len(sys.argv) != 3:
        print("usage: uninstall-desktop-entry.py <config.json> <port>", file=sys.stderr)
        raise SystemExit(USAGE)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
