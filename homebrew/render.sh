#!/usr/bin/env bash
# Renders the formula + cask for VERSION (vX.Y.Z) from release assets in
# DIST into OUT (a homebrew-tap checkout). Used by release.yml; runnable
# by hand to publish a release to the tap.
set -euo pipefail
VERSION="${1:?usage: render.sh vX.Y.Z DIST OUT}"; DIST="${2:?}"; OUT="${3:?}"
V="${VERSION#v}"
sha() { shasum -a 256 "$DIST/$1" | cut -d' ' -f1; }
mkdir -p "$OUT/Formula" "$OUT/Casks"
HERE="$(cd "$(dirname "$0")" && pwd)"
sed -e "s|__VERSION__|$V|" \
    -e "s|__SHA_DARWIN_ARM64__|$(sha claudecounter-darwin-arm64)|" \
    -e "s|__SHA_DARWIN_AMD64__|$(sha claudecounter-darwin-amd64)|" \
    -e "s|__SHA_LINUX_ARM64__|$(sha claudecounter-linux-arm64)|" \
    -e "s|__SHA_LINUX_AMD64__|$(sha claudecounter-linux-amd64)|" \
    "$HERE/claudecounter.rb" > "$OUT/Formula/claudecounter.rb"
sed -e "s|__VERSION__|$V|" \
    -e "s|__SHA_MACAPP__|$(sha "ClaudeCounterBar-$VERSION-macos-arm64.zip")|" \
    "$HERE/claudecounter-bar.rb" > "$OUT/Casks/claudecounter-bar.rb"
if grep -qE "\"__[A-Z0-9_]+__\"" "$OUT/Formula/claudecounter.rb" "$OUT/Casks/claudecounter-bar.rb"; then
  echo "unfilled placeholder" >&2; exit 1
fi
