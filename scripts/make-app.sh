#!/bin/bash
# Builds TerminalNavigator.app.
#
# SwiftPM produces bare executables, not bundles, so the .app is assembled here. It matters
# for more than tidiness: macOS grants Accessibility and Automation permission to a bundle
# identity, and a bare binary run from .build gets a fresh identity every time it is rebuilt —
# so permissions silently lapse and cross-desktop jumps quietly stop working.
#
# The tnav CLI is placed inside the bundle too, so the Claude Code hooks can point at a path
# that does not move when the source tree does.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/TerminalNavigator.app}"
VERSION="1.0.0"

echo "==> Building release binaries"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

echo "==> Assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/TerminalNavigatorApp" "$APP/Contents/MacOS/TerminalNavigator"
cp "$BIN/tnav"                 "$APP/Contents/MacOS/tnav"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>TerminalNavigator</string>
    <key>CFBundleDisplayName</key>       <string>TerminalNavigator</string>
    <key>CFBundleExecutable</key>        <string>TerminalNavigator</string>
    <key>CFBundleIdentifier</key>        <string>com.github.ayekarimba.terminalnavigator</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu bar only: no Dock icon, no window on launch. -->
    <key>LSUIElement</key>               <true/>
    <!-- Shown in the permission prompts, so say why rather than leaving it blank. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>TerminalNavigator asks Terminal which tab each Claude Code session is running in, so it can take you to the right one.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature. Without a Developer ID this is the best available, and it is what gives the
# bundle a consistent identity for the permission prompts.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "    warning: codesign failed; the app still runs but may re-prompt for permissions"

echo "==> Built $APP"
