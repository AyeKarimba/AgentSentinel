#!/usr/bin/env python3
"""Register (or remove) ClaudeBar's hooks in ~/.claude/settings.json.

The file belongs to the user, not to us: it may already hold hooks for other tools, on these
very same events. So this merges rather than writes — it only ever removes entries it can
identify as its own, leaves everything else untouched, and takes a backup first.

Re-running is safe. Existing ClaudeBar entries are replaced, not duplicated, so an
upgrade that moves the binary does the right thing.

    register-hooks.py /path/to/tnav      # install or update
    register-hooks.py --remove           # uninstall
"""
import json
import os
import shutil
import sys

EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
SETTINGS = os.path.expanduser("~/.claude/settings.json")


def is_ours(command):
    """Whether a hook command is one of ours, wherever the binary happens to live."""
    text = str(command).strip()
    return text.endswith("tnav hook") or "ClaudeBar.app" in text or "TerminalNavigator.app" in text


def strip_ours(hooks):
    """Removes our entries from a hooks dict, dropping any group left empty."""
    for event in list(hooks):
        groups = []
        for group in hooks.get(event) or []:
            if not isinstance(group, dict):
                groups.append(group)
                continue
            kept = [h for h in group.get("hooks", [])
                    if not is_ours(h.get("command", "") if isinstance(h, dict) else h)]
            if kept:
                groups.append({**group, "hooks": kept})
            elif not group.get("hooks"):
                groups.append(group)      # a group that never had hooks is not ours to drop
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    return hooks


def main():
    remove = "--remove" in sys.argv
    tnav = None
    if not remove:
        args = [a for a in sys.argv[1:] if not a.startswith("--")]
        if len(args) != 1:
            print("usage: register-hooks.py /path/to/tnav | --remove", file=sys.stderr)
            return 2
        tnav = os.path.abspath(args[0])
        if not os.path.isfile(tnav):
            print(f"no tnav binary at {tnav}", file=sys.stderr)
            return 1

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    settings = {}
    if os.path.exists(SETTINGS):
        try:
            with open(SETTINGS) as handle:
                settings = json.load(handle)
        except (json.JSONDecodeError, OSError) as error:
            # Never overwrite a file we could not read: a malformed settings.json is the
            # user's to fix, and replacing it would lose every other tool's configuration.
            print(f"could not read {SETTINGS}: {error}", file=sys.stderr)
            print("leaving it untouched — fix the JSON and re-run", file=sys.stderr)
            return 1
        shutil.copy2(SETTINGS, SETTINGS + ".tnav-backup")

    if not isinstance(settings, dict):
        print(f"{SETTINGS} is not a JSON object; leaving it untouched", file=sys.stderr)
        return 1

    hooks = settings.get("hooks") or {}
    if not isinstance(hooks, dict):
        print(f"'hooks' in {SETTINGS} is not an object; leaving it untouched", file=sys.stderr)
        return 1

    strip_ours(hooks)
    if not remove:
        for event in EVENTS:
            hooks.setdefault(event, []).append(
                {"hooks": [{"type": "command", "command": f"{tnav} hook"}]})

    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)

    tmp = SETTINGS + ".tnav-tmp"
    with open(tmp, "w") as handle:
        json.dump(settings, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, SETTINGS)

    other = sum(len(g.get("hooks", [])) for groups in hooks.values()
                for g in groups if isinstance(g, dict)) - (0 if remove else len(EVENTS))
    if remove:
        print(f"removed ClaudeBar hooks from {SETTINGS}")
    else:
        print(f"registered {len(EVENTS)} hooks in {SETTINGS}")
    if other > 0:
        print(f"  ({other} hook(s) belonging to other tools left untouched)")
    if os.path.exists(SETTINGS + ".tnav-backup"):
        print(f"  backup: {SETTINGS}.tnav-backup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
