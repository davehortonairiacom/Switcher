#!/usr/bin/env bash
# Cuts a release: tags, builds the source tarball, and prints a ready-to-paste
# Homebrew formula with the url and sha256 filled in.
#
#   Tools/release.sh 0.1.0
set -euo pipefail

VERSION="${1:?usage: Tools/release.sh <version>   e.g. 0.1.0}"
REPO="${REPO:-davehortonairiacom/Switcher}"
TAG="v$VERSION"

cd "$(dirname "$0")/.."

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty — commit before releasing." >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
if ! git diff --quiet Resources/Info.plist; then
  git commit -q -m "Version $VERSION" Resources/Info.plist
fi

git tag -a "$TAG" -m "Switcher $VERSION"
echo "Tagged $TAG. Push it:  git push origin main --tags"
echo

TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
echo "Fetching $TARBALL_URL to compute its checksum…"
SHA=$(curl -fsSL "$TARBALL_URL" | shasum -a 256 | cut -d' ' -f1) || {
  echo "Couldn't fetch the tarball — push the tag first, then re-run." >&2
  exit 1
}

echo
echo "Update Formula/switcher.rb in the tap with:"
echo "  url    \"$TARBALL_URL\""
echo "  sha256 \"$SHA\""
