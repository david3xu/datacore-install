#!/usr/bin/env python3
"""Remove the Claude Desktop MCP entry for one Datacore install.

Exits 0 only if an entry existed AND pointed at the given port, so the caller can tell
"removed" from "left alone because it belongs to another install".
"""
import json
import sys


def main(path: str, port: str) -> int:
    with open(path) as handle:
        config = json.load(handle)
    servers = config.get("mcpServers")
    if not isinstance(servers, dict):
        return 1
    entry = servers.get("datacore")
    if entry is None or port not in json.dumps(entry):
        return 1
    del servers["datacore"]
    with open(path, "w") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: uninstall-desktop-entry.py <config.json> <port>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
