#!/bin/bash
# Build Galleria.app
#
# NOTE: this Mac has Command Line Tools only (no Xcode). The macOS 27 SDK makes
# SwiftUI's @State a macro whose plugin ships with Xcode, so we build against the
# macOS 26 SDK, where @State is still a property wrapper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"

APP="dist/Galleria.app"
BIN="$APP/Contents/MacOS/Galleria"

echo "▸ SDK: $SDK"
echo "▸ Compiling…"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -O \
    -o "$BIN" \
    Sources/Galleria/*.swift \
    -framework SwiftUI \
    -framework AppKit \
    -framework CoreImage \
    -framework CoreServices \
    -framework Vision \
    -framework MapKit \
    -lsqlite3

cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "▸ Done: $ROOT/$APP"
du -sh "$APP"
