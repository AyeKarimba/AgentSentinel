"""Claude Code: ~/.claude/settings.json, `hooks` object, Claude-shaped groups."""
import os
from . import common

KIND = "claude"
CONFIG_DIR = ".claude"
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
REQUIRED = ["Stop", "Notification"]

installed, registered, register, remove = common.grouped_registrar(
    KIND, os.path.join(CONFIG_DIR, "settings.json"), "hooks", EVENTS, REQUIRED,
    # Hooks written by the 1.0.x builds had no --agent flag.
    legacy_markers=("tnav hook",),
)
