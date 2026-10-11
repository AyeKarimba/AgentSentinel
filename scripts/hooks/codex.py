"""Codex CLI: ~/.codex/hooks.json, `hooks` object, same group shape as Claude.

Codex skips hooks it has not been told to trust. After registering, the user runs `codex`
once and accepts the new hooks under `/hooks`; install.sh says so."""
import os
from . import common

KIND = "codex"
CONFIG_DIR = ".codex"
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd"]
REQUIRED = ["Stop", "PermissionRequest"]

installed, registered, _register, remove = common.grouped_registrar(
    KIND, os.path.join(CONFIG_DIR, "hooks.json"), "hooks", EVENTS, REQUIRED)


def register(home, tnav):
    # Codex's default hook timeout is 600s; ours finishes in milliseconds, so a tight cap means
    # a wedged hook can never hold a Codex turn.
    return _register(home, tnav, extra={"timeout": 10})
