#!/usr/bin/env python3
"""Register, remove or report AgentSentinel's hooks for every supported agent.

    register-hooks.py --tnav /path/to/tnav              every agent whose config dir exists
    register-hooks.py --tnav /path/to/tnav --agents codex,gemini
    register-hooks.py --remove [--agents ...]           default: all
    register-hooks.py --status                          one line per agent

Each agent's file is merged, never replaced: other tools' hooks on the same events are left
alone, a backup is written beside the file, and a file that does not parse is refused.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hooks import claude, codex, copilot, gemini  # noqa: E402
from hooks.common import RegistrarError          # noqa: E402

AGENTS = {m.KIND: m for m in (claude, codex, gemini, copilot)}


def main(argv):
    home = os.path.expanduser("~")
    tnav = None
    remove = "--remove" in argv
    status = "--status" in argv
    selected = None
    for index, arg in enumerate(argv):
        if arg == "--tnav" and index + 1 < len(argv):
            tnav = argv[index + 1]
        if arg == "--agents" and index + 1 < len(argv):
            selected = [a.strip() for a in argv[index + 1].split(",") if a.strip()]

    if selected:
        unknown = [a for a in selected if a not in AGENTS]
        if unknown:
            print(f"unknown agent(s): {', '.join(unknown)}; known: {', '.join(AGENTS)}", file=sys.stderr)
            return 2

    if status:
        for kind, module in AGENTS.items():
            inst = module.installed(home)
            reg = module.registered(home) if inst else False
            print(f"{kind:8} {'installed' if inst else 'absent':9} {'registered' if reg else 'not-registered'}")
        return 0

    if remove:
        kinds = selected or list(AGENTS)
        code = 0
        for kind in kinds:
            try:
                print(AGENTS[kind].remove(home))
            except RegistrarError as error:
                print(str(error), file=sys.stderr)
                code = 1
        return code

    if not tnav:
        print(__doc__, file=sys.stderr)
        return 2
    tnav = os.path.abspath(tnav)
    if not os.path.isfile(tnav):
        print(f"no tnav binary at {tnav}", file=sys.stderr)
        return 1

    kinds = selected or [k for k, m in AGENTS.items() if m.installed(home)]
    if not kinds:
        print("no supported agent found (looked for ~/.claude ~/.codex ~/.gemini ~/.copilot)")
        return 0
    code = 0
    for kind in kinds:
        try:
            print(AGENTS[kind].register(home, tnav))
        except RegistrarError as error:
            print(str(error), file=sys.stderr)
            code = 1
    if "codex" in kinds:
        print("codex: hooks run only once trusted — start `codex`, type /hooks, and accept the"
              " AgentSentinel entries. An edited hook is skipped again until re-trusted.")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
