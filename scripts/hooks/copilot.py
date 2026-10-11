"""Copilot CLI: a file of our own under ~/.copilot/hooks/, so merging is unnecessary and
removal is deleting one file. Copilot's payload does not name the event, so each entry passes
it on the command line."""
import os
from . import common

KIND = "copilot"
CONFIG_DIR = ".copilot"
FILE = os.path.join(CONFIG_DIR, "hooks", "agentsentinel.json")
EVENTS = ["sessionStart", "userPromptSubmitted", "preToolUse", "permissionRequest",
          "notification", "agentStop", "sessionEnd"]


def installed(home):
    return os.path.isdir(os.path.join(home, CONFIG_DIR))


def registered(home, tnav=None):
    try:
        data = common.read_json(os.path.join(home, FILE))
    except common.RegistrarError:
        return False
    if not data:
        return False
    hooks = data.get("hooks") or {}
    return all(any("tnav hook --agent copilot" in (h.get("bash", "")) for h in hooks.get(e, []))
               for e in ("agentStop", "permissionRequest"))


def register(home, tnav):
    tnav = os.path.abspath(tnav)
    data = {
        "version": 1,
        "hooks": {
            event: [{"type": "command",
                     "bash": f"{tnav} hook --agent copilot --event {event}",
                     "timeoutSec": 10}]
            for event in EVENTS
        },
    }
    path = os.path.join(home, FILE)
    common.write_json_atomic(path, data)
    return f"wrote {len(EVENTS)} copilot hooks to {path}"


def remove(home):
    path = os.path.join(home, FILE)
    if os.path.exists(path):
        os.remove(path)
        return f"removed {path}"
    return f"no {path}; nothing to remove"
