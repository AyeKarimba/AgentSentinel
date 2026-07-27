# TerminalNavigator

A macOS menu bar app that tells you which Claude Code sessions are waiting on you, and takes
you to the right terminal tab when you click one.

Run Claude Code in six tabs and the hard part stops being the work — it's noticing that one of
them has been sitting on a permission prompt for ten minutes while you watched a different one
think. This puts that in the menu bar.

```
 >_ 2 · 4m          <- two tabs need you; the oldest has waited 4 minutes

 ● webapp            4m   needs your permission
 ● api               2m   Should I also update the tests?
 ● dotfiles         18m   you've opened it; still waiting on your reply
 ○ sandbox          31s   working
```

Colour answers *have you dealt with this*, not *what is it doing*. Red is a blocking request
you haven't opened, amber a finished turn you haven't opened, grey something you've looked at
but not answered, purple a session still working. Open a tab and its row goes quiet — the badge
moves on to the next one and disappears when nothing is left. There's a full **App Legend** in
the menu.

## Requirements

- macOS 13 or later
- Terminal.app (iTerm2, Ghostty and others aren't supported yet — see [Adding a terminal](#adding-a-terminal))
- [Claude Code](https://claude.com/claude-code)
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Install

```sh
git clone https://github.com/AyeKarimba/TerminalNavigator.git
cd TerminalNavigator
swift build -c release
```

Register the hooks in `~/.claude/settings.json`. Point every command at the `tnav` binary you
just built (use the absolute path):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/absolute/path/to/.build/release/tnav hook" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/absolute/path/to/.build/release/tnav hook" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/absolute/path/to/.build/release/tnav hook" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/absolute/path/to/.build/release/tnav hook" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/absolute/path/to/.build/release/tnav hook" }] }]
  }
}
```

Then start the menu bar app:

```sh
./.build/release/TerminalNavigatorApp &
```

Open **Diagnostics…** from the menu to confirm the hooks are registered and see which focus
backend is live.

### Permissions

- **Automation** (Terminal) — required. macOS prompts on first use.
- **Accessibility** — optional. Without it, only tabs on your current desktop can be reached.

## Known limitation: other desktops

**Clicking a tab on another desktop brings its window to you, instead of taking you to it.**

This is the honest state of the art, not an oversight. macOS offers no supported way for an app
to switch desktops:

| Route | Reaches the tab | Side effect |
|---|---|---|
| AppleScript | same desktop only | none |
| **Terminal's Window menu** (shipped) | always | brings the window to your desktop |
| Private window-server call | only with SIP disabled | **corrupts Spaces system-wide when SIP is on** |

The third was implemented, measured and removed. With System Integrity Protection enabled — the
default — `CGSManagedDisplaySetCurrentSpace` reports success and moves the window server's idea
of the current desktop while the display never changes, which breaks Mission Control and Stage
Manager machine-wide. Full measurements in
[`docs/phase1-spaces-finding.md`](docs/phase1-spaces-finding.md).

Refusing off-desktop jumps was also tried, and rejected: most tabs are usually on another
desktop, so it turned the app into a dialog box. Bringing the window to you is a nuisance, but a
visible and undoable one.

## Usage

Click any row to jump to that tab. The controls on each row snooze it for 10 minutes
(⌥-click for 30) or mute that tab entirely. `⌥⌘J` jumps to the oldest tab waiting on you.

There's also a CLI:

```sh
tnav list      # what's waiting, as text
tnav jump      # go to the oldest waiting tab
tnav spaces    # which tabs are on which desktop
tnav resolve   # explain how this tab was identified (debugging)
```

## How it works

Claude Code hooks fire on every session event. `tnav hook` resolves which terminal tab the
session belongs to by walking the process tree to its controlling TTY, then writes one JSON
file per session under `~/.claude/tnav/sessions/`. Those files are the entire contract: the
menu bar app can be closed, restarted or absent without state going wrong.

The app watches that directory, plus a Darwin notification the hook posts, plus a periodic
reload for the things neither can see — a tab closed, a tab switched to by hand, a config edit
from another process. End to end, a hook event reaches the menu in about 12ms.

`tab.tty` is the join key between a Claude session and a Terminal tab. It survives everything a
window title doesn't.

### Adding a terminal

Every terminal-specific call sits behind the `TabController` protocol
(`Sources/TNavCore/TabController.swift`). iTerm2 or Ghostty support means one new conformance;
the hook, state and UI layers don't change.

## Development

```sh
swift test                              # 119 unit tests
./scripts/integration-test.sh           # hook -> state -> list, against a scratch state dir
python3 scripts/verify-focus.py         # focus, including whether it crossed a desktop
./.build/debug/TerminalNavigatorApp --dump-menu   # render the menu as text
```

`--dump-menu` exists because an `NSStatusItem` menu can't be opened from another process via
Accessibility, so it's the only way to assert on what the menu actually shows.

`verify-focus.py` reports whether each jump **switched desktop** or **pulled the window** — the
original version only checked the tab became frontmost, which is true either way, and that gap
hid the limitation above for some time.

Set `TNAV_STATE_DIR` to point any binary at a scratch state directory.

## Design notes

- [`docs/phase0-recon-findings.md`](docs/phase0-recon-findings.md) — the hook payload shapes,
  measured rather than assumed
- [`docs/phase1-spaces-finding.md`](docs/phase1-spaces-finding.md) — the Spaces investigation,
  including a correction to its own earlier conclusion

## License

MIT — see [LICENSE](LICENSE).
