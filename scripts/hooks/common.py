"""Shared mechanics for the per-agent hook registrars.

Every config file these touch belongs to the user and may hold other tools' hooks on the
very same events. So: merge rather than write, remove only entries recognisable as ours,
back up first, write atomically, and never touch a file that does not parse.
"""
import copy
import json
import os
import shutil

OURS_MARKERS = ("tnav hook", "ClaudeBar.app", "TerminalNavigator.app", "AgentSentinel.app")


class RegistrarError(Exception):
    """A config file could not be read or is not shaped as expected; nothing was changed."""


def is_ours(command):
    text = str(command).strip()
    return any(marker in text for marker in OURS_MARKERS)


def read_json(path, snippet=None):
    """The parsed object, or None when the file does not exist. Raises RegistrarError rather
    than returning a default for a file that exists but cannot be parsed: replacing it would
    lose every other tool's configuration. `snippet`, when given, is the JSON text to offer
    for pasting by hand (some agents' settings files allow comments, which json cannot read)."""
    if not os.path.exists(path):
        return None
    try:
        with open(path) as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError) as error:
        message = (f"could not read {path}: {error}; leaving it untouched. The file may contain "
                   "comments or trailing commas, which this tool does not parse.")
        if snippet:
            message += (" Add the hooks by hand, or remove the comments and re-run. "
                        f"Paste this into {path}:\n{snippet}")
        else:
            message += " Fix it and re-run."
        raise RegistrarError(message)
    if not isinstance(data, dict):
        raise RegistrarError(f"{path} is not a JSON object; leaving it untouched")
    return data


def write_json_atomic(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".tnav-backup")
    tmp = path + ".tnav-tmp"
    with open(tmp, "w") as handle:
        json.dump(obj, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def strip_grouped(hooks):
    """Removes our entries from a Claude-shaped hooks dict:
    {event: [{"matcher"?: str, "hooks": [{"type": "command", "command": str}]}]}.
    Drops a group left empty by the removal, and an event left with no groups."""
    for event in list(hooks):
        if not isinstance(hooks.get(event), list):
            continue                          # a shape we do not understand is not ours to touch
        groups = []
        for group in hooks[event]:
            if not isinstance(group, dict) or not isinstance(group.get("hooks", []), list):
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


def merge_grouped(hooks, events, command, extra=None):
    """Appends one group per event holding our command, after stripping any older entries."""
    strip_grouped(hooks)
    entry = {"type": "command", "command": command}
    if extra:
        entry.update(extra)
    for event in events:
        if not isinstance(hooks.setdefault(event, []), list):
            raise RegistrarError(f"hooks for '{event}' is not a list; leaving the file untouched")
        hooks[event].append({"hooks": [entry]})
    return hooks


def grouped_has_ours(hooks, events, marker):
    """Whether every event in `events` has a command carrying `marker`."""
    if not isinstance(hooks, dict):
        return False
    for event in events:
        found = False
        groups = hooks.get(event)
        for group in groups if isinstance(groups, list) else []:
            if not isinstance(group, dict) or not isinstance(group.get("hooks", []), list):
                continue
            for h in group.get("hooks", []):
                command = h.get("command", "") if isinstance(h, dict) else str(h)
                if marker in command:
                    found = True
        if not found:
            return False
    return True


def grouped_registrar(kind, config_rel, root_key, events, required_events, legacy_markers=()):
    """Builds the module-level functions for an agent whose file is Claude-shaped.

    `root_key` is the key holding the events dict ("hooks" for every current agent).
    `required_events` are the ones `registered()` insists on — turn-complete and permission.
    """
    marker = f"tnav hook --agent {kind}"

    def config_path(home):
        return os.path.join(home, config_rel)

    def installed(home):
        return os.path.isdir(os.path.join(home, config_rel.split(os.sep)[0]))

    def registered(home, tnav=None):
        data = None
        try:
            data = read_json(config_path(home))
        except RegistrarError:
            return False
        if not data:
            return False
        hooks = data.get(root_key) or {}
        if grouped_has_ours(hooks, required_events, marker):
            return True
        return any(grouped_has_ours(hooks, required_events, m) for m in legacy_markers)

    def register(home, tnav, extra=None):
        path = config_path(home)
        command = f"{os.path.abspath(tnav)} hook --agent {kind}"
        snippet = json.dumps({root_key: merge_grouped({}, events, command, extra)}, indent=2)
        data = read_json(path, snippet) or {}
        hooks = data.get(root_key) or {}
        if not isinstance(hooks, dict):
            raise RegistrarError(f"'{root_key}' in {path} is not an object; leaving it untouched")
        merge_grouped(hooks, events, command, extra)
        data[root_key] = hooks
        write_json_atomic(path, data)
        return f"registered {len(events)} {kind} hooks in {path}"

    def remove(home):
        path = config_path(home)
        data = read_json(path)
        if not data:
            return f"no {path}; nothing to remove"
        hooks = data.get(root_key) or {}
        if not isinstance(hooks, dict):
            return f"nothing of ours in {path}"
        before = copy.deepcopy(hooks)
        strip_grouped(hooks)
        if hooks == before:
            return f"nothing of ours in {path}"
        if hooks:
            data[root_key] = hooks
        else:
            data.pop(root_key, None)
        write_json_atomic(path, data)
        return f"removed {kind} hooks from {path}"

    return installed, registered, register, remove
