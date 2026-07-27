# Phase 0 recon findings

Captured live on 2026-07-27, Claude Code 2.1.220, macOS 26.5.1, Apple Terminal.app.
Method: a throwaway `sh` hook registered on all five events, logging raw stdin plus the
PPID chain. Raw log: `~/.claude/tnav/recon.log`.

## Confirmed payload shapes

Every event carries `session_id`, `transcript_path`, `cwd`, `hook_event_name`.
Event-specific additions:

| Event | Extra fields |
|---|---|
| `SessionStart` | `source` (`"startup"`) |
| `UserPromptSubmit` | `prompt_id`, `permission_mode`, `prompt` |
| `Notification` | `prompt_id`, `message`, **`notification_type`** |
| `Stop` | `prompt_id`, `permission_mode`, `stop_hook_active`, **`last_assistant_message`**, `background_tasks`, `session_crons` |
| `SessionEnd` | `reason` (`"other"`) |

Observed `Notification` example:

```json
{"hook_event_name":"Notification","message":"Claude is waiting for your input",
 "notification_type":"idle_prompt", ...}
```

## Finding 1 — `last_assistant_message` is free

`Stop` ships the assistant's final message inline (observed: `"pong"`). The
"show what Claude actually said" label option was costed during design as requiring a
transcript JSONL tail-parse. **It doesn't.** It's a plain field on the payload.

Consequence: the richer label is now zero-cost and should be offered as a display toggle
rather than dismissed on performance grounds.

## Finding 2 — nested sessions alias onto the parent's TTY

The PPID walk works, but a nested session (Claude Code spawning `claude -p`, or any
subagent shelling out to `claude`) produces a chain with **two** `claude` ancestors:

```
19594 19575 ??       /bin/sh          ← the hook
19575 19571 ??       claude           ← nested `claude -p`
19571 17544 ??       /bin/zsh
17544 16972 ttys003  claude           ← the real interactive session
16972 16971 ttys003  -zsh
16971   645 ttys003  login
  645     1 ??       Terminal
```

Walking to the first real TTY yields `ttys003` — the *parent's* tab. A nested session
firing `Stop` would therefore mark the parent's tab "waiting" while the parent is
actually busy, producing a false notification.

A genuine top-level session has exactly one `claude` ancestor:

```
19703 12691 ??       /bin/sh
12691  1000 ttys002  claude           ← the session, directly
 1000   991 ttys002  -zsh
```

**Rule adopted:** count `claude` ancestors during the walk. More than one → nested →
ignore the event entirely. Nested sessions are never a tab the user needs to visit.

## Finding 3 — multi-session behaviour confirmed live

A `Notification` fired from an unrelated real session (`~/code/webapp`,
`ttys002`) mid-recon and resolved its own TTY correctly and independently. The
multi-session case is verified, not assumed.

## Finding 4 — latency budget is comfortable

The recon hook measured **63–86 ms**, and that is a shell script spawning `python3`
twice plus repeated `ps` calls. Claude Code tolerated it without visible stall, so a
compiled Swift binary (target <30 ms) has ample headroom.

## Open item

Only `notification_type: "idle_prompt"` was observed; the permission-request value was
not captured (headless mode auto-denies rather than prompting). Handled robustly instead
of guessed: `idle_prompt` maps to the idle tier, **any other value maps to urgent**, and
unrecognised values are appended to `~/.claude/tnav/events.log` so the real string
documents itself during normal use.
