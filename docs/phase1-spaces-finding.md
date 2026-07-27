# Phase 1 finding: Spaces break AppleScript-only focus

Discovered while verifying the focus mechanism on 2026-07-27. This is the most consequential
correction to the original design.

## What works

Precise tab focus **within a single Space** is proven. Jumps landed on the exact target tab,
settling in ~320ms:

```
jump /dev/ttys000 -> /dev/ttys000  PASS (331ms)
jump /dev/ttys002 -> /dev/ttys002  PASS (315ms)
jump /dev/ttys003 -> /dev/ttys003  PASS (327ms)
```

`tab.tty` as the join key, `SessionStore`, the hook pipeline, and nested-session rejection
are all verified and working.

## What does not work

`set index of window to 1` and `set frontmost of window to true` **silently fail** — they
report no AppleScript error and have zero effect — when the target window is on a different
Space. Confirmed by reading the window list before and after: order unchanged.

The reason surfaced via CoreGraphics (`kCGWindowIsOnscreen` is true only for windows on the
current Space):

```
1 of 9 Terminal windows are on the Space you're looking at.
```

The machine has **5 Spaces** (`~/Library/Preferences/com.apple.spaces.plist`), and Claude
sessions are scattered across them. So the failing case is the *normal* case, not an edge
case: the earlier partial successes were jumps that happened to stay inside one Space.

## Permission-free workarounds: all tested, all failed

| Strategy | Result |
|---|---|
| `set frontmost`, then `activate` | no effect |
| `activate`, delay, then `set frontmost` | no effect |
| `set index` + `activate` + `set frontmost` + `activate` | no effect |
| `reopen` + `activate` | no effect |
| `set visible false/true` + `set frontmost` | **rejected** — hides windows and silently reorders Terminal's window list; too destructive to ship |

`com.apple.dock workspaces-auto-swoosh` ("when switching to an application, switch to a Space
with open windows for it") is unset on this machine. Even enabled it selects *a* Space with
Terminal windows, not the one holding a specific window, so it cannot target a tab.

## Conclusion

Crossing Spaces to raise a specific window requires the **Accessibility API**
(`AXUIElementPerformAction(window, kAXRaiseAction)`). This is the same reason window managers
like Rectangle and yabai require it. Current state:

```
AXIsProcessTrusted() = false
AXUIElementCopyAttributeValue(kAXWindows) -> -25211 (kAXErrorAPIDisabled)
```

This corrects the original plan, which asserted the design needed no Accessibility
permission. That remains true for two features — frontmost-tab detection (`frontmost` is a
property of Terminal itself, no System Events involved) and the ⌥⌘J hotkey (Carbon
`RegisterEventHotKey`) — but **not** for cross-Space focus.

## Recommended design

Two focus backends behind the existing `TabController` protocol, chosen at runtime:

1. **`AXTabController`** — primary. `AXRaise` on the target window plus
   `NSRunningApplication.activate()`. Crosses Spaces. Needs Accessibility.
2. **`TerminalAppController`** — fallback, already built and tested. Same-Space only, needs
   no Accessibility.

`tnav doctor` reports which backend is live so a silent downgrade to same-Space-only is
never mistaken for a bug. Note the permission is granted per *responsible process*: the menu
bar app needs its own grant for notification clicks and the hotkey, and Terminal.app would
need one separately for `tnav jump` typed at a prompt.

## Correction (2026-07-27): the resolution below does not hold

**The Window-menu route does not switch Spaces. It drags the target window onto the desktop
you are already on.** Everything below this heading was written against a verification that
could not detect that, and is retained only for the reasoning it records.

The flaw: `verify-focus.py` checked that the target tab became frontmost. That is true whether
macOS switches to the window's desktop *or* pulls the window to yours, so a pull scored PASS.
The script now fingerprints every on-screen application window before and after each jump and
reports `switched desktop` vs `PULLED to this desktop`.

Isolated by removing one step at a time — with `selectTab` and `NSRunningApplication.activate()`
both taken out, leaving `AXUIElementPerformAction(item, kAXPressAction)` as the only action, the
window is still pulled. Ground truth for one jump, all apps:

```
windows that STAYED:       16  (the entire previous desktop, untouched)
windows that DISAPPEARED:   0
windows that APPEARED:      1  -> 4155, Terminal   (the target)
```

Setting `com.apple.dock workspaces-auto-swoosh` does not fix it: one jump switched desktops and
three pulled, which is the intermittency the behaviour presents as. The setting was reverted.

`focusByTemporaryTitle` is not implicated — path logging showed every jump taking the
exact-title branch, so the `defer`-restore during the Space transition never ran.

### The private API is blocked too, by SIP

`CGSManagedDisplaySetCurrentSpace` — what yabai and Amethyst use — is reachable, and the
lookups around it work: `CGSCopySpacesForWindows` correctly reports window 3871 on space 111,
and `CGSCopyManagedDisplaySpaces` returns display `37D8832A-…` holding spaces [3, 6, 90, 111].

But with System Integrity Protection **enabled**, which is the default, the switch call reports
success and updates the window server's own idea of the current Space while **the display never
changes**. Adding the fuller `CGSShowSpaces` / `CGSHideSpaces` sequence does not help. This is
why yabai requires SIP to be partially disabled before it will focus a Space.

Worse, it cannot be made safe by checking afterwards. The mutation happens on the **call**, so
a jump that correctly detected failure and declined had *already* desynchronised the system.
Observed on the test machine after a run: the window server reporting desktop 90 as current
while six visible windows belonged to desktop 6 — with symptoms to match, being swept to
another desktop unprompted, windows appearing unbidden, Stage Manager misbehaving. Spaces
bookkeeping is what Mission Control and Stage Manager are built on, so corrupting it is a
system-wide fault, not a local one. It took a logout to clear.

**The lesson worth keeping: a call that mutates global state cannot be made safe by validating
the result afterwards. The damage is already done. The only safe version is not calling it.**

That route is deleted and will not be reinstated.

### Where this leaves it

Refusing off-desktop jumps was tried and rejected on use: it turns the app into a dialog box,
since most tabs are usually on another desktop. So the shipped behaviour is the Window-menu
press — you always reach the tab, and a tab on another desktop arrives by its window coming to
you rather than you going to it.

That is a nuisance, and it is visible and undoable: the window is somewhere you can see and
drag back. It is the best of the three options, not a good one.

| Route | Reaches the tab | Side effect |
|---|---|---|
| AppleScript only | same desktop only | none |
| **Window menu (shipped)** | **always** | **brings the window to your desktop** |
| Window-server call | always, if SIP disabled | corrupts Spaces system-wide when SIP is on |

## Superseded resolution — retained for its reasoning

`AXRaise` turned out to be a dead end for the opposite reason to the AppleScript path:
`kAXWindows` enumerates only windows on the **current Space** (1 of 4 on this machine), so
there is no element to raise for an off-Space window.

What does work is Terminal's own **Window menu**, which lists every window across every
Space. `AXUIElementPerformAction(item, kAXPressAction)` on the matching item raises the
window *and* switches Space.

Verified with the real `tnav jump`, starting from a Space holding no Terminal windows:

```
tab            window     started        result
/dev/ttys002   85         this Space     PASS
/dev/ttys000   3871       ANOTHER Space  PASS
/dev/ttys001   4155       ANOTHER Space  PASS
/dev/ttys003   4312       ANOTHER Space  PASS
4/4 landed on the exact target tab
3 of those required crossing a Space
```

Reproduce with `python3 scripts/verify-focus.py`. It reports whether each window started on
the current Space, so a run where everything happened to be co-located cannot be mistaken for
proof of the cross-Space path.

### Two further bugs this uncovered

1. **`tab` is not the tab character inside a Terminal `tell` block.** Terminal's `tab` *class*
   shadows the constant, so `(id of aWindow) & tab & (name of aWindow)` yields the literal
   text `85tabwebapp — …`. Now joined with `linefeed`.
2. **A parse failure was reported as "tab not found", and "not found" pruned session
   records** — so a scripting quirk silently destroyed good state. `parseWindowInfo` now
   throws on an unparseable reply and returns nil only for a genuinely empty one, and
   `tnav jump` re-confirms against `knownTTYs()` before deleting anything. Covered by
   `WindowInfoParsingTests`.

### Ambiguous window titles

Window titles are not unique — two of this machine's windows read
`webapp — claude — …` and differ only by size. When more than one Window-menu item
matches, `AXWindowMenuController` stamps a unique temporary custom title on the target tab,
presses the now-unambiguous item, then restores the title.
