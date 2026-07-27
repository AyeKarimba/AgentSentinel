#!/bin/bash
# Remove TerminalNavigator: the app, the login item, and its Claude Code hooks.
#
# Leaves ~/.claude/tnav alone by default — it is small, and keeping it means a reinstall
# remembers your mutes and snoozes. Pass --purge to delete that too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.terminalnavigator.plist"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> Stopping"
pkill -f "TerminalNavigator.app/Contents/MacOS/TerminalNavigator" 2>/dev/null || true

if [ -f "$AGENT" ]; then
    echo "==> Removing login item"
    launchctl unload "$AGENT" 2>/dev/null || true
    rm -f "$AGENT"
fi

echo "==> Removing Claude Code hooks"
python3 "$ROOT/scripts/register-hooks.py" --remove | sed 's/^/    /'

for prefix in /Applications "$HOME/Applications"; do
    if [ -d "$prefix/TerminalNavigator.app" ]; then
        echo "==> Removing $prefix/TerminalNavigator.app"
        rm -rf "$prefix/TerminalNavigator.app"
    fi
done

if [ "$PURGE" = "1" ]; then
    echo "==> Removing ~/.claude/tnav"
    rm -rf "$HOME/.claude/tnav"
else
    echo "==> Keeping ~/.claude/tnav (settings and session state); --purge removes it"
fi

echo
echo "Done. Nothing of TerminalNavigator is left running."
echo "You may also want to drop it from System Settings → Privacy & Security →"
echo "Accessibility and Automation."
