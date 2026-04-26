#!/usr/bin/env bash
# Build claudecounter-bar as a macOS .app bundle from the SPM executable.
#
# Usage: ./scripts/build-app.sh [debug|release]
# Output: dist/ClaudeCounterBar.app

set -euo pipefail

CONFIGURATION="${1:-release}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DIST="$(cd "$ROOT/.." && pwd)/dist"
APP="$DIST/ClaudeCounterBar.app"

echo "▸ Building ClaudeCounterBar (${CONFIGURATION})…"
cd "$ROOT"
swift build --configuration "$CONFIGURATION"

BIN="$ROOT/.build/$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
# `--show-bin-path` echoes the absolute bin dir already; the line above
# concatenates accidentally. Re-fetch cleanly.
BIN="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
EXE="$BIN/ClaudeCounterBar"

if [ ! -x "$EXE" ]; then
    echo "✘ Built executable not found at: $EXE"
    exit 1
fi

echo "▸ Assembling .app bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$EXE" "$APP/Contents/MacOS/ClaudeCounterBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Copy SPM resource bundle if present (Resources processed by Package.swift).
RES_BUNDLE="$BIN/ClaudeCounterBar_ClaudeCounterBar.bundle"
if [ -d "$RES_BUNDLE" ]; then
    cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
fi

# Ad-hoc sign so Gatekeeper at least lets it launch from the user's machine.
codesign --force --sign - --options runtime "$APP" 2>/dev/null || \
    echo "⚠ codesign failed (continuing — app will still launch locally)"

echo "✓ Built: $APP"
echo "  Open with: open '$APP'"
