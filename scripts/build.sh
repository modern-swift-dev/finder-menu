#!/bin/bash
# Builds "Finder Menu.app" into the given directory.
# Usage: scripts/build.sh <output-dir>
set -euo pipefail
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
cd "$(dirname "$0")/.."

APP="$OUT/Finder Menu.app"
EXT="$APP/Contents/PlugIns/FinderMenuExtension.appex"
TARGET="$(uname -m)-apple-macos13.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/Extension-Info.plist "$EXT/Contents/Info.plist"

xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  -module-name FinderMenuExtension -parse-as-library -application-extension \
  -framework Cocoa -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
  Sources/FinderMenuExtension/*.swift Sources/Shared/*.swift -o "$EXT/Contents/MacOS/FinderMenuExtension"
xcrun swiftc -swift-version 5 -O -sdk "$SDK" -target "$TARGET" \
  -module-name FinderMenu -framework Cocoa \
  Sources/FinderMenu/*.swift Sources/Shared/*.swift -o "$APP/Contents/MacOS/FinderMenu"

# Ad-hoc signature ("Sign to Run Locally"). Finder extensions must be sandboxed.
# The hardened runtime (-o runtime) stops other code from being injected with DYLD_INSERT_LIBRARIES,
# which could otherwise borrow the helper's permission to control Finder or pose as the extension.
# The linker already ad-hoc signs the binaries, so hide codesign's "replacing existing signature".
codesign --force -s - -o runtime --entitlements Resources/Extension.entitlements "$EXT" 2> >(grep -v "replacing existing signature" >&2)
codesign --force -s - -o runtime --entitlements Resources/App.entitlements "$APP" 2> >(grep -v "replacing existing signature" >&2)
