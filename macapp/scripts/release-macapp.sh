#!/usr/bin/env bash
# Package the menu bar app for distribution as a release artifact.
#
# Outputs in dist/:
#   ClaudeCounterBar-<version>-macos-<arch>.zip
#   ClaudeCounterBar-<version>-macos-<arch>.zip.sha256
#
# Usage:
#   VERSION=v1.0.0 ./scripts/release-macapp.sh
#   (without VERSION, packages as "dev" — useful for local checks)
#
# This is Tier A distribution: ad-hoc signed, no notarization.
# Users will need to strip the quarantine flag on first run; see the
# install section in macapp/README.md. When a paid Apple Developer
# account is available, drop-in additions to this script can sign
# with a Developer ID cert and notarize via xcrun notarytool — no
# other change needed.
set -euo pipefail

VERSION="${VERSION:-dev}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"               # macapp/
REPO="$(cd "$ROOT/.." && pwd)"                # repo root
DIST="$REPO/dist"
APP="$DIST/ClaudeCounterBar.app"

# Apple Silicon by default; macos-14 GitHub runner is arm64.
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64|aarch64) ARCH_LABEL="arm64" ;;
    x86_64)        ARCH_LABEL="x86_64" ;;
    *)             ARCH_LABEL="$ARCH" ;;
esac

ZIP_NAME="ClaudeCounterBar-${VERSION}-macos-${ARCH_LABEL}.zip"
ZIP_PATH="$DIST/$ZIP_NAME"

echo "▸ Building app bundle…"
"$HERE/build-app.sh" release > /dev/null

if [ ! -d "$APP" ]; then
    echo "✘ Built bundle missing at $APP"
    exit 1
fi

echo "▸ Stamping CFBundleShortVersionString = ${VERSION#v}"
# Update the version string inside the bundle so users who right-click
# Get Info on the .app see the release version. We do this in-place on
# the just-built bundle.
PLIST="$APP/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION#v}" "$PLIST"
fi

# Re-sign after the plist edit so the ad-hoc signature stays valid.
codesign --force --sign - --options runtime "$APP" 2>/dev/null \
    || echo "⚠ codesign re-sign failed (continuing — app will still launch locally)"

echo "▸ Packaging $ZIP_NAME"
rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
# `ditto -c -k --keepParent --sequesterRsrc` is the canonical macOS
# packaging command: preserves resource forks, extended attributes, and
# the parent .app directory inside the archive. A plain `zip -r` can
# silently mangle bundles with symlinks, which would brick the install.
( cd "$DIST" && ditto -c -k --keepParent --sequesterRsrc \
    "ClaudeCounterBar.app" "$ZIP_NAME" )

echo "▸ Computing SHA-256"
( cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" )

echo
echo "✓ Release artifacts in $DIST/"
echo "    $(ls -lh "$ZIP_PATH" | awk '{print $5}')   $ZIP_NAME"
echo "    $(cat "$ZIP_PATH.sha256")"
echo
echo "Next:"
echo "  • Test locally:  open $APP"
echo "  • Tag + push:    git tag macapp-${VERSION} && git push origin macapp-${VERSION}"
echo "  • CI will rebuild from the tag and attach these artifacts to a Release."
