# Datacore — install

Datacore gives your AI coding tools a shared memory: tasks, decisions, evidence and search that
persist across sessions and across tools. It runs entirely on your own machine.

This repository holds the installer and documentation. **It contains no Datacore source code.**

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/david3xu/datacore-install/v0.1.79/install.sh | sh
```

The URL names a release on purpose. Fetching the installer from `main` would mean the script and
the bundle it downloads could both change under you, so the same command would install different
software on different days. Installing from a tag is reproducible: that command does the same thing
next month as it does today. To track the newest release instead, set `DATACORE_VERSION=latest`.

Prefer to read before you run? That is the better habit:

```bash
curl -fsSLO https://raw.githubusercontent.com/david3xu/datacore-install/v0.1.79/install.sh
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
4. Installs to `~/.datacore/versions/<version>` and points `current` at it, with your data in
   `~/.datacore/data` — set `DATACORE_HOME` to put it elsewhere, or to point a new install at data
   that already exists
5. Shows the licence terms and records your acceptance
6. Has Datacore generate its own configuration and service identities
7. Writes a stand-in worker project map, so nothing is dispatched into a directory you did not
   choose — you name the real repository yourself with `datacore project link`
8. Starts Datacore and waits until it reports healthy
9. Trims the worker registry to the CLIs you actually have, keeping the rest in a catalogue
10. Registers Datacore with every AI client it finds, and **verifies the connection works**
11. On macOS, sets Datacore to **start automatically at login**
12. Prints the next steps in the order they matter, starting with whatever still blocks dispatch

Nothing is hand-edited. You will not be asked to open a file in an editor.

## After installing

```
✓ Datacore 0.1.79 is running

  Runtime    http://127.0.0.1:43123
  MCP        Claude Code
  Workers    2 enabled
  Projects   none mapped — nothing can be dispatched yet
  Gateway    off

  Next:  datacore project link <project> <path-to-repo>    (until then, nothing is dispatched)
  Then:  restart Claude Code, then ask it "what tasks do I have?"
  Later: datacore worker list    (see them), datacore worker add <name>    (enable more)
```

A minimal install is a complete product: memory, tasks and search inside your AI client. Model
execution is opt-in and configured later, only if you want it.

### Your first worker, start to finish

This is the whole path on a machine with no AI CLI yet, which is the usual starting point. Every
line of output below is what the install actually prints, not a sketch.

**1. Install.** On a clean machine the summary ends like this:

```
  Runtime    http://127.0.0.1:43123
  MCP        not registered
  Workers    none — no worker CLI installed (claude, codex, agy)
  Projects   none mapped — nothing can be dispatched yet
```

That is a working install. Memory, tasks and search are already usable from an AI client; workers
are the opt-in part.

**2. Expect `datacore doctor` to report failures at this point, and do not be alarmed by them.**
The installer says `✓ doctor: no blocking failures (2 optional worker CLI not installed)` while
`datacore doctor` run by hand says `16 ok, 3 fail, 3 skip`. Both are right and they are describing
the same machine. The three are:

| Failure | Why, on a clean machine |
|---|---|
| `bridge_dispatch:launcher:claude` | `claude` is not on `PATH`, so no claude worker can be launched |
| `bridge_dispatch:launcher:codex` | same, for `codex` |
| `executor_config:has_entries` | no workers are enabled yet, so there are no executor profiles to project |

All three clear in step 4. Until then they are the honest description of a machine that cannot
dispatch yet, not damage. `datacore doctor`'s remediation line for the launchers suggests setting
`DATACORE_CLAUDE_CODE_BIN` in the bundle `.env`; you do not need to. Putting the CLI on `PATH` is
enough, and is the supported way.

**3. Install and log into an AI CLI.** Datacore dispatches to the CLI you already use — it does not
ship one. Install `claude` or `codex`, then **run it once yourself** and confirm it answers.
Datacore can only check that the command exists; it cannot tell an authenticated CLI from one that
will refuse on first use.

**4. Enable it.**

```bash
datacore worker add claude     # or: codex
datacore worker list           # confirm
datacore doctor                # the three failures above are now gone
```

Nothing needs reinstalling. `worker add` regenerates the Coordinator's executor profiles and
restarts the worker bridge for you.

**5. Map a project.** Nothing is dispatched until the task's project points at a repository:

```bash
datacore project link my-project ~/Developer/my-repo
datacore project list
```

**6. Restart your AI client** and ask it *"what tasks do I have?"*. If it answers, the MCP
connection is live and the loop is closed.

If something still does not dispatch, the three gates in [Workers](#workers) are the things to
check, in that order — and all three fail quietly, which is why they are listed there explicitly.

### Projects

A worker is dispatched **into a git repository**, and which one is decided by the task's project
name. Nothing is dispatched until that project is mapped:

```bash
datacore project list                                  # what is mapped, and whether it is usable
datacore project link my-project ~/Developer/my-repo   # map a project to its repository
datacore project unlink my-project                     # remove a mapping
```

The name is **yours to choose** — it is whatever you call the project when you create tasks, so you
can map it before a single task exists, and that is the right time to do it. What matters is that
the two agree afterwards: matching is **exact**, with no `default` entry and no wildcard, so a task
whose project is `my-project` needs a mapping spelled `my-project`. A mismatch fails with
`No worker workspace configured for project: <name>`, and `datacore project list` shows you the
spelling you actually have.

A fresh install has nothing to map yet, so it reports `none mapped` and says so in its summary
rather than looking ready. Earlier installs left `{"default":"<your home directory>"}` in the
bundle `.env` to satisfy a pre-flight check that rejects an empty map. That entry matched no real
project, so every dispatch failed — and had it matched, it would have handed a worker your whole
home directory. `datacore project link` clears it, and `datacore project list` calls it out if it
is still there.

### Workers

A worker is an AI coding CLI that Datacore dispatches work to. Datacore knows 29 combinations of
CLI × model × role, which is far more than anyone wants enabled — and far more credentials than
anyone wants minted. So the installer mints a token only for the lean set it enables: **one
implementation worker and one reviewer per CLI you actually have installed**, and only for the
families in Datacore's default profile. A stock install ends up with about five.

The other combinations are listed but have no credential yet. `datacore worker add` mints the one
it needs, on the spot, by asking the Runtime — so **the Runtime has to be running** to enable a
worker that was never provisioned. `datacore worker list` marks which families are in that state.

```bash
datacore worker list                       # what will be dispatched to
datacore worker add codex                  # enable a CLI (one worker, one reviewer)
datacore worker add codex-review@gpt-6-sol # or one exact model
datacore worker remove agy                 # disable
datacore worker prune                      # back to the lean default
```

```bash
datacore worker sync                       # regenerate executor profiles from the registry
```

**Installed an AI CLI after Datacore?** That is the common order — Datacore has no workers to
enable until a CLI exists on `PATH`, so a first install on a clean machine reports
`Workers  none — no worker CLI installed`. Install the CLI, log into it, then:

```bash
datacore worker add claude                 # or: codex
datacore worker list                       # confirm it is there
```

There is nothing else to do and no need to reinstall. `worker add` regenerates the Coordinator's
executor profiles and restarts the worker bridge itself, which are the two steps that would
otherwise leave a worker enabled but never dispatched to.

Three things gate dispatch besides the registry, and all three fail quietly:

1. **The worker's CLI has to resolve on `PATH`.** `datacore doctor` checks this.
2. **That CLI has to be logged in.** Datacore only checks that the command exists — it cannot tell
   an authenticated CLI from one that will refuse on first use. Run the CLI once yourself and
   confirm it answers before expecting Datacore to dispatch to it.
3. **The task's project has to be mapped to a repository.** `datacore project list` shows the
   mapping and `datacore project link` sets it — see [Projects](#projects) below.

A fourth used to fail quietly and no longer does: the Coordinator dispatches from executor
profiles, which the installer now generates from your registry on every install. If they are ever
missing, `datacore doctor` reports `executor_config:file_present` and `datacore worker sync`
rebuilds them.

### Starting at login

On macOS the installer registers a login agent, so Datacore is already running the next time you
open your AI client. This matters more than it sounds: an AI client started while Datacore is down
cannot reach it for that whole session, and the only cure is restarting the client.

```bash
DATACORE_SKIP_LOGIN_AGENT=1 ...   # install without it
datacore stop / datacore start    # control it by hand at any time
```

`datacore uninstall` removes the agent. On Linux no agent is installed; run `datacore start`
yourself, or add it to your own session startup.

### A second install on the same machine

Two installs must not share a Compose project, or the second one reconciles the first one's running
containers to its own configuration. Give each its own install root, data directory, project name
and port:

```bash
DATACORE_INSTALL_ROOT="$HOME/.datacore-staging" \
DATACORE_HOME="$HOME/.datacore-staging/data" \
DATACORE_COMPOSE_PROJECT=datacore-staging \
  sh install.sh
```

Each install's generated secrets live under its own data directory, and `datacore` reads the
project name back from the install it was run from, so `stop`, `start`, `doctor` and `update` all
act on the right stack.

## Commands

| | |
|---|---|
| `datacore status` | is it running, and what is enabled |
| `datacore doctor` | diagnose problems, with remediation |
| `datacore logs` | tail component logs |
| `datacore stop` / `start` | stop and start the stack |
| `datacore provider add <name>` | configure a model API key |
| `datacore project list` | the repository each project's workers are dispatched into |
| `datacore project link <project> <path>` | map a project to its repository |
| `datacore worker list` | the workers the runtime will dispatch to |
| `datacore worker add <name>` | enable a worker CLI, family, or one exact model |
| `datacore update` | fetch the latest release and upgrade in place, rolling back on failure |
| `datacore uninstall` | remove the containers, client entries, login agent and install |

## Giving Datacore model access

Two routes, and you can use either or both.

**An API key** — Datacore stores it in your system keychain and calls the provider itself:

```bash
datacore provider add meta
```

**An AI CLI you already pay for** — Datacore runs it as a worker, using your own login for that
tool:

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

Two deliberate refusals, because both directions of a wrong guess here are destructive:

- If this install's `.env` is gone, the uninstaller does not know which data directory is its own
  and will not guess at a shared default. It reports the data as unknown, and `--purge-data`
  stops rather than deleting someone else's. Name it explicitly to proceed:
  `DATACORE_HOME=/path datacore uninstall --purge-data`.
- `--purge-data` refuses any path that does not look like a Datacore data directory, so a
  mistyped `DATACORE_HOME` is rejected instead of erased.

Your previous Claude Desktop configuration is copied to
`claude_desktop_config.json.datacore-uninstall-backup` before the entry is removed, and kept. It
holds your other MCP servers, so it is yours to delete once you have checked the result.

## Support

Open an issue in this repository, and paste the output of `datacore doctor`. It prints one line
per check with the reason and the remediation, and never prints a key or a token — but it does
name local paths and ports, so read it before you post it.

## Releasing

For maintainers: [RELEASING.md](./RELEASING.md).

## Licence

See [EULA.md](./EULA.md). Datacore is distributed as a binary bundle. The source is not public.
