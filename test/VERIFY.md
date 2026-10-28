# Verifying a fresh install, step by step

What a new user actually does, in order, with what each step should print. Run it on a machine
that has never had Datacore on it — a VM, a spare box, or a cloud runner. An upgrade proves the
upgrade path, not this one.

`test/fresh-install.sh` does all of this unattended. This page is for watching it happen.

---

## 0. Confirm the machine is clean

```bash
ls -d ~/.datacore* 2>/dev/null        # expect: nothing
docker ps -q | wc -l                  # expect: 0
for c in claude codex agy; do command -v $c; done   # expect: nothing
```

That last line matters more than it looks. The installer enables worker families whose CLI it
finds on `PATH`, so a leftover binary from an earlier attempt changes the result and the machine
is no longer fresh.

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/david3xu/datacore-install/v0.1.79/install.sh | sh
```

The URL names a release. Fetching from `main` would let the script and the bundle both move, so
the same command would install different software on different days.

Expect, in order: the platform check, a private `bun` if the machine has none, the archive
download **with its sha256 verified**, configuration, `runtime healthy at http://127.0.0.1:43123`,
and a worker summary.

## 2. Check it is where it says it is

```bash
test -L ~/.datacore/current && echo "current -> $(readlink ~/.datacore/current)"
grep '^DATACORE_HOME=' ~/.datacore/current/.env
ls -d ~/.datacore-local 2>/dev/null && echo "WRONG: shared path created" || echo "data is under the install root"
```

A second install must never adopt the first one's database, which is what the fixed shared path
used to cause.

## 3. Doctor

```bash
~/.datacore/bin/datacore doctor | tail -1
```

Expect `0 fail`. A launcher check for a CLI you have not installed is reported as **skip**, not
fail — nothing is waiting on it. It fails only when a worker that *is* enabled cannot be launched.

## 4. Workers

```bash
~/.datacore/bin/datacore worker list
```

On a machine with no AI CLI this correctly says none are enabled. Install one, log in to it, then:

```bash
~/.datacore/bin/datacore worker add codex-worker
```

Being present is not the same as being logged in. Datacore only checks that the command exists;
run the CLI once yourself first, or dispatch fails quietly later.

## 5. The step that used to lie

```bash
cat ~/.datacore/data/coordinator/executors.json | head -20
~/.datacore/bin/datacore doctor | grep executor_config
```

The Coordinator refuses to dispatch to an agent no executor profile names. These profiles are
generated from your registry on every install. If they are ever missing, doctor reports
`executor_config:file_present` and `datacore worker sync` rebuilds them.

Until this was fixed the installer printed a tick here while writing nothing, and the Coordinator
fell back to an example list baked into the image — which happened to work for the agent ids that
list named, and silently failed for every other one.

## 6. Uninstall

```bash
~/.datacore/bin/datacore uninstall
test -d ~/.datacore/current && echo "WRONG: tree survived" || echo "removed"
docker ps -q | wc -l                  # expect: 0
```

Your data is kept deliberately. `--purge-data` removes it.
