#!/bin/bash
# Remove ClaudeBar: the app, the login item, and its Claude Code hooks.
#
# Leaves ~/.claude/tnav alone by default — it is small, and keeping it means a reinstall
# remembers your mutes and snoozes. Pass --purge to delete that too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.claudebar.plist"
# The pre-rename login item, cleaned up too if a migration left it behind.
OLD_AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.terminalnavigator.plist"
PURGE=0

# Arguments are validated before anything is removed. Previously anything that was not exactly
# `--purge` was ignored, so `--help` silently began a full uninstall — a script whose entire job
# is deleting things has no business guessing at what it was asked to do.
while [ $# -gt 0 ]; do
    case "$1" in
        --purge)   PURGE=1; shift ;;
        -h|--help)
            echo "usage: uninstall.sh [--purge]"
            echo
            echo "  Removes the app, the login item and the hooks from every agent."
            echo "  --purge  also delete ~/.claude/tnav (settings and session state)"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; echo "try --help" >&2; exit 2 ;;
    esac
done

echo "==> Stopping"
pkill -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" 2>/dev/null || true
pkill -f "TerminalNavigator.app/Contents/MacOS/TerminalNavigator" 2>/dev/null || true

for agent in "$AGENT" "$OLD_AGENT"; do
    if [ -f "$agent" ]; then
        echo "==> Removing login item"
        launchctl unload "$agent" 2>/dev/null || true
        rm -f "$agent"
    fi
done

echo "==> Removing hooks from every agent"
python3 "$ROOT/scripts/register-hooks.py" --remove | sed 's/^/    /'

for prefix in /Applications "$HOME/Applications"; do
    for app in ClaudeBar.app TerminalNavigator.app; do
        if [ -e "$prefix/$app" ]; then
            echo "==> Removing $prefix/$app"
            rm -rf "$prefix/$app"
        fi
    done
done

if [ "$PURGE" = "1" ]; then
    echo "==> Removing ~/.claude/tnav"
    rm -rf "$HOME/.claude/tnav"
else
    echo "==> Keeping ~/.claude/tnav (settings and session state); --purge removes it"
fi

echo
echo "Done. Nothing of ClaudeBar is left running."
echo "You may also want to drop it from System Settings → Privacy & Security →"
echo "Accessibility and Automation."
