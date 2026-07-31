# ⌘-click to forget a row — design

**Date:** 2026-07-31
**Status:** approved

## Problem

A session record can outlive its session while naming a pid that is still alive
(because that pid now belongs to a different session). The liveness check passes, so
the record never prunes; the tab it names belongs to someone else, so it cannot be
jumped to. The current app gives the user no way to remove such a row short of
deleting JSON files in `~/.claude/tnav/sessions/` by hand. This is the "shows a
terminal as working while I'm just typing in it" bug.

Deliberately out of scope: any automatic pruning (e.g. duplicate-pid detection).
This project has twice removed automatic heuristics that decided things for the
user; this feature is manual-only by design. Auto-pruning can be revisited later if
hand-dismissing proves tedious.

## Behaviour

- **⌘-click any row** in the menu forgets that session:
  1. one line is appended to the event log recording the dismissal,
  2. the session's JSON record file under `~/.claude/tnav/sessions/` is deleted,
  3. the menu reloads immediately.
- No confirmation dialog. Forgetting is safe by construction: a live session
  rewrites its record on its next hook event, so at worst a forgotten row
  reappears. Only a record with nothing behind it stays gone — exactly the one the
  user is trying to remove.
- Click semantics are otherwise unchanged: plain click jumps, ⌥-click snoozes.
  ⌘ is checked **before** ⌥, so ⌘⌥-click forgets rather than snoozes.
- Works on any row regardless of state colour.

## Components

Five touch points, mirroring the previously shipped manual path (d534104) adapted
to the current (reverted) code:

| Unit | Change |
|---|---|
| `Sources/TNavCore/SessionStore.swift` | `remove(_ sessionId: String)` — deletes the record file; quiet no-op if already gone |
| `Sources/TerminalNavigatorApp/SessionMonitor.swift` | `forget(_ record: SessionRecord)` — event-log line, `store.remove`, `reload()` |
| `Sources/TerminalNavigatorApp/SessionRowView.swift` | new `onForget` callback; ⌘ modifier check first in the click handler |
| `Sources/TerminalNavigatorApp/StatusItemController.swift` | thread the forget callback through row construction |
| `Sources/TerminalNavigatorApp/Legend.swift` | one line documenting ⌘-click |

## Error handling

The dismissal is logged unconditionally, before the delete is attempted — the log line
records that the user asked to forget the row, not whether the file removal succeeded.
A failed delete (permissions, file already gone) is tolerated silently: there is nothing
useful to do about it, so nothing is surfaced, and the reload happens regardless. The
menu always shows whatever record files actually exist — the files are the source of
truth, so no in-memory state can drift from them.

## Testing

Unit tests on `SessionStore.remove`:

- removing an existing record deletes its file and drops it from subsequent loads,
- removing a missing session id is a quiet no-op (no throw, no side effects),
- other sessions' files are untouched.

Run via `make test` / `make check`, which point the tests at a scratch state
directory (`TNAV_STATE_DIR`) rather than the user's real `~/.claude/tnav`.

## Documentation

- README **Usage**: restore a short "⌘-click a row to forget it" paragraph,
  worded for the manual-only behaviour (no mention of automatic pruning).
- README **Troubleshooting**: the "row won't go away" remedy changes from
  "delete its JSON file" to "⌘-click it to forget it".
