# ⌘-click to Forget a Row — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘-clicking any row in the menu deletes that session's record file and removes the row, giving the user a manual way to dismiss a record that outlived its session.

**Architecture:** `SessionStore.remove(_:)` already exists (it backs the liveness prune), so the store layer is done. The work is app-layer wiring: a `forget` method on `SessionMonitor`, an `onForget` callback on `SessionRowView` triggered by a ⌘ modifier check in `mouseUp`, threading in `StatusItemController`, and one legend line. Spec: `docs/superpowers/specs/2026-07-31-forget-row-design.md`.

**Tech Stack:** Swift 5.9 / AppKit, XCTest via SwiftPM. No new dependencies.

## Global Constraints

- **Manual only.** No automatic pruning beyond the existing liveness prune. No duplicate-pid detection. This is deliberate; see the spec's "out of scope".
- No confirmation dialog — forgetting is safe by construction (a live session rewrites its record on its next hook event).
- ⌘ is checked **before** the row's control hit-tests and before ⌥, so ⌘⌥-click forgets, and ⌘-click over the snooze/mute icons forgets too.
- Run tests with `make test` / `make check`, never bare `swift test` — the Makefile sets `TNAV_STATE_DIR` to a scratch directory so library code can't write to the real `~/.claude/tnav`.
- Match the codebase's comment style: comments explain *why*, written as prose. No "added X" narration.

---

### Task 1: Pin the `SessionStore.remove` contract with tests

The UI will call `remove` with arbitrary records, so its edge behaviour must be pinned: removing a missing or unsafe id is a quiet no-op, and removing one session never touches another. `testRemove` (the happy path) already exists at `Tests/TNavCoreTests/SessionStoreTests.swift:49`.

**Files:**
- Modify: `Tests/TNavCoreTests/SessionStoreTests.swift` (insert after `testRemove`, line 54)

**Interfaces:**
- Consumes: `SessionStore.remove(_ sessionId: String)` — exists at `Sources/TNavCore/SessionStore.swift:54`; returns `Void`, never throws.
- Produces: nothing new — these tests are the contract Task 2's `forget` relies on.

- [ ] **Step 1: Add the two contract tests**

```swift
func testRemoveMissingOrUnsafeIdIsAQuietNoOp() throws {
    let store = SessionStore(directory: directory)
    try store.save(record())
    store.remove("never-existed")
    store.remove("../evil")
    XCTAssertEqual(store.all().map(\.sessionId), ["s1"],
                   "a bad id must not throw, and must not delete anything")
}

func testRemoveLeavesOtherRecordsAlone() throws {
    let store = SessionStore(directory: directory)
    try store.save(record(id: "s1"))
    try store.save(record(id: "s2"))
    store.remove("s1")
    XCTAssertNil(store.load("s1"))
    XCTAssertEqual(store.all().map(\.sessionId), ["s2"])
}
```

- [ ] **Step 2: Run the suite**

Run: `make test`
Expected: **PASS** (133 tests). These pin existing behaviour rather than drive new code — that is intentional, since `remove` already exists. **If either test FAILS, stop:** the store does not behave as the spec assumes, and Task 2 must not proceed on a broken assumption.

- [ ] **Step 3: Commit**

```bash
git add Tests/TNavCoreTests/SessionStoreTests.swift
git commit -m "Pin SessionStore.remove edge behaviour before wiring it to the UI"
```

---

### Task 2: Wire ⌘-click through monitor, row, controller, and legend

One task because the pieces cannot compile independently: adding a required `onForget` init parameter to `SessionRowView` breaks `StatusItemController` until it passes the callback.

**Files:**
- Modify: `Sources/TerminalNavigatorApp/SessionMonitor.swift` (insert after `noteVisit`, line 179)
- Modify: `Sources/TerminalNavigatorApp/SessionRowView.swift:31` (callback property), `:62` (init parameter), `:71` (assignment), `:284` (`mouseUp`)
- Modify: `Sources/TerminalNavigatorApp/StatusItemController.swift:368` (pass the callback)
- Modify: `Sources/TerminalNavigatorApp/Legend.swift:206` (one legend line)

**Interfaces:**
- Consumes: `SessionStore.remove(_:)` (Task 1's contract), `SessionMonitor.reload()` (exists, line 75), `EventLog.append(_:)`, `SessionRecord.project` (computed property, `SessionRecord.swift:84`).
- Produces: `SessionMonitor.forget(_ record: SessionRecord)` — the only new public-ish surface; nothing later depends on it.

- [ ] **Step 1: Add `forget` to `SessionMonitor`** (after `noteVisit`, before `snooze`)

```swift
/// Drops a record from the menu.
///
/// Safe by construction rather than by care: a session that is genuinely alive rewrites its
/// record on its next hook event, so forgetting one is at worst temporary. Only a record
/// with nothing behind it stays gone — which is precisely the one the user is trying to
/// remove, and the case that had no remedy at all before.
func forget(_ record: SessionRecord) {
    EventLog.append("forget: \(record.project) (\(record.tty)) dismissed by hand")
    store.remove(record.sessionId)
    reload()
}
```

- [ ] **Step 2: Add the callback to `SessionRowView`**

Property, alongside the existing callbacks (line 31):

```swift
private let onForget: (SessionRecord) -> Void
```

Init parameter after `onToggleSnooze` (line 62) and assignment (line 71):

```swift
onForget: @escaping (SessionRecord) -> Void
```

```swift
self.onForget = onForget
```

- [ ] **Step 3: Check ⌘ first in `mouseUp`** (line 284)

```swift
override func mouseUp(with event: NSEvent) {
    // ⌘ wins over everything on the row: over the snooze and mute icons, and over ⌥.
    // Like the controls, it does not dismiss the menu — the row visibly vanishes instead.
    if event.modifierFlags.contains(.command) {
        onForget(record)
        return
    }
    let location = convert(event.locationInWindow, from: nil)
    // Controls first, and neither dismisses the menu.
    if hitRect(around: muteIcon).contains(location) {
        onToggleMute(record)
        return
    }
    if hitRect(around: snoozeIcon).contains(location) {
        onToggleSnooze(record)
        return
    }
    enclosingMenuItem?.menu?.cancelTracking()
    onJump(record)
}
```

- [ ] **Step 4: Thread the callback in `StatusItemController`** (line 368, inside the `SessionRowView(` call)

```swift
onToggleSnooze: { [weak self] record in self?.toggleSnooze(record) },
onForget: { [weak self] record in self?.monitor.forget(record) }
```

- [ ] **Step 5: Add the legend line** (`Legend.swift`, after the "Clicking a row jumps…" heading at line 206)

```swift
menu.addItem(heading("⌘-click a row to forget it, if it outlived its session"))
```

- [ ] **Step 6: Build and verify the legend via dump-menu**

Run: `swift build && ./.build/debug/TerminalNavigatorApp --dump-menu | grep "⌘-click"`
Expected: one line containing `⌘-click a row to forget it, if it outlived its session`

- [ ] **Step 7: Run the full check**

Run: `make check`
Expected: 133 unit tests pass, then `integration: all checks passed`

- [ ] **Step 8: Commit**

```bash
git add Sources/TerminalNavigatorApp/SessionMonitor.swift Sources/TerminalNavigatorApp/SessionRowView.swift Sources/TerminalNavigatorApp/StatusItemController.swift Sources/TerminalNavigatorApp/Legend.swift
git commit -m "⌘-click a row to forget it"
```

---

### Task 3: Documentation and install

**Files:**
- Modify: `README.md` — Usage section (after the `⌥⌘J` line), Troubleshooting table ("A row won't go away" row), Development section (test count)

**Interfaces:**
- Consumes: the behaviour shipped in Task 2. Nothing produced for later tasks.

- [ ] **Step 1: Restore the Usage paragraph, manual-only wording** (insert after the line ending "`⌥⌘J` jumps to the oldest tab waiting on you.", before "There's also a CLI:")

```markdown
**⌘-click a row to forget it.** Records normally clean themselves up — a session that ends
fires a hook, and one whose process is gone gets pruned. The exception is a record that
outlives its session while naming a pid that is still alive: it never prunes, and the tab it
names belongs to someone else, so it can't be jumped to either. ⌘-click removes it. Forgetting
a session that is genuinely alive is harmless — it reappears on its next event.
```

- [ ] **Step 2: Update the Troubleshooting row**

Change:

```markdown
| A row won't go away and can't be jumped to | A record that outlived its session. Delete its JSON file under `~/.claude/tnav/sessions/`. |
```

to:

```markdown
| A row won't go away and can't be jumped to | A record that outlived its session. **⌘-click it to forget it.** |
```

- [ ] **Step 3: Update the test count**

Change `make test        # 131 unit tests` to `make test        # 133 unit tests`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: document ⌘-click to forget"
```

- [ ] **Step 5: Install and hand-verify**

Run: `make install`
Expected: "Installed: /Applications/TerminalNavigator.app". Then, by hand: open the menu, ⌘-click a row, and watch it disappear (it returns on that session's next hook event). Note for the user: `make install` re-signs the app, so macOS may ask for the Accessibility grant again.
