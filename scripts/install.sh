#!/bin/bash
# Build, install and start ClaudeBar.
#
#   ./scripts/install.sh                 install to /Applications and start at login
#   ./scripts/install.sh --no-login      do not start it at login
#   ./scripts/install.sh --prefix ~/Applications
#   ./scripts/install.sh --agents claude,codex   register hooks for these agents only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="/Applications"
LOGIN_ITEM=1
AGENTS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-login) LOGIN_ITEM=0; shift ;;
        --prefix)   PREFIX="${2%/}"; shift 2 ;;
        --agents)   AGENTS="$2"; shift 2 ;;
        -h|--help)  sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

APP="$PREFIX/ClaudeBar.app"
TNAV="$APP/Contents/MacOS/tnav"
AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.claudebar.plist"

# /Applications needs admin rights on some machines; fall back rather than failing late.
if [ ! -w "$PREFIX" ]; then
    echo "==> $PREFIX is not writable, using ~/Applications instead"
    PREFIX="$HOME/Applications"
    mkdir -p "$PREFIX"
    APP="$PREFIX/ClaudeBar.app"
    TNAV="$APP/Contents/MacOS/tnav"
fi

echo "==> Stopping any running copy"
pkill -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" 2>/dev/null || true
pkill -f "\.build/.*/ClaudeBarApp" 2>/dev/null || true
[ -f "$AGENT" ] && launchctl unload "$AGENT" 2>/dev/null || true

# One-time migration from the app's old name, TerminalNavigator. The real app and login item
# go; a symlink stays behind because Claude Code snapshots hook paths per session, so sessions
# started before the rename keep calling the old path until they are restarted.
OLD_AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.terminalnavigator.plist"
pkill -f "TerminalNavigator.app/Contents/MacOS/TerminalNavigator" 2>/dev/null || true
if [ -f "$OLD_AGENT" ]; then
    echo "==> Migrating from TerminalNavigator"
    launchctl unload "$OLD_AGENT" 2>/dev/null || true
    rm -f "$OLD_AGENT"
fi
[ -e "$PREFIX/TerminalNavigator.app" ] && rm -rf "$PREFIX/TerminalNavigator.app"

"$ROOT/scripts/make-app.sh" "$APP"

ln -sfn "$APP" "$PREFIX/TerminalNavigator.app"

echo "==> Registering hooks"
if [ -n "$AGENTS" ]; then
    python3 "$ROOT/scripts/register-hooks.py" --tnav "$TNAV" --agents "$AGENTS" | sed 's/^/    /'
else
    python3 "$ROOT/scripts/register-hooks.py" --tnav "$TNAV" | sed 's/^/    /'
fi

if [ "$LOGIN_ITEM" = "1" ]; then
    echo "==> Starting at login"
    mkdir -p "$(dirname "$AGENT")"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.github.ayekarimba.claudebar</string>
    <key>ProgramArguments</key> <array><string>$APP/Contents/MacOS/ClaudeBar</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <false/>
</dict>
</plist>
PLIST
    launchctl load "$AGENT" 2>/dev/null || true
    echo "    $AGENT"
else
    echo "==> Skipping login item (--no-login)"
    open -a "$APP"
fi

echo
echo "Installed: $APP"
echo
echo "ClaudeBar is now in your menu bar (look for the >_ icon)."
echo "Open the menu once and pick 'App Legend' to see what the colours mean."
echo
echo "Two things macOS will ask for, the first time each is needed:"
echo "  • Automation — to ask Terminal which tab a session is in. Required."
echo "  • Accessibility — to reach tabs on other desktops. Optional; without it"
echo "    only tabs on your current desktop can be jumped to."
echo
echo "Hooks were registered for every agent found on this machine (Claude Code, Codex,"
echo "Gemini CLI, Copilot CLI). Install another later and open Diagnostics… from the menu"
echo "to register it. Sessions already running appear at their next event."
echo
echo "To remove it all again:  ./scripts/uninstall.sh"
