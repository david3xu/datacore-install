#!/bin/sh
# Assemble the release assets for a Datacore version.
#
# Why this script exists: v0.1.79 was assembled by hand and shipped without lib/project.sh or
# lib/install-desktop-entry.py. install.sh refuses any helper the manifest does not list -- it will
# not put an unverified file on PATH -- so `datacore project` simply did not exist on a fresh
# install, and `datacore project link` is the first thing the install summary tells the user to run.
# Nothing failed loudly; dispatch just had nowhere to send work.
#
# So the asset set is never written down twice. It is derived from install.sh's own CLI_FILES, and
# the script refuses to finish if the manifest does not account for every file install.sh installs.
#
# Usage:  sh make-release.sh <version> <dir-with-bundle-tarballs>
#   e.g.  sh make-release.sh v0.1.79 ~/Developer/datacore-platform/dist/release-stage-refix/latest/download
#
# It stages into dist/<version>/ and prints the upload command. It does not upload or publish:
# that is the maintainer's call, and a draft release is invisible to users until they make it live.
set -eu

VERSION="${1:-}"
BUNDLE_DIR="${2:-}"
REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "Usage: sh make-release.sh <version> <dir-with-bundle-tarballs>" >&2
  echo "  e.g. sh make-release.sh v0.1.79 /path/to/latest/download" >&2
  exit 2
}
[ -n "$VERSION" ] || usage
[ -n "$BUNDLE_DIR" ] || usage
[ -d "$BUNDLE_DIR" ] || { echo "No such directory: $BUNDLE_DIR" >&2; exit 1; }

case "$VERSION" in
  v[0-9]*) ;;
  *) echo "Version should look like v0.1.79, got: $VERSION" >&2; exit 1 ;;
esac

# install.sh is the single source of truth for what a release has to carry. Reading it here means a
# new helper is covered by adding it to CLI_FILES, with nothing else to remember.
cli_files=$(sed -n 's/^CLI_FILES="\(.*\)"$/\1/p' "$REPO_DIR/install.sh" | tr ' ' '\n')
[ -n "$cli_files" ] || { echo "Could not read CLI_FILES from install.sh" >&2; exit 1; }

pinned=$(sed -n 's/^PINNED_RELEASE="\(.*\)"$/\1/p' "$REPO_DIR/install.sh")
if [ "$pinned" != "$VERSION" ]; then
  echo "install.sh pins $pinned but you are building $VERSION." >&2
  echo "Update PINNED_RELEASE (and the README) first, or build $pinned." >&2
  exit 1
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

OUT="$REPO_DIR/dist/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Assembling $VERSION"
echo

# --- the bundle archives -------------------------------------------------------------------------
# Both platforms, every time. SHA256SUMS listing an archive that is not attached is the failure that
# made macOS/arm64 -- the only platform marked "tested" -- 404 on the documented one-liner.
for arch in amd64 arm64; do
  name="datacore-local-edition-$arch.tar.gz"
  if [ ! -f "$BUNDLE_DIR/$name" ]; then
    echo "  MISSING  $name" >&2
    echo >&2
    echo "$BUNDLE_DIR does not contain $name. Build it before assembling the release;" >&2
    echo "a release with one architecture 404s for everyone on the other." >&2
    exit 1
  fi
  cp "$BUNDLE_DIR/$name" "$OUT/$name"
  echo "  archive  $name"
done

# --- the CLI files -------------------------------------------------------------------------------
# install.sh fetches these by basename, so they are flattened here (lib/project.sh -> project.sh).
for f in $cli_files; do
  [ -n "$f" ] || continue
  src="$REPO_DIR/$f"
  [ -f "$src" ] || { echo "  MISSING  $f (named in CLI_FILES, not in the repo)" >&2; exit 1; }
  cp "$src" "$OUT/$(basename "$f")"
  echo "  cli      $(basename "$f")"
done

# --- the manifest --------------------------------------------------------------------------------
( cd "$OUT" && for f in *; do
    [ "$f" = SHA256SUMS ] && continue
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"
  done > SHA256SUMS )

# --- self-check ----------------------------------------------------------------------------------
# The point of generating the manifest is undone if it can still miss a file, so verify the output
# rather than trusting the loop that produced it.
fail=0
for f in $cli_files datacore-local-edition-amd64.tar.gz datacore-local-edition-arm64.tar.gz; do
  [ -n "$f" ] || continue
  name=$(basename "$f")
  [ -f "$OUT/$name" ] || { echo "  NOT STAGED  $name" >&2; fail=1; }
  grep -q "  $name\$" "$OUT/SHA256SUMS" || { echo "  NOT IN MANIFEST  $name" >&2; fail=1; }
done
[ "$fail" = 0 ] || { echo "Refusing to finish: the staged release is incomplete." >&2; exit 1; }

count=$(grep -c . "$OUT/SHA256SUMS")
echo
echo "Staged $count asset(s) in dist/$VERSION, manifest covers all of them."
echo
echo "To publish (this script deliberately does not):"
echo
echo "  gh release create $VERSION --repo <owner>/datacore-install \\"
echo "    --title '$VERSION' --notes-file <notes.md> \\"
echo "    dist/$VERSION/*"
echo
echo "For a release that already exists as a draft:"
echo
echo "  gh release upload $VERSION --repo <owner>/datacore-install dist/$VERSION/* --clobber"
echo "  gh release edit   $VERSION --repo <owner>/datacore-install --draft=false"
echo
echo "A draft release keeps its tag unpushed, so"
echo "  curl -fsSL https://raw.githubusercontent.com/<owner>/datacore-install/$VERSION/install.sh"
echo "returns 404 until --draft=false. That URL is the install command in the README."
