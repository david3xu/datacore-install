# Datacore — install

Datacore gives your AI coding tools a shared memory: tasks, decisions, evidence and search that
persist across sessions and across tools. It runs entirely on your own machine.

This repository holds the installer and documentation. **It contains no Datacore source code.**

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/david3xu/datacore-install/main/install.sh | sh
```

Prefer to read before you run? That is the better habit:

```bash
curl -fsSLO https://raw.githubusercontent.com/david3xu/datacore-install/main/install.sh
less install.sh
sh install.sh
```

## What you need first

**Docker.** That is the only prerequisite. If you have [colima](https://github.com/abiosoft/colima)
installed but stopped, the installer starts it for you. If you have no container runtime at all,
the installer prints the one command to install one and stops.

You do **not** need Node, Bun, Python, or any AI CLI installed to get started. Datacore's own
scripts run on bun; if your machine has none, the installer puts a private copy in
`~/.datacore/bin` and changes nothing system-wide.

## Platforms

Each release carries one archive per CPU architecture, because the bundle ships container images;
the installer picks by `uname -m`.

| | |
|---|---|
| macOS, Apple silicon | tested |
| Linux, x86_64 | tested on Ubuntu 24.04 |
| Linux, arm64 | same archive as Apple silicon; not yet tested on a Linux arm64 host |
| macOS, Intel | should work, untested |
| Windows | not supported |

On Linux, Docker must be usable by your own user. If `docker info` reports *permission denied*,
run Docker's post-install step — the installer tells you the command.

## What the installer does

1. Detects your platform and refuses clearly if it is unsupported
2. Starts your container runtime, or tells you exactly how to install one
3. Downloads the release archive and **verifies its SHA-256 before extracting**
4. Installs to `~/.datacore/versions/<version>` and points `current` at it
5. Shows the licence terms and records your acceptance
6. Starts Datacore and waits until it reports healthy
7. Registers Datacore with every AI client it finds, and **verifies the connection works**
8. Prints one next step

Nothing is hand-edited. You will not be asked to open a file in an editor.

## After installing

```
✓ Datacore 0.1.77 is running

  Runtime    http://127.0.0.1:43123
  MCP        Claude Code
  Profile    minimal — workers off, gateway off

  Next: restart Claude Code, then ask it "what tasks do I have?"
  Later: datacore worker add codex    (let Datacore drive coding agents)
```

A minimal install is a complete product: memory, tasks and search inside your AI client. Model
execution is opt-in and configured later, only if you want it.

## Commands

| | |
|---|---|
| `datacore status` | is it running, and what is enabled |
| `datacore doctor` | diagnose problems, with remediation |
| `datacore logs` | tail component logs |
| `datacore stop` / `start` | stop and start the stack |
| `datacore provider add <name>` | configure a model API key |
| `datacore worker add <cli>` | register a local AI CLI as a worker |
| `datacore update` | fetch the latest release and upgrade in place, rolling back on failure |
| `datacore uninstall` | remove the containers, client entries, login agent and install |

## Giving Datacore model access

Two routes, and you can use either or both.

**An API key** — Datacore stores it in your system keychain and calls the provider itself:

```bash
datacore provider add meta
```

**An AI CLI you already pay for** — Datacore runs it as a worker. It stores only the path and the
model name:

```bash
datacore worker add codex
```

> **Datacore never stores your CLI credentials.** Your Claude or Codex login stays inside that
> tool, under your own account. Installing Datacore does not give it access to those accounts.

Either way, nothing is accepted until a real round trip succeeds. A key or CLI that cannot
actually answer is reported as a failure, not saved as configuration.

## Uninstalling

```bash
datacore uninstall
```

Removes the containers, the MCP entry this install added to your AI clients, the macOS login
agent, and the install itself. **Your data is kept** — the path is printed so you can keep or
remove it yourself.

```bash
datacore uninstall --purge-data     # also delete the data directory, after a y/N confirmation
datacore uninstall --purge-images   # also delete the three Datacore images (~1.5GB)
```

Add `--yes` to skip the confirmation in a script. Only a client entry pointing at *this* install is
removed, so a second install on another port keeps working.

## Support

Open an issue in this repository, and paste the output of `datacore doctor`. It prints one line
per check with the reason and the remediation, and never prints a key or a token — but it does
name local paths and ports, so read it before you post it.

## Licence

See [EULA.md](./EULA.md). Datacore is distributed as a binary bundle. The source is not public.
