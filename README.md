# AgentSentinel

A macOS menu bar app that tells you which CLI coding agent sessions are waiting on you, and
takes you to the right terminal tab when you click one. Works with Claude Code, Codex CLI,
Gemini CLI and Copilot CLI. An unofficial community tool, not affiliated with any of their
makers. Formerly ClaudeBar, and before that TerminalNavigator.

Run four agents in six tabs and the hard part stops being the work — it's noticing that one of
them has been sitting on a permission prompt for ten minutes while you watched a different one
think. This puts that in the menu bar.

<img src="docs/screenshot.png" alt="AgentSentinel's menu: two tabs needing attention in red, one already-opened in grey, and one still working in purple" width="430">

Colour answers *have you dealt with this*, not *what is it doing* — and the menu explains
itself, so nobody has to memorise it:

<img src="docs/legend.png" alt="The App Legend submenu, listing every colour and marker with its meaning" width="470">

Colour answers *have you dealt with this*, not *what is it doing*:

| | |
|---|---|
| **red** | needs your permission — you haven't opened it yet |
| **orange** | finished its turn — you haven't opened it yet |
| **grey** | you've opened it; still waiting on your reply |
| **purple** | an agent is working; nothing is needed from you |

Open a tab and its row goes quiet — the badge moves to the next one, and disappears once
nothing is left waiting on you.

The icon follows the same scale, so a glance at the menu bar is enough:

| Icon | Meaning |
|---|---|
| grey `>_` | no agent sessions at all |
| purple `>_ 3` | 3 tabs working; nothing wants you |
| orange `>_ 1 · 2m` | a tab has finished and is waiting on you |
| red `>_ 2 · 4m` | a tab needs your permission |

## Requirements

- macOS 13 or later
- Terminal.app (iTerm2, Ghostty and others aren't supported yet — see [Adding a terminal](#adding-a-terminal))
- At least one of: Claude Code, Codex CLI, Gemini CLI, Copilot CLI
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Agents

| Agent | How it's wired | Verified live |
|---|---|---|
| Claude Code | hooks in `~/.claude/settings.json` | yes |
| Codex CLI | hooks in `~/.codex/hooks.json` — after installing, start `codex`, type `/hooks` and accept the AgentSentinel entries, or they are silently skipped | partly — SessionStart/UserPromptSubmit captured live; Stop and PermissionRequest from the docs |
| Gemini CLI | hooks in `~/.gemini/settings.json` | not yet — hooks are registered from the documented payload shape; please report what you see |
| Copilot CLI | `~/.copilot/hooks/agentsentinel.json` | not yet — same |

`make install` registers hooks for every agent whose config directory exists. Install another
agent later and open **Diagnostics…** from the menu: it lists each agent's status and offers a
button to register it. Each row shows a two-letter tag (`CC`, `CX`, `GM`, `CP`) and, when the
agent reports it, the model.

Hermes Agent, OpenCode and Cursor CLI have hook systems too and are not yet supported; each is
one adapter in `Sources/TNavCore/Agents/` plus one registrar in `scripts/hooks/`.

## Install

```sh
git clone https://github.com/AyeKarimba/AgentSentinel.git
cd AgentSentinel
make install
```

That's it. It builds `AgentSentinel.app`, installs it to `/Applications`, registers the
hooks for every agent it finds, starts it at login, and launches it. The `>_` icon appears in your menu bar.

To remove everything again:

```sh
make uninstall
```

<details>
<summary>What <code>make install</code> actually does</summary>

- Builds a release binary and assembles it into a proper `.app` bundle, ad-hoc signed. This is
  not cosmetic: macOS ties Accessibility and Automation permission to a bundle identity, and a
  bare binary run out of `.build` gets a new identity on every rebuild — so permissions
  silently lapse.
- Registers hooks with every agent found (Claude Code, Codex, Gemini CLI, Copilot CLI), merging
  into each agent's config and backing it up first, pointing at the `tnav` inside the bundle.
  It **merges**: any hooks you already have, including other tools' hooks on the same events,
  are left alone, and re-running replaces its own entries rather than duplicating them.
- Installs a LaunchAgent so it starts at login. Skip with `make install ARGS=--no-login`, or
  `./scripts/install.sh --no-login`.
- Installs to `~/Applications` instead if `/Applications` isn't writable.

`make uninstall` reverses all of it and leaves `~/Library/Application Support/AgentSentinel` in place so your mutes and
snoozes survive a reinstall; `./scripts/uninstall.sh --purge` removes that too.
</details>

Already-running agent sessions appear at their next event — send a message in one and it
shows up. New sessions appear immediately.

### Permissions

macOS will ask for these the first time each is needed:

- **Automation** (Terminal) — required, to ask Terminal which tab a session is in.
- **Accessibility** — optional, to reach tabs on other desktops.

Open **Diagnostics…** from the menu to check hook registration and which focus backend is live.

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

## Getting your attention

The badge is passive — fine if you glance at the menu bar, useless if you're deep in something
else. So a tab that starts waiting can also raise a banner, play a sound, and pulse the menu
bar icon. All of it is adjustable under **Settings…** (`⌘,`):

| | |
|---|---|
| **Banner** | on/off, three sizes, how long it stays, and whether it may appear over fullscreen apps |
| **Sound** | on/off, volume, and separate sounds for "waiting" and "needs permission" |
| **Pulse** | on/off, strength, and whether finished turns pulse or only permission requests |

Permission requests always pulse deeper and faster than finished turns — the difference between
*there's something for you* and *something is stuck* should be felt, not read.

Each request alerts **once**, at the moment it happens — a banner is never delivered late. A
permission request that stays unanswered reminds you at the urgent sound on a short ladder —
after 5, 10 and 15 minutes — and then goes quiet for good; finished turns never re-alert.
Muting, snoozing and pausing all suppress alerts entirely.

The banner is the app's own window rather than a system notification, and that's a deliberate
trade. macOS fixes the size of a system notification and decides from your Focus settings
whether it may appear over a fullscreen app — an app gets no say in either. Making those two
adjustable required owning the window. The cost is that this banner does not respect Do Not
Disturb, which is why **show over fullscreen apps is off by default**: going fullscreen is often
precisely a request not to be interrupted.

## Usage

Click any row to jump to that tab, or click a banner to go straight to the tab that raised it.
The controls on each row snooze it for 10 minutes (⌥-click for 30) or mute that tab entirely.
`⌥⌘J` jumps to the oldest tab waiting on you.

**⌘-click a row to forget it.** Records normally clean themselves up — a session that ends
fires a hook, and one whose process is gone gets pruned. The exception is a record that
outlives its session while naming a pid that is still alive: it never prunes, and the tab it
names belongs to someone else, so it can't be jumped to either. ⌘-click removes it. Forgetting
a session that is genuinely alive is harmless — it reappears on its next event.

There's also a CLI:

```sh
tnav list      # what's waiting, as text
tnav jump      # go to the oldest waiting tab
tnav spaces    # which tabs are on which desktop
tnav resolve   # explain how this tab was identified (debugging)
```

## Troubleshooting

Open **Diagnostics…** from the menu first — it reports whether each agent's hooks are registered and
which focus backend is live, which covers most of these.

| What you see | What it is |
|---|---|
| Nothing in the menu, ever | Hooks aren't registered for that agent. Diagnostics lists each agent; use its Register button or re-run `make install`. |
| Codex sessions never appear | Codex skips hooks it has not been told to trust. Start `codex`, type `/hooks`, accept the AgentSentinel entries. |
| Gemini hooks won't register | `~/.gemini/settings.json` may contain comments; this tool refuses files it cannot round-trip. Paste the snippet the installer prints, or remove the comments and re-run. |
| A session you're already running doesn't appear | Expected. Records are created by hook events, so send a message in that tab and it shows up. New sessions appear immediately. |
| "Could not switch to that tab" | Automation permission for Terminal was denied. System Settings → Privacy & Security → Automation. |
| Jumping brings the window to you instead of switching desktop | A macOS limitation, not a bug — see [above](#known-limitation-other-desktops). |
| Cross-desktop jumps worked, then stopped | Accessibility permission is keyed to the binary's code signature, and `make install` rebuilds it. Re-grant under Privacy & Security → Accessibility. A `make run` build loses it on *every* rebuild. |
| A row won't go away and can't be jumped to | A record that outlived its session. **⌘-click it to forget it.** |
| No banners or sounds | Check **Settings…** (`⌘,`), and that the tab isn't muted or snoozed and notifications aren't paused. |

## What it touches

Worth being explicit, because this reads what your agents say.

**Reads** the hook payload each agent hands it: session id, working directory, event name,
permission message, and the agent's closing message when the agent includes it. It never opens a
transcript file.

**Writes** to `~/Library/Application Support/AgentSentinel/` only — one JSON file per session,
plus `config.json`, `visits.json`, `alerts.json` and `events.log`. Installing also adds hook
entries to each detected agent's config file, merging rather than replacing, with a backup
alongside. On first launch after upgrading from ClaudeBar, state is copied from `~/.claude/tnav`;
the old directory is left in place until `uninstall.sh --purge`.

**Sends nothing anywhere.** There is no networking code in the repo — no `URLSession`, no
sockets. Verifiable in one grep.

The agent's closing message is stored in the session file and shown in the menu row (the banner
shows only the project name and what happened).
If you'd rather it weren't, turn off **Show the agent's last message**; the rows fall back to a
generic reason like "needs permission". `./scripts/uninstall.sh --purge` removes the state directory entirely.

## How it works

Each agent's hooks fire on every session event, as `tnav hook --agent <kind>`. The adapter for
that agent (`Sources/TNavCore/Agents/`) turns the payload into one of six normalized events;
everything after that is agent-independent. `tnav` resolves which terminal tab the
session belongs to by walking the process tree to its controlling TTY, then writes one JSON
file per session under `~/Library/Application Support/AgentSentinel/sessions/`. Those files are the entire contract: the
menu bar app can be closed, restarted or absent without state going wrong.

The app watches that directory, plus a Darwin notification the hook posts, plus a periodic
reload for the things neither can see — a tab closed, a tab switched to by hand, a config edit
from another process. End to end, a hook event reaches the menu in about 12ms.

`tab.tty` is the join key between an agent session and a Terminal tab. It survives everything a
window title doesn't.

### Adding a terminal

Every terminal-specific call sits behind the `TabController` protocol
(`Sources/TNavCore/TabController.swift`). iTerm2 or Ghostty support means one new conformance;
the hook, state and UI layers don't change.

### Adding an agent

Three pieces, none of which touch the state machine or the UI:

1. An `AgentAdapter` conformance in `Sources/TNavCore/Agents/` mapping the agent's events to
   `AgentEvent` (session start, prompt submitted, tool starting, turn complete, needs
   permission, session end). Add it to `AgentRegistry` and `AgentKind.known`.
2. A process signature in `AgentKind.signature` so the hook can find the agent in its own
   ancestry — the binary name, or the package path fragment for a Node program.
3. A registrar module in `scripts/hooks/` that merges `tnav hook --agent <kind>` into the
   agent's config, plus the matching `HookRegistration` entries for Diagnostics.

## Development

```sh
make test          # unit tests
make test-scripts  # registrar tests
make check         # both, plus the hook integration test
make run         # run from source, without installing
make app         # build the .app into ./build without installing
make clean
```

Note that `make run` uses the binary in `.build`, whose signature changes on every rebuild —
so macOS drops its Accessibility grant and cross-desktop jumps quietly stop working. That is a
property of unsigned local builds, not a bug. `make install` is the one that behaves
consistently.

Other tools:

```sh
python3 scripts/verify-focus.py                   # does a jump switch desktop, or pull the window?
./.build/debug/AgentSentinelApp --dump-menu   # render the menu as text
swift scripts/make-icon.swift                     # regenerate Resources/AppIcon.icns
```

`--dump-menu` exists because an `NSStatusItem` menu can't be opened from another process via
Accessibility, so it's the only way to assert on what the menu actually shows.

`verify-focus.py` reports whether each jump **switched desktop** or **pulled the window** — the
original version only checked the tab became frontmost, which is true either way, and that gap
hid the limitation above for some time.

Set `TNAV_STATE_DIR` to point any binary at a scratch state directory. The integration test
exports `TNAV_HOOK_IGNORE_ANCESTRY_MISMATCH=1` so its canned per-agent payloads are accepted
even when run from inside an agent's own process tree; it is a test-only knob.

## Design notes

- [`docs/phase0-recon-findings.md`](docs/phase0-recon-findings.md) — the hook payload shapes,
  measured rather than assumed
- [`docs/phase1-spaces-finding.md`](docs/phase1-spaces-finding.md) — the Spaces investigation,
  including a correction to its own earlier conclusion
- [`docs/superpowers/specs/2026-10-10-multi-agent-design.md`](docs/superpowers/specs/2026-10-10-multi-agent-design.md) — the multi-agent design, with the per-agent feasibility table

## Contributing

Issues and pull requests welcome. Two things worth knowing before changing anything:

- **`make check`** runs the unit tests plus a hook-to-menu integration test. `--dump-menu`
  renders the menu as text, which is the only way to assert on it — an `NSStatusItem` menu
  can't be opened from another process.
- **`docs/`** records why things are the way they are, including a correction where the
  project disproves its own earlier conclusion about Spaces. If you find one of those
  conclusions wrong, that's the most useful kind of contribution.

Every terminal-specific call sits behind `TabController`, so iTerm2 or Ghostty support is one
new conformance.

## License

MIT — see [LICENSE](LICENSE).
