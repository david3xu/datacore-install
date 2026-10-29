# Releasing

For maintainers. Users need nothing in this file.

Changing a helper in this checkout does not update an existing release asset. Stage and publish a
new release for the worker-choice and preflight fixes; do not claim the pinned release includes
them until its published assets actually carry them. The runtime bundle may retain its own
version when only installer helpers change.

## Why it is a script

`v0.1.79` was assembled by hand and shipped 7 of the 9 files it needed. `lib/project.sh` and
`lib/install-desktop-entry.py` were named in `install.sh`'s `CLI_FILES` and present in neither the
release assets nor `SHA256SUMS`.

Nothing failed loudly. `install.sh` correctly refuses to put an unverified file on PATH, so it
deleted both and printed one `not installed:` warning. The visible consequence was that
`datacore project` did not exist — the command the install summary names as the **first** next
step, and the one thing that has to be done before any work can be dispatched.

The same release listed `datacore-local-edition-arm64.tar.gz` in `SHA256SUMS` without attaching it,
so macOS on Apple Silicon — the only platform marked *tested* — could not install at all. And it was
left as a **draft**, which leaves its tag unpushed, so the `curl` command in the README returned
`404` for every user.

So the asset set is not written down twice. `make-release.sh` derives it from `install.sh`'s own
`CLI_FILES` and refuses to finish if the manifest does not cover every file.

## Steps

Build both architectures first. A release with one architecture 404s for everyone on the other.

```bash
sh make-release.sh v0.1.82 /path/to/bundle/latest/download
```

It stages into `dist/<version>/`, writes `SHA256SUMS`, verifies its own output, and prints the
upload commands. It refuses to:

- stage a version `install.sh` does not pin — users would fetch a different `install.sh` than the
  assets they get
- stage without both `amd64` and `arm64`
- stage when `CLI_FILES` names a file the repo does not have

It does not upload and does not publish. Both are deliberate.

```bash
gh release upload v0.1.82 --repo <owner>/datacore-install dist/v0.1.82/* --clobber
gh api repos/<owner>/datacore-install/releases/tags/v0.1.82 --jq '.assets[] | [.name, .state] | @tsv'
gh release edit   v0.1.82 --repo <owner>/datacore-install --draft=false --latest
```

Before publishing, every staged asset must be present and have state `uploaded`. A failed upload
entry is not an attached file; retry it before making the release public.

## The last step is the one that is easy to forget

`--draft=false` publishes the release; `--latest` also makes the update command find it. Until
publication the tagged installer —

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/datacore-install/v0.1.82/install.sh
```

— returns `404`. A draft release is fully visible to you and invisible to everyone else, which is
why this is worth checking from a logged-out client rather than from your own `gh`.

Verify after publishing:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/<owner>/datacore-install/v0.1.82/install.sh      # expect 200
gh api repos/<owner>/datacore-install/releases/latest --jq .tag_name               # expect v0.1.82
```

CI covers all of this in two jobs: *the pinned release is stated the same way everywhere* checks the
published release is reachable, not a draft, complete against `CLI_FILES`, and internally
consistent; *a release cannot ship without the files install.sh needs* checks `make-release.sh`
itself.
