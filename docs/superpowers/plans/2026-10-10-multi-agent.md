# Multi-Agent Support and Rename to AgentSentinel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agent a pluggable concept so the menu bar app tracks Claude Code, Codex CLI, Gemini CLI and Copilot CLI sessions, tags each row with its agent, and ships under the name AgentSentinel.

**Architecture:** Hooks are registered per agent as `tnav hook --agent <kind>`. Each agent has an `AgentAdapter` in `Sources/TNavCore/Agents/` that decodes its payload into a normalized `AgentEvent`; `HookProcessor` consumes only that. `AgentMatcher` recognises every known agent in the process tree, including Node-based ones by script path, so TTY resolution and nested-session detection work across agents. Python registrars under `scripts/hooks/` write each agent's hook config; the app's Diagnostics reads the same files back.

**Tech Stack:** Swift 5.9 (SwiftPM, XCTest, AppKit), Python 3 standard library (registrars + unittest), bash integration test, `jq`.

**Spec:** `docs/superpowers/specs/2026-10-10-multi-agent-design.md`

## Probe result (done before this plan, 2026-10-10)

A Codex `SessionStart`/`UserPromptSubmit` hook was run from a Terminal tab with an isolated `CODEX_HOME` and `codex exec --dangerously-bypass-hook-trust`. Findings that this plan relies on:

- Codex runs hooks as `codex → bash → tnav`, with the `codex` process owning the tab's TTY (`argv0 = codex`, Mach-O binary). The existing ancestry walk resolves it with no change. No fallback needed.
- Live Codex payload shape (SessionStart):
  `{"session_id":"01a128e2-…","transcript_path":"…/rollout-….jsonl","cwd":"/…","hook_event_name":"SessionStart","model":"gpt-5","permission_mode":"bypassPermissions","source":"startup"}`
  UserPromptSubmit adds `turn_id` and `prompt`.
- Hooks placed in `hooks.json` were **silently skipped** until trusted. Codex prints `hook: SessionStart` / `hook: SessionStart Completed` lines on stderr when hooks run. Trust is granted interactively with `/hooks` inside Codex; the install script must say so.
- Inline `-c hooks.SessionStart=[…]` overrides did not run hooks; use `hooks.json`.
- Node entry points: `@google/gemini-cli` installs `gemini → dist/index.js`; `@github/copilot` installs `copilot → index.js`. The script basename is `index.js` in both, so matching must use the package directory in the script path, not the basename.

## Global Constraints

- macOS 13+, Swift 5.9+, no external Swift dependencies (Package.swift comment: hook cold-start matters).
- The hook binary always exits 0 and never writes to stdout; every event, every agent.
- The hook does no subprocess spawning; syscalls plus one file write only.
- Records written by the current build must keep loading: a `SessionRecord` without `agent` decodes as Claude; a bare `<sessionId>.json` file still loads.
- `TNAV_STATE_DIR` keeps overriding the state directory for every binary.
- The app never opens a transcript file, for any agent.
- Config files the registrars touch belong to the user: merge, back up to `<file>.tnav-backup`, write atomically, refuse to touch a file that does not parse.
- The CLI stays `tnav`. The app becomes `AgentSentinel`; bundle id `com.github.ayekarimba.agentsentinel` (keeps the existing `com.github.ayekarimba.` prefix used by the LaunchAgent label).
- All unit tests run with `TNAV_STATE_DIR` pointing at a scratch directory (`make test` does this).

## Review Focus

1. A session record on disk written by the shipped 1.0.1 build (no `agent`, no `model`, filename `<id>.json`) must appear in the menu as a Claude row after upgrade, and must not appear twice once its hook rewrites it. Pinned in Task 1 (`testLegacyRecordDecodesAsClaude`, `testSavingLegacyRecordRemovesBareFile`).
2. `tnav hook --agent something-unknown` must exit 0, print nothing, write nothing. Pinned in Task 5 (integration test "unknown agent").
3. A Copilot payload has no event-name field; the hook must take the event from `--event` and must not crash without it. Pinned in Task 8 (`testUsesEventHintWhenPayloadHasNoEventName`, `testMissingHintYieldsNoEvent`).
4. A Node process that is not an agent (`argv0 = node`, `argv1 = /app/server.js`) must not be recognised as Gemini or Copilot, or every Node dev server would count as an agent ancestor. Pinned in Task 4 (`testUnrelatedNodeScriptIsNotAnAgent`).
5. Codex `PermissionRequest` hooks can answer the prompt from stdout; ours must print nothing. Pinned in Task 6 (integration "PermissionRequest prints nothing on stdout").

---

## File structure

**Create (Swift, TNavCore):**
- `Sources/TNavCore/AgentKind.swift` — the `AgentKind` struct, display name, tag, config directory, process signature.
- `Sources/TNavCore/Agents/AgentEvent.swift` — `AgentEvent`, `DecodedHook`, `AgentAdapter` protocol, `AgentRegistry`.
- `Sources/TNavCore/Agents/ClaudeAdapter.swift`, `CodexAdapter.swift`, `GeminiAdapter.swift`, `CopilotAdapter.swift` — one per agent.
- `Sources/TNavCore/Agents/HookJSON.swift` — tiny shared helper for reading string fields out of `[String: Any]`.
- `Sources/TNavCore/HookRegistration.swift` — reads each agent's config file to answer "installed?" and "registered?" for Diagnostics.
- `Sources/TNavCore/StateMigration.swift` — one-time copy from `~/.claude/tnav` to the new state directory.

**Modify (Swift):**
- `Sources/TNavCore/SessionRecord.swift` — `agent`, `model`, lenient decoding, `storageKey`.
- `Sources/TNavCore/SessionStore.swift` — filename `<agent>-<id>.json`, legacy load, legacy cleanup on save.
- `Sources/TNavCore/HookProcessor.swift` — consumes `DecodedHook`; `HookPayload` and `HookEventKind` are deleted.
- `Sources/TNavCore/ProcessTable.swift` — `argv1`, `AgentMatcher` replaces `ClaudeMatcher`.
- `Sources/TNavCore/TTYResolver.swift` — `agentAncestors`, `nearestAgent`.
- `Sources/TNavCore/Paths.swift` — new root, legacy root.
- `Sources/TNavCore/StatusSummary.swift` — strings.
- `Sources/tnav/HookCommand.swift`, `ResolveCommand.swift`, `ListCommand.swift`, `main.swift` — `--agent`, `--event`, agent column.
- `Sources/ClaudeBarApp/*` (renamed to `Sources/AgentSentinelApp/` in Task 13) — row tag, legend, banner, diagnostics, strings.

**Create (scripts):**
- `scripts/hooks/__init__.py`, `common.py`, `claude.py`, `codex.py`, `gemini.py`, `copilot.py`, `test_registrars.py`.

**Modify (scripts):** `scripts/register-hooks.py` (becomes the CLI over the package), `install.sh`, `uninstall.sh`, `make-app.sh`, `integration-test.sh`, `Makefile`, `Package.swift`, `README.md`.

**Tests (Swift):** `Tests/TNavCoreTests/AgentKindTests.swift`, `Agents/ClaudeAdapterTests.swift`, `Agents/CodexAdapterTests.swift`, `Agents/GeminiAdapterTests.swift`, `Agents/CopilotAdapterTests.swift`, `HookRegistrationTests.swift`, `StateMigrationTests.swift`; modified `HookProcessorTests.swift`, `TTYResolverTests.swift`, `SessionStoreTests.swift`, `StatusSummaryTests.swift`, `BadgeQueueTests.swift`, `SnoozeAndUnseenTests.swift`.

Run all Swift tests with:

```bash
TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -20
```

Run one test class with:

```bash
TNAV_STATE_DIR="$(mktemp -d)" swift test --filter AgentKindTests 2>&1 | tail -20
```

---

### Task 1: `AgentKind` and the record/store changes

**Files:**
- Create: `Sources/TNavCore/AgentKind.swift`
- Modify: `Sources/TNavCore/SessionRecord.swift`
- Modify: `Sources/TNavCore/SessionStore.swift`
- Test: `Tests/TNavCoreTests/AgentKindTests.swift` (new), `Tests/TNavCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces: `AgentKind` (struct, `rawValue: String`; statics `.claude .codex .gemini .copilot`, `known`, `displayName`, `tag`, `configDirectoryName: String?`), `SessionRecord.agent: AgentKind`, `SessionRecord.model: String?`, `SessionRecord.storageKey: String`, `SessionStore.load(agent:sessionId:)`, `SessionStore.remove(agent:sessionId:)`, `SessionStore.remove(_ record:)`.
- Callers that change in this task: `SessionMonitor.forget` (`store.remove(record)`), `JumpCommand` (`store.remove(record)`), `HookCommand` (temporarily `load(agent: .claude, …)` / `remove(agent: .claude, …)`; Task 5 replaces these).

- [ ] **Step 1: Write the failing `AgentKind` tests**

Create `Tests/TNavCoreTests/AgentKindTests.swift`:

```swift
import XCTest
@testable import TNavCore

final class AgentKindTests: XCTestCase {
    func testKnownKindsHaveDistinctTagsAndNames() {
        let tags = AgentKind.known.map(\.tag)
        XCTAssertEqual(Set(tags).count, tags.count, "two agents must never share a row tag")
        XCTAssertEqual(AgentKind.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentKind.codex.displayName, "Codex")
        XCTAssertEqual(AgentKind.gemini.displayName, "Gemini CLI")
        XCTAssertEqual(AgentKind.copilot.displayName, "Copilot CLI")
        XCTAssertEqual(AgentKind.claude.tag, "CC")
        XCTAssertEqual(AgentKind.codex.tag, "CX")
        XCTAssertEqual(AgentKind.gemini.tag, "GM")
        XCTAssertEqual(AgentKind.copilot.tag, "CP")
    }

    func testUnknownKindStillHasAUsableTagAndName() {
        // A record from a newer build must render, not crash the menu.
        let future = AgentKind(rawValue: "hermes")
        XCTAssertEqual(future.displayName, "hermes")
        XCTAssertEqual(future.tag, "HE")
        XCTAssertNil(future.configDirectoryName)
    }

    func testKindRoundTripsThroughJSONAsItsRawString() throws {
        let data = try JSONEncoder().encode(AgentKind.codex)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"codex\"")
        XCTAssertEqual(try JSONDecoder().decode(AgentKind.self, from: data), .codex)
    }

    func testConfigDirectories() {
        XCTAssertEqual(AgentKind.claude.configDirectoryName, ".claude")
        XCTAssertEqual(AgentKind.codex.configDirectoryName, ".codex")
        XCTAssertEqual(AgentKind.gemini.configDirectoryName, ".gemini")
        XCTAssertEqual(AgentKind.copilot.configDirectoryName, ".copilot")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter AgentKindTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'AgentKind' in scope`.

- [ ] **Step 3: Create `AgentKind`**

Create `Sources/TNavCore/AgentKind.swift`:

```swift
import Foundation

/// Which CLI coding agent a session belongs to.
///
/// A struct rather than an enum so that any raw string decodes: a record written by a newer
/// build with an agent this build does not know still loads and renders, showing its raw
/// value as the tag. The known kinds are the ones with adapters and registrars.
public struct AgentKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let claude = AgentKind(rawValue: "claude")
    public static let codex = AgentKind(rawValue: "codex")
    public static let gemini = AgentKind(rawValue: "gemini")
    public static let copilot = AgentKind(rawValue: "copilot")

    /// Every kind this build ships an adapter for, in display order.
    public static let known: [AgentKind] = [.claude, .codex, .gemini, .copilot]

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .copilot: return "Copilot CLI"
        default: return rawValue
        }
    }

    /// Two-letter label shown on each row. Unknown kinds use the first two letters of
    /// their raw value, uppercased, so they still read as *something*.
    public var tag: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "CX"
        case .gemini: return "GM"
        case .copilot: return "CP"
        default: return String(rawValue.prefix(2)).uppercased()
        }
    }

    /// Directory under `$HOME` whose presence means "this agent is installed". Nil for kinds
    /// this build cannot register hooks for.
    public var configDirectoryName: String? {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        case .gemini: return ".gemini"
        case .copilot: return ".copilot"
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run the `AgentKind` tests**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter AgentKindTests 2>&1 | tail -5`
Expected: 4 tests pass.

- [ ] **Step 5: Write the failing record and store tests**

Append to `Tests/TNavCoreTests/SessionStoreTests.swift`, inside the class:

```swift
    // MARK: - Agents

    func testLegacyRecordDecodesAsClaude() throws {
        // Exactly what the 1.0.1 build writes: no `agent`, no `model`.
        let legacy = """
        {"cwd":"/tmp/proj","escalated":false,"notified":false,"pid":100,"reason":"turn_complete",\
        "sessionId":"s1","since":1000,"state":"waiting","tty":"/dev/ttys003"}
        """
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(record.agent, .claude)
        XCTAssertNil(record.model)
        XCTAssertEqual(record.sessionId, "s1")
    }

    func testRecordRoundTripsAgentAndModel() throws {
        var original = record(id: "c1")
        original.agent = .codex
        original.model = "gpt-6-astra"
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.agent, .codex)
        XCTAssertEqual(decoded.model, "gpt-6-astra")
    }

    func testStorageKeyIsAgentThenId() {
        var r = record(id: "abc")
        r.agent = .gemini
        XCTAssertEqual(r.storageKey, "gemini-abc")
    }

    func testSaveWritesAgentPrefixedFileAndLoadFindsIt() throws {
        let store = SessionStore(directory: directory)
        var r = record(id: "s1")
        r.agent = .codex
        try store.save(r)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex-s1.json").path))
        XCTAssertEqual(store.load(agent: .codex, sessionId: "s1"), r)
        XCTAssertNil(store.load(agent: .claude, sessionId: "s1"), "same id under another agent is a different record")
    }

    func testLoadFallsBackToBareLegacyFilenameForClaude() throws {
        let legacy = """
        {"cwd":"/tmp/proj","escalated":false,"notified":false,"pid":100,"reason":"turn_complete",\
        "sessionId":"s1","since":1000,"state":"waiting","tty":"/dev/ttys003"}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("s1.json"))
        let store = SessionStore(directory: directory)
        XCTAssertEqual(store.load(agent: .claude, sessionId: "s1")?.sessionId, "s1")
        XCTAssertNil(store.load(agent: .codex, sessionId: "s1"), "legacy files are Claude's only")
    }

    func testSavingLegacyRecordRemovesBareFile() throws {
        // Upgrade path: the first hook after upgrading rewrites the record under the new name;
        // the old file must go or the menu shows the session twice.
        let legacy = """
        {"cwd":"/tmp/proj","escalated":false,"notified":false,"pid":100,"reason":"turn_complete",\
        "sessionId":"s1","since":1000,"state":"waiting","tty":"/dev/ttys003"}
        """
        let bare = directory.appendingPathComponent("s1.json")
        try Data(legacy.utf8).write(to: bare)
        let store = SessionStore(directory: directory)
        let loaded = try XCTUnwrap(store.load(agent: .claude, sessionId: "s1"))
        try store.save(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.path))
        XCTAssertEqual(store.all().count, 1)
    }

    func testRemoveByAgentAndIdRemovesBothSpellings() throws {
        let store = SessionStore(directory: directory)
        try store.save(record(id: "s1"))                                  // claude-s1.json
        try Data("{}".utf8).write(to: directory.appendingPathComponent("s1.json"))
        store.remove(agent: .claude, sessionId: "s1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("claude-s1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("s1.json").path))
    }
```

Also update the existing tests in that file that call `store.load("s1")` and `store.remove("s1")`: replace with `store.load(agent: .claude, sessionId: "s1")` and `store.remove(agent: .claude, sessionId: "s1")`. In `testRemoveMissingOrUnsafeIdIsAQuietNoOp`, use `store.remove(agent: .claude, sessionId: "never-existed")` and `store.remove(agent: .claude, sessionId: "../evil")`. In `testRejectsSessionIdsThatWouldEscapeTheDirectory` and `testSaveThrowsOnUnsafeSessionId` keep the `url(for:)` calls but pass the new signature `store.url(agent: .claude, sessionId: "../../etc/passwd")` etc.

- [ ] **Step 6: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter SessionStoreTests 2>&1 | tail -5`
Expected: compile errors about `agent`, `model`, `storageKey`, `load(agent:sessionId:)`.

- [ ] **Step 7: Update `SessionRecord`**

In `Sources/TNavCore/SessionRecord.swift`, replace the `SessionRecord` struct declaration (from `public struct SessionRecord` through the end of `init`) with:

```swift
public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    /// Which agent this session belongs to. Absent in records written before 1.1, which
    /// were all Claude's.
    public var agent: AgentKind
    /// Model name when the agent's payload states it (Codex does); nil otherwise.
    public var model: String?
    public var tty: String
    public var pid: Int32
    public var cwd: String
    public var state: SessionState
    public var reason: WaitReason?
    /// Unix time the session entered its current state. Preserved across reason upgrades so
    /// "waiting 4m" and the escalation timer both measure from the original wait.
    public var since: Double
    /// Unix time the current `reason` was set, when that is later than `since`.
    ///
    /// Exists because preserving `since` across an upgrade — right for the elapsed label — is
    /// wrong for "have you seen this". A turn completion you glanced at and left can become a
    /// permission request a minute later; measured from `since`, your earlier visit would
    /// vouch for information that did not exist when you made it, and the tab would drop out
    /// of the badge while genuinely blocked. Optional so records from an older build decode.
    public var reasonSince: Double?
    public var notified: Bool
    public var escalated: Bool
    /// `Stop` ships this inline, so the richer label costs nothing to support.
    public var lastAssistantMessage: String?

    public init(sessionId: String,
                agent: AgentKind = .claude,
                model: String? = nil,
                tty: String,
                pid: Int32,
                cwd: String,
                state: SessionState,
                reason: WaitReason? = nil,
                since: Double,
                reasonSince: Double? = nil,
                notified: Bool = false,
                escalated: Bool = false,
                lastAssistantMessage: String? = nil) {
        self.sessionId = sessionId
        self.agent = agent
        self.model = model
        self.tty = tty
        self.pid = pid
        self.cwd = cwd
        self.state = state
        self.reason = reason
        self.since = since
        self.reasonSince = reasonSince
        self.notified = notified
        self.escalated = escalated
        self.lastAssistantMessage = lastAssistantMessage
    }

    // Decoded by hand so a record from the 1.0.x build — no `agent`, no `model` — still loads
    // as the Claude session it was, instead of failing and vanishing from the menu.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tty = try c.decode(String.self, forKey: .tty)
        pid = try c.decode(Int32.self, forKey: .pid)
        cwd = try c.decode(String.self, forKey: .cwd)
        state = try c.decode(SessionState.self, forKey: .state)
        reason = try c.decodeIfPresent(WaitReason.self, forKey: .reason)
        since = try c.decode(Double.self, forKey: .since)
        reasonSince = try c.decodeIfPresent(Double.self, forKey: .reasonSince)
        notified = try c.decodeIfPresent(Bool.self, forKey: .notified) ?? false
        escalated = try c.decodeIfPresent(Bool.self, forKey: .escalated) ?? false
        lastAssistantMessage = try c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
    }

    /// Filename stem for this record: `<agent>-<sessionId>`. Two agents can in principle hand
    /// out the same id, and the prefix also makes a directory listing readable.
    public var storageKey: String { "\(agent.rawValue)-\(sessionId)" }
```

Keep the rest of the file (`project`, `urgency`, `attentionSince`, `elapsed`, `summary`, `tabMuteKey`) unchanged.

- [ ] **Step 8: Update `SessionStore`**

In `Sources/TNavCore/SessionStore.swift`, replace `url(for:)`, `load(_:)`, `save(_:)`, `remove(_:)` with:

```swift
    /// Sanitised filename stem for a record, or nil when the id is not safe as a filename.
    static func stem(agent: AgentKind, sessionId: String) -> String? {
        guard let safe = sanitize(sessionId), sanitize(agent.rawValue) != nil else { return nil }
        return "\(agent.rawValue)-\(safe)"
    }

    public func url(agent: AgentKind, sessionId: String) -> URL? {
        guard let stem = Self.stem(agent: agent, sessionId: sessionId) else { return nil }
        return directory.appendingPathComponent("\(stem).json")
    }

    /// Where the 1.0.x build kept the same record: a bare `<sessionId>.json`. Only Claude
    /// sessions ever lived there.
    func legacyURL(sessionId: String) -> URL? {
        guard let safe = Self.sanitize(sessionId) else { return nil }
        return directory.appendingPathComponent("\(safe).json")
    }

    public func load(agent: AgentKind, sessionId: String) -> SessionRecord? {
        if let url = url(agent: agent, sessionId: sessionId),
           let data = try? Data(contentsOf: url),
           let record = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            return record
        }
        guard agent == .claude,
              let legacy = legacyURL(sessionId: sessionId),
              let data = try? Data(contentsOf: legacy),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
        else { return nil }
        return record
    }

    /// Atomic: `.atomic` writes a temp file and renames, so a concurrent reader in the app
    /// never observes a partially written record. Also retires the pre-1.1 bare filename for
    /// the same session, so an upgraded install does not list it twice.
    public func save(_ record: SessionRecord) throws {
        guard let url = url(agent: record.agent, sessionId: record.sessionId) else {
            throw StoreError.invalidSessionId(record.sessionId)
        }
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        if record.agent == .claude, let legacy = legacyURL(sessionId: record.sessionId) {
            try? fileManager.removeItem(at: legacy)
        }
    }

    public func remove(agent: AgentKind, sessionId: String) {
        if let url = url(agent: agent, sessionId: sessionId) {
            try? fileManager.removeItem(at: url)
        }
        if agent == .claude, let legacy = legacyURL(sessionId: sessionId) {
            try? fileManager.removeItem(at: legacy)
        }
    }

    public func remove(_ record: SessionRecord) {
        remove(agent: record.agent, sessionId: record.sessionId)
    }
```

In `prune(_:)`, change `remove(record.sessionId)` to `remove(record)`. In `prune()` the survivors/removed logic uses `sessionId` strings; leave it.

- [ ] **Step 9: Fix the callers**

- `Sources/tnav/HookCommand.swift`: `store.load(payload.sessionId)` → `store.load(agent: .claude, sessionId: payload.sessionId)`; `store.remove(sessionId)` → `store.remove(agent: .claude, sessionId: sessionId)`. (Task 5 replaces this file.)
- `Sources/ClaudeBarApp/SessionMonitor.swift` `forget`: `store.remove(record.sessionId)` → `store.remove(record)`.
- `Sources/tnav/JumpCommand.swift`: `store.remove(record.sessionId)` → `store.remove(record)`.

- [ ] **Step 10: Run the whole suite**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -5`
Expected: all tests pass (existing count plus 11 new).

- [ ] **Step 11: Commit**

```bash
git add Sources/TNavCore/AgentKind.swift Sources/TNavCore/SessionRecord.swift Sources/TNavCore/SessionStore.swift \
        Sources/tnav/HookCommand.swift Sources/tnav/JumpCommand.swift Sources/ClaudeBarApp/SessionMonitor.swift \
        Tests/TNavCoreTests/AgentKindTests.swift Tests/TNavCoreTests/SessionStoreTests.swift
git commit -m "Records carry their agent; store files are agent-prefixed

AgentKind is a struct so unknown kinds still decode. Records without
the field load as Claude, bare <id>.json files still load, and saving
retires the legacy filename so an upgrade never lists a session twice.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `AgentEvent`, `DecodedHook`, `AgentAdapter`, and the Claude adapter

**Files:**
- Create: `Sources/TNavCore/Agents/AgentEvent.swift`
- Create: `Sources/TNavCore/Agents/HookJSON.swift`
- Create: `Sources/TNavCore/Agents/ClaudeAdapter.swift`
- Test: `Tests/TNavCoreTests/Agents/ClaudeAdapterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum AgentEvent: Equatable, Sendable {
      case sessionStart, promptSubmitted, toolStarting, sessionEnd, idlePrompt
      case turnComplete(lastMessage: String?)
      case needsPermission(message: String?)
  }
  public struct DecodedHook: Equatable, Sendable {
      public let sessionId: String; public let cwd: String; public let model: String?
      public let rawEventName: String; public let event: AgentEvent?
  }
  public enum HookDecodeError: Error { case notAnObject, missingField(String) }
  public protocol AgentAdapter: Sendable {
      var kind: AgentKind { get }
      /// `eventHint` is the `--event` argument; adapters whose payload names the event ignore it.
      func decode(_ data: Data, eventHint: String?) throws -> DecodedHook
  }
  public enum AgentRegistry { public static func adapter(for kind: AgentKind) -> AgentAdapter? }
  enum HookJSON { static func object(_ data: Data) throws -> [String: Any]; static func string(_ o: [String: Any], _ key: String) -> String? }
  public struct ClaudeAdapter: AgentAdapter
  ```
- `AgentRegistry` returns only `ClaudeAdapter` in this task; Tasks 6–8 add the others.

- [ ] **Step 1: Write the failing Claude adapter tests**

Create `Tests/TNavCoreTests/Agents/ClaudeAdapterTests.swift`:

```swift
import XCTest
@testable import TNavCore

final class ClaudeAdapterTests: XCTestCase {
    private let adapter = ClaudeAdapter()

    private func decode(_ json: String) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: nil)
    }

    // Shapes captured live in Phase 0 (docs/phase0-recon-findings.md).

    func testStopCarriesLastMessage() throws {
        let hook = try decode("""
        {"session_id":"9cf7abf1","transcript_path":"/tmp/t.jsonl","cwd":"/Users/you/code/webapp",\
        "prompt_id":"bf47","permission_mode":"default","hook_event_name":"Stop",\
        "stop_hook_active":false,"last_assistant_message":"pong","background_tasks":[],"session_crons":[]}
        """)
        XCTAssertEqual(hook.sessionId, "9cf7abf1")
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertNil(hook.model)
        XCTAssertEqual(hook.rawEventName, "Stop")
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: "pong"))
    }

    func testIdlePromptNotificationIsTheSoftReminder() throws {
        let hook = try decode("""
        {"session_id":"20aae48f","cwd":"/Users/you/code/webapp","hook_event_name":"Notification",\
        "message":"Claude is waiting for your input","notification_type":"idle_prompt"}
        """)
        XCTAssertEqual(hook.event, .idlePrompt)
    }

    func testAnyOtherNotificationTypeNeedsPermission() throws {
        // The permission type was never observed in recon; unknown must be urgent, not dropped.
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"Notification",\
        "message":"Claude needs your permission","notification_type":"tool_permission_v9"}
        """)
        XCTAssertEqual(hook.event, .needsPermission(message: "Claude needs your permission"))
        let untyped = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"Notification"}"#)
        XCTAssertEqual(untyped.event, .needsPermission(message: nil))
    }

    func testLifecycleEvents() throws {
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SessionStart","source":"startup"}"#).event, .sessionStart)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"go"}"#).event, .promptSubmitted)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash"}"#).event, .toolStarting)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SessionEnd","reason":"other"}"#).event, .sessionEnd)
    }

    func testUnknownEventDecodesWithNilEventAndKeepsItsName() throws {
        let hook = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SubagentStop"}"#)
        XCTAssertNil(hook.event)
        XCTAssertEqual(hook.rawEventName, "SubagentStop")
    }

    func testMissingSessionIdThrows() {
        XCTAssertThrowsError(try decode(#"{"cwd":"/p","hook_event_name":"Stop"}"#))
    }

    func testNonObjectThrows() {
        XCTAssertThrowsError(try decode("[1,2,3]"))
        XCTAssertThrowsError(try decode("not json"))
    }

    func testRegistryKnowsClaude() {
        XCTAssertEqual(AgentRegistry.adapter(for: .claude)?.kind, .claude)
        XCTAssertNil(AgentRegistry.adapter(for: AgentKind(rawValue: "nope")))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter ClaudeAdapterTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'ClaudeAdapter' in scope`.

- [ ] **Step 3: Create the event vocabulary and adapter protocol**

Create `Sources/TNavCore/Agents/AgentEvent.swift`:

```swift
import Foundation

/// What a hook event means, independent of which agent sent it. This is the whole vocabulary
/// the state machine in `HookProcessor` understands; each adapter's job is to translate its
/// agent's event names into these.
public enum AgentEvent: Equatable, Sendable {
    case sessionStart
    case promptSubmitted
    case toolStarting
    /// The agent finished its turn and is waiting for the user to say something.
    case turnComplete(lastMessage: String?)
    /// Claude Code's soft reminder about a minute after a turn ends. No other agent has an
    /// equivalent, and it is deliberately not urgent — see `WaitReason.idlePrompt`.
    case idlePrompt
    /// The agent is blocked on a permission prompt.
    case needsPermission(message: String?)
    case sessionEnd
}

/// An agent's hook payload, reduced to what the state machine needs.
public struct DecodedHook: Equatable, Sendable {
    public let sessionId: String
    public let cwd: String
    /// Stated by the payload when the agent includes it (Codex does), nil otherwise.
    public let model: String?
    /// The agent's own event name, for logging the ones that are not mapped.
    public let rawEventName: String
    /// Nil when the agent sent an event this adapter does not map. Logged and ignored.
    public let event: AgentEvent?

    public init(sessionId: String, cwd: String, model: String?, rawEventName: String, event: AgentEvent?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.model = model
        self.rawEventName = rawEventName
        self.event = event
    }
}

public enum HookDecodeError: Error, Equatable, CustomStringConvertible {
    case notAnObject
    case missingField(String)

    public var description: String {
        switch self {
        case .notAnObject: return "payload is not a JSON object"
        case .missingField(let name): return "payload lacks \(name)"
        }
    }
}

/// One conformance per agent. Decoding is the only agent-specific step in the hook path;
/// everything after it works on `DecodedHook`.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// - Parameter eventHint: the `--event` argument the hook was registered with. Adapters
    ///   whose payload names the event ignore it; Copilot's does not, so it needs it.
    func decode(_ data: Data, eventHint: String?) throws -> DecodedHook
}

public enum AgentRegistry {
    public static func adapter(for kind: AgentKind) -> AgentAdapter? {
        switch kind {
        case .claude: return ClaudeAdapter()
        default: return nil
        }
    }
}
```

Create `Sources/TNavCore/Agents/HookJSON.swift`:

```swift
import Foundation

/// The adapters read a handful of string fields out of a JSON object. `JSONSerialization`
/// rather than `Codable` because each agent's payload has a different shape, and a missing
/// optional field must never make the whole payload undecodable.
enum HookJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any]
        else { throw HookDecodeError.notAnObject }
        return object
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    static func required(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = string(object, key) else { throw HookDecodeError.missingField(key) }
        return value
    }

    /// Nested lookup, e.g. `tool_input.description`.
    static func string(_ object: [String: Any], _ key: String, _ nested: String) -> String? {
        (object[key] as? [String: Any]).flatMap { $0[nested] as? String }
    }
}
```

Create `Sources/TNavCore/Agents/ClaudeAdapter.swift`:

```swift
import Foundation

/// Claude Code. Field names verified against live payloads in Phase 0 —
/// see docs/phase0-recon-findings.md.
public struct ClaudeAdapter: AgentAdapter {
    public let kind: AgentKind = .claude

    /// The one notification type observed in recon. Anything else is treated as a
    /// permission request rather than guessed at: unknown means urgent, not ignored.
    public static let idlePromptType = "idle_prompt"

    public init() {}

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = try HookJSON.required(object, "hook_event_name")
        let event: AgentEvent?
        switch name {
        case "SessionStart": event = .sessionStart
        case "UserPromptSubmit": event = .promptSubmitted
        case "PreToolUse": event = .toolStarting
        case "Stop": event = .turnComplete(lastMessage: HookJSON.string(object, "last_assistant_message"))
        case "Notification":
            event = HookJSON.string(object, "notification_type") == Self.idlePromptType
                ? .idlePrompt
                : .needsPermission(message: HookJSON.string(object, "message"))
        case "SessionEnd": event = .sessionEnd
        default: event = nil
        }
        return DecodedHook(sessionId: try HookJSON.required(object, "session_id"),
                           cwd: try HookJSON.required(object, "cwd"),
                           model: nil,
                           rawEventName: name,
                           event: event)
    }
}
```

- [ ] **Step 4: Run the adapter tests**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter ClaudeAdapterTests 2>&1 | tail -5`
Expected: 8 tests pass. The rest of the suite still compiles because `HookPayload` is untouched for now.

- [ ] **Step 5: Commit**

```bash
git add Sources/TNavCore/Agents Tests/TNavCoreTests/Agents
git commit -m "Normalized AgentEvent vocabulary and the Claude adapter

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `HookProcessor` consumes `DecodedHook`

**Files:**
- Modify: `Sources/TNavCore/HookProcessor.swift` (delete `HookPayload`, `HookEventKind`)
- Modify: `Sources/TNavCore/TTYResolver.swift` (`SessionIdentity` field rename only; matcher work is Task 4)
- Modify: `Sources/tnav/HookCommand.swift` (minimal, keeps building; Task 5 finishes it)
- Modify: `Sources/tnav/ResolveCommand.swift` (field rename)
- Test: `Tests/TNavCoreTests/HookProcessorTests.swift` (rewrite), `Tests/TNavCoreTests/TTYResolverTests.swift` (rename)

**Interfaces:**
- Produces:
  ```swift
  public struct SessionIdentity { let tty: String; let sessionPid: Int32; let agentAncestors: Int; let nearestAgent: AgentKind?; var isNested: Bool }
  public enum HookOutcome { case updated(SessionRecord); case removed(agent: AgentKind, sessionId: String); case ignoredNested; case ignoredUnknownEvent(String) }
  public enum HookProcessor {
      static func apply(agent: AgentKind, hook: DecodedHook, identity: SessionIdentity, existing: SessionRecord?, now: Double) -> HookOutcome
  }
  ```

- [ ] **Step 1: Rewrite `HookProcessorTests`**

Replace the whole of `Tests/TNavCoreTests/HookProcessorTests.swift` with:

```swift
import XCTest
@testable import TNavCore

final class HookProcessorTests: XCTestCase {
    private let id = "9cf7abf1-94cb-4db1-912a-38247f0898b6"
    private let cwd = "/Users/you/code/MacTerminalNavigator"
    private let identity = SessionIdentity(tty: "/dev/ttys003", sessionPid: 17544,
                                           agentAncestors: 1, nearestAgent: .claude)
    private let nested = SessionIdentity(tty: "/dev/ttys003", sessionPid: 17544,
                                         agentAncestors: 2, nearestAgent: .claude)

    private func hook(_ event: AgentEvent?, raw: String = "X", model: String? = nil) -> DecodedHook {
        DecodedHook(sessionId: id, cwd: cwd, model: model, rawEventName: raw, event: event)
    }

    private func apply(_ event: AgentEvent?, raw: String = "X", agent: AgentKind = .claude,
                       model: String? = nil, existing: SessionRecord? = nil,
                       identity: SessionIdentity? = nil, now: Double) -> HookOutcome {
        HookProcessor.apply(agent: agent, hook: hook(event, raw: raw, model: model),
                            identity: identity ?? self.identity, existing: existing, now: now)
    }

    private func waiting(reason: WaitReason, since: Double, notified: Bool, escalated: Bool = false) -> SessionRecord {
        SessionRecord(sessionId: id, tty: "/dev/ttys003", pid: 17544, cwd: cwd,
                      state: .waiting, reason: reason, since: since,
                      notified: notified, escalated: escalated)
    }

    private func working(since: Double) -> SessionRecord {
        SessionRecord(sessionId: id, tty: "/dev/ttys003", pid: 17544, cwd: "/tmp/x",
                      state: .working, since: since)
    }

    // MARK: - Nested and unknown

    func testIgnoresNestedSessionEntirely() {
        XCTAssertEqual(apply(.turnComplete(lastMessage: nil), identity: nested, now: 1000), .ignoredNested)
    }

    func testUnknownEventIsIgnoredByName() {
        XCTAssertEqual(apply(nil, raw: "SubagentStop", now: 1000), .ignoredUnknownEvent("SubagentStop"))
    }

    // MARK: - Agent and model land on the record

    func testRecordCarriesAgentAndModel() {
        let outcome = apply(.sessionStart, agent: .codex, model: "gpt-6-astra", now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.agent, .codex)
        XCTAssertEqual(record.model, "gpt-6-astra")
    }

    func testModelPersistsWhenALaterEventOmitsIt() {
        var existing = working(since: 500)
        existing.agent = .codex
        existing.model = "gpt-6-astra"
        let outcome = apply(.turnComplete(lastMessage: "done"), agent: .codex, existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.model, "gpt-6-astra")
    }

    func testSessionEndRemovesRecordForThatAgent() {
        XCTAssertEqual(apply(.sessionEnd, agent: .gemini, now: 1000),
                       .removed(agent: .gemini, sessionId: id))
    }

    // MARK: - Reason mapping

    func testTurnCompleteIsNormalUrgency() {
        let outcome = apply(.turnComplete(lastMessage: "pong"), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .waiting)
        XCTAssertEqual(record.reason, .turnComplete)
        XCTAssertEqual(record.urgency, .normal)
        XCTAssertEqual(record.since, 1000)
        XCTAssertFalse(record.notified)
        XCTAssertEqual(record.lastAssistantMessage, "pong")
        XCTAssertEqual(record.tty, "/dev/ttys003")
        XCTAssertEqual(record.project, "MacTerminalNavigator")
    }

    func testIdlePromptIsNotUrgent() {
        let outcome = apply(.idlePrompt, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .idlePrompt)
        XCTAssertEqual(record.urgency, .normal)
    }

    func testNeedsPermissionIsUrgentAndCarriesItsMessage() {
        let outcome = apply(.needsPermission(message: "Allow Bash?"), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .permission)
        XCTAssertEqual(record.urgency, .urgent)
        XCTAssertEqual(record.lastAssistantMessage, "Allow Bash?")
    }

    // MARK: - The user acting clears the alert

    func testPromptSubmittedClearsPendingAlert() {
        let existing = waiting(reason: .permission, since: 500, notified: true, escalated: true)
        let outcome = apply(.promptSubmitted, existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .working)
        XCTAssertNil(record.reason)
        XCTAssertFalse(record.notified)
        XCTAssertFalse(record.escalated)
    }

    // MARK: - `since` preservation and notification re-arming

    func testRepeatedTurnCompletePreservesOriginalWaitStart() {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true)
        let outcome = apply(.turnComplete(lastMessage: nil), existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 500, "elapsed time must measure the real wait")
        XCTAssertTrue(record.notified, "same urgency should not re-notify")
    }

    func testIdlePromptAfterTurnCompleteDoesNotReArmTheAlert() {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true, escalated: true)
        let outcome = apply(.idlePrompt, existing: existing, now: 560)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .idlePrompt)
        XCTAssertEqual(record.since, 500)
        XCTAssertTrue(record.notified)
        XCTAssertTrue(record.escalated)
    }

    func testPermissionAfterTurnCompleteReArmsTheAlert() {
        let existing = waiting(reason: .turnComplete, since: 500, notified: true, escalated: true)
        let outcome = apply(.needsPermission(message: nil), existing: existing, now: 560)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.reason, .permission)
        XCTAssertFalse(record.notified, "climbing to urgent should ping again")
        XCTAssertFalse(record.escalated)
        XCTAssertEqual(record.since, 500)
        XCTAssertEqual(record.reasonSince, 560, "new information restarts the seen clock")
    }

    func testRepeatedIdlePromptDoesNotReArm() {
        let existing = waiting(reason: .idlePrompt, since: 500, notified: true)
        let outcome = apply(.idlePrompt, existing: existing, now: 600)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertTrue(record.notified)
    }

    func testTurnCompleteAfterWorkingStartsFreshWait() {
        let outcome = apply(.turnComplete(lastMessage: nil), existing: working(since: 500), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 1000)
    }

    // MARK: - Tool activity

    func testToolStartingMarksAWaitingSessionWorking() {
        let existing = waiting(reason: .permission, since: 500, notified: true, escalated: true)
        let outcome = apply(.toolStarting, existing: existing, now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.state, .working)
        XCTAssertNil(record.reason)
        XCTAssertEqual(record.since, 1000, "the approval starts a fresh work period")
        XCTAssertFalse(record.notified)
    }

    func testToolStartingWhileAlreadyWorkingPreservesTheWorkStart() {
        let outcome = apply(.toolStarting, existing: working(since: 500), now: 1000)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.since, 500, "every tool call fires this; the clock must not restart per tool")
    }

    func testWaitPreservesEarlierMessageWhenEventOmitsIt() {
        var existing = waiting(reason: .turnComplete, since: 500, notified: true)
        existing.lastAssistantMessage = "earlier answer"
        let outcome = apply(.idlePrompt, existing: existing, now: 600)
        guard case .updated(let record) = outcome else { return XCTFail("expected update") }
        XCTAssertEqual(record.lastAssistantMessage, "earlier answer")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter HookProcessorTests 2>&1 | tail -5`
Expected: compile errors (`agentAncestors`, `apply(agent:hook:…)`).

- [ ] **Step 3: Rewrite `HookProcessor`**

Replace the whole of `Sources/TNavCore/HookProcessor.swift` with:

```swift
import Foundation

public enum HookOutcome: Equatable, Sendable {
    case updated(SessionRecord)
    case removed(agent: AgentKind, sessionId: String)
    case ignoredNested
    case ignoredUnknownEvent(String)
}

/// Pure state transitions, kept free of disk and AppleScript so the interesting behaviour
/// (what preserves `since`, what re-arms a notification) is unit-testable. Knows nothing about
/// any particular agent: the adapters have already translated the payload into `AgentEvent`.
public enum HookProcessor {
    public static func apply(agent: AgentKind,
                             hook: DecodedHook,
                             identity: SessionIdentity,
                             existing: SessionRecord?,
                             now: Double) -> HookOutcome {
        guard !identity.isNested else { return .ignoredNested }
        guard let event = hook.event else { return .ignoredUnknownEvent(hook.rawEventName) }

        // A payload that states the model wins; otherwise keep whatever an earlier event said.
        let model = hook.model ?? existing?.model

        switch event {
        case .sessionEnd:
            return .removed(agent: agent, sessionId: hook.sessionId)

        case .sessionStart, .promptSubmitted:
            // The user just acted, so any pending alert is answered by definition.
            return .updated(SessionRecord(sessionId: hook.sessionId,
                                          agent: agent,
                                          model: model,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: hook.cwd,
                                          state: .working,
                                          reason: nil,
                                          since: now,
                                          notified: false,
                                          escalated: false,
                                          lastAssistantMessage: nil))

        case .toolStarting:
            // The only signal that exists for "the user answered the permission prompt":
            // approving one fires no hook of its own, but the approved tool starts executing
            // immediately, and that is observable. It also fires on every tool call mid-turn,
            // so an already-working session keeps its original work start — the clock must
            // not restart per tool.
            let since = existing?.state == .working ? (existing?.since ?? now) : now
            return .updated(SessionRecord(sessionId: hook.sessionId,
                                          agent: agent,
                                          model: model,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: hook.cwd,
                                          state: .working,
                                          reason: nil,
                                          since: since,
                                          notified: false,
                                          escalated: false,
                                          lastAssistantMessage: nil))

        case .turnComplete, .idlePrompt, .needsPermission:
            let reason: WaitReason
            let message: String?
            switch event {
            case .turnComplete(let last): reason = .turnComplete; message = last
            case .idlePrompt: reason = .idlePrompt; message = nil
            case .needsPermission(let text): reason = .permission; message = text
            default: fatalError("unreachable")
            }

            let wasWaiting = existing?.state == .waiting

            // Keep the original wait start so elapsed time and escalation measure the real
            // wait, not the most recent event.
            let since = wasWaiting ? (existing?.since ?? now) : now

            // A changed reason is new information the user cannot have seen, so it restarts
            // the "have you looked at it" clock even though the wait clock keeps running. A
            // repeat of the same reason does not: the user having decided to leave a request
            // sitting is not grounds for the badge to keep re-flagging it at them.
            let reasonChanged = !wasWaiting || existing?.reason != reason
            let reasonSince = reasonChanged ? now : (existing?.reasonSince ?? since)

            // Re-arm notification when urgency climbs: a soft "finished" ping followed by a
            // permission request should sound again, at the higher tier.
            let urgencyClimbed = wasWaiting
                && existing?.urgency == .normal
                && reason.urgency == .urgent
            let notified = wasWaiting && !urgencyClimbed ? (existing?.notified ?? false) : false
            let escalated = wasWaiting && !urgencyClimbed ? (existing?.escalated ?? false) : false

            return .updated(SessionRecord(sessionId: hook.sessionId,
                                          agent: agent,
                                          model: model,
                                          tty: identity.tty,
                                          pid: identity.sessionPid,
                                          cwd: hook.cwd,
                                          state: .waiting,
                                          reason: reason,
                                          since: since,
                                          reasonSince: reasonSince,
                                          notified: notified,
                                          escalated: escalated,
                                          lastAssistantMessage: message ?? existing?.lastAssistantMessage))
        }
    }
}
```

- [ ] **Step 4: Rename the identity fields**

In `Sources/TNavCore/TTYResolver.swift`, replace the `SessionIdentity` struct with:

```swift
/// Which terminal tab an agent session belongs to, plus enough context to tell a real
/// top-level session apart from a nested one.
public struct SessionIdentity: Equatable, Sendable {
    /// Controlling terminal of the owning session, e.g. "/dev/ttys003". This is the join
    /// key against Terminal.app's `tty of tab`.
    public let tty: String
    /// Process to watch for liveness — the nearest known agent ancestor when there is one.
    public let sessionPid: Int32
    /// Number of known-agent processes in the ancestry, of any kind.
    public let agentAncestors: Int
    /// The kind of the nearest agent ancestor, when one was recognised.
    public let nearestAgent: AgentKind?

    /// More than one agent ancestor means this event came from a nested session — Claude
    /// Code spawning `claude -p`, or Codex launched from Claude's Bash tool. Such a session
    /// resolves to its *parent's* TTY, so acting on it would mark the parent's tab "waiting"
    /// while the parent is actually busy. See docs/phase0-recon-findings.md.
    public var isNested: Bool { agentAncestors > 1 }

    public init(tty: String, sessionPid: Int32, agentAncestors: Int, nearestAgent: AgentKind?) {
        self.tty = tty
        self.sessionPid = sessionPid
        self.agentAncestors = agentAncestors
        self.nearestAgent = nearestAgent
    }
}
```

In the resolver body of the same file, rename `claudeCount` → `agentCount`, `nearestClaudePid` → `nearestAgentPid`, add `var nearestKind: AgentKind? = nil`, and in the match branch set `if nearestAgentPid == 0 { nearestAgentPid = row.pid; nearestKind = .claude }` (Task 4 replaces `.claude` with the matched kind). Return `SessionIdentity(tty: tty, sessionPid: sessionPid, agentAncestors: agentCount, nearestAgent: nearestKind)`.

- [ ] **Step 5: Keep `HookCommand` and `ResolveCommand` building**

In `Sources/tnav/HookCommand.swift` replace the body of `process()` from `let payload: HookPayload` through the `switch outcome` with:

```swift
        let adapter = ClaudeAdapter()
        let hook: DecodedHook
        do {
            hook = try adapter.decode(data, eventHint: nil)
        } catch {
            EventLog.append("hook: undecodable payload: \(error)")
            return
        }

        guard let identity = TTYResolver().resolve(from: getpid()) else {
            EventLog.append("hook: no tty for session \(hook.sessionId) (\(hook.rawEventName))")
            return
        }

        let store = SessionStore()
        let existing = store.load(agent: .claude, sessionId: hook.sessionId)
        let outcome = HookProcessor.apply(agent: .claude,
                                         hook: hook,
                                         identity: identity,
                                         existing: existing,
                                         now: Date().timeIntervalSince1970)

        switch outcome {
        case .updated(let record):
            try store.save(record)
        case .removed(let agent, let sessionId):
            store.remove(agent: agent, sessionId: sessionId)
        case .ignoredNested:
            break
        case .ignoredUnknownEvent(let name):
            EventLog.append("hook: unhandled event \(name)")
        }
```

Delete the `logUnknownNotificationType` function.

In `Sources/tnav/ResolveCommand.swift` change `claudeAncestors  \(identity.claudeAncestors)` to `agentAncestors   \(identity.agentAncestors)` and add a line `nearestAgent     \(identity.nearestAgent?.rawValue ?? "-")`.

In `Tests/TNavCoreTests/TTYResolverTests.swift` replace every `claudeAncestors` with `agentAncestors` (`sed -i '' 's/claudeAncestors/agentAncestors/g' Tests/TNavCoreTests/TTYResolverTests.swift`).

- [ ] **Step 6: Run the whole suite**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -5`
Expected: all pass. `grep -rn "HookPayload\|HookEventKind" Sources Tests` prints nothing.

- [ ] **Step 7: Commit**

```bash
git add -A Sources Tests
git commit -m "HookProcessor consumes normalized AgentEvents

HookPayload and HookEventKind are gone; the Claude adapter owns that
knowledge. Records now carry agent and model through every transition.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `AgentMatcher`, `argv1`, cross-agent nesting

**Files:**
- Modify: `Sources/TNavCore/ProcessTable.swift`
- Modify: `Sources/TNavCore/TTYResolver.swift`
- Modify: `Sources/tnav/ResolveCommand.swift`
  (`AgentSignature` and the `AgentKind.signature` extension live in `ProcessTable.swift`, next to the matcher that reads them)
- Test: `Tests/TNavCoreTests/TTYResolverTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ProcessRow { …; public let argv1: String }   // init gains `argv1: String = ""`
  public struct AgentSignature: Sendable { public let binaryName: String; public let scriptPathFragments: [String] }
  extension AgentKind { public var signature: AgentSignature? }
  public struct AgentMatcher: Sendable {
      public init(referenceExecutablePaths: [AgentKind: String])
      public init(environment: [String: String] = ProcessInfo.processInfo.environment)
      public func match(_ row: ProcessRow) -> AgentKind?
  }
  TTYResolver.init(table:matcher:maxDepth:) takes an AgentMatcher
  ```
- `ClaudeMatcher` is deleted.

- [ ] **Step 1: Write the failing matcher tests**

In `Tests/TNavCoreTests/TTYResolverTests.swift`, replace the four tests `testIdentifiesClaudeByExecutablePathWhenArgv0IsUnhelpful`, `testMatcherDoesNotFalsePositiveOnUnrelatedProcesses`, `testLiveProcessTableIdentifiesTheRealClaudeProcess` and the `// MARK: - Identifying claude when p_comm lies` section's matcher references with the following, and add the new tests:

```swift
    func testIdentifiesClaudeByExecutablePathWhenArgv0IsUnhelpful() {
        let execPath = "/Users/you/.local/share/claude/versions/2.1.220"
        let chain = StubProcessTable([
            ProcessRow(pid: 900, ppid: 800, tty: "", command: "sh", argv0: "sh"),
            ProcessRow(pid: 800, ppid: 1, tty: "/dev/ttys003", command: "2.1.220",
                       argv0: "node", executablePath: execPath),
        ])
        let matcher = AgentMatcher(referenceExecutablePaths: [.claude: execPath])
        let identity = TTYResolver(table: chain, matcher: matcher).resolve(from: 900)
        XCTAssertEqual(identity?.agentAncestors, 1)
        XCTAssertEqual(identity?.sessionPid, 800)
        XCTAssertEqual(identity?.nearestAgent, .claude)
    }

    func testMatcherDoesNotFalsePositiveOnUnrelatedProcesses() {
        let matcher = AgentMatcher(referenceExecutablePaths: [.claude: "/opt/claude/versions/9"])
        let unrelated = ProcessRow(pid: 1, ppid: 0, tty: "", command: "zsh",
                                   argv0: "-zsh", executablePath: "/bin/zsh")
        XCTAssertNil(matcher.match(unrelated))
        let claudeLike = ProcessRow(pid: 2, ppid: 1, tty: "", command: "node",
                                    argv0: "/usr/local/bin/claude", executablePath: "/usr/local/bin/node")
        XCTAssertEqual(matcher.match(claudeLike), .claude, "argv0 basename should match through a full path")
    }

    // MARK: - Other agents

    /// The real chain from the Codex probe (2026-10-10): codex → bash → tnav.
    func testIdentifiesCodexByArgv0() {
        let chain = StubProcessTable([
            ProcessRow(pid: 20412, ppid: 20407, tty: "", command: "tnav", argv0: "tnav"),
            ProcessRow(pid: 20407, ppid: 20108, tty: "", command: "bash", argv0: "bash"),
            ProcessRow(pid: 20108, ppid: 19663, tty: "/dev/ttys005", command: "codex", argv0: "codex",
                       executablePath: "/Users/you/.codex/packages/standalone/current/bin/codex"),
            ProcessRow(pid: 19663, ppid: 19661, tty: "/dev/ttys005", command: "zsh", argv0: "-zsh"),
        ])
        let identity = TTYResolver(table: chain).resolve(from: 20412)
        XCTAssertEqual(identity?.tty, "/dev/ttys005")
        XCTAssertEqual(identity?.sessionPid, 20108)
        XCTAssertEqual(identity?.nearestAgent, .codex)
        XCTAssertEqual(identity?.isNested, false)
    }

    func testIdentifiesNodeBasedGeminiByScriptPath() {
        // `gemini` is a Node program: argv0 is node, the script is .../@google/gemini-cli/dist/index.js.
        // The basename is index.js, which says nothing — the package directory is the signal.
        let row = ProcessRow(pid: 5, ppid: 4, tty: "/dev/ttys001", command: "node", argv0: "node",
                             argv1: "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js",
                             executablePath: "/opt/homebrew/bin/node")
        XCTAssertEqual(AgentMatcher(referenceExecutablePaths: [:]).match(row), .gemini)
    }

    func testIdentifiesNodeBasedCopilotByScriptPath() {
        let row = ProcessRow(pid: 5, ppid: 4, tty: "/dev/ttys001", command: "node", argv0: "/usr/local/bin/node",
                             argv1: "/usr/local/lib/node_modules/@github/copilot/index.js",
                             executablePath: "/usr/local/bin/node")
        XCTAssertEqual(AgentMatcher(referenceExecutablePaths: [:]).match(row), .copilot)
    }

    func testWrapperBinaryNamedAfterTheAgentMatches() {
        // Homebrew-style shim: argv0 is "gemini" even though node runs underneath.
        let row = ProcessRow(pid: 5, ppid: 4, tty: "/dev/ttys001", command: "node", argv0: "gemini",
                             argv1: "--model", executablePath: "/opt/homebrew/bin/node")
        XCTAssertEqual(AgentMatcher(referenceExecutablePaths: [:]).match(row), .gemini)
    }

    func testUnrelatedNodeScriptIsNotAnAgent() {
        // Every Node dev server would otherwise count as an agent ancestor.
        let row = ProcessRow(pid: 5, ppid: 4, tty: "/dev/ttys001", command: "node", argv0: "node",
                             argv1: "/Users/you/app/server.js", executablePath: "/usr/local/bin/node")
        XCTAssertNil(AgentMatcher(referenceExecutablePaths: [:]).match(row))
    }

    func testCodexUnderClaudeIsNested() {
        // Claude's Bash tool runs `codex exec …`; Codex's hook then fires. Two agent ancestors
        // of different kinds — still nested, still the parent's tab.
        let chain = StubProcessTable([
            ProcessRow(pid: 60, ppid: 50, tty: "", command: "tnav", argv0: "tnav"),
            ProcessRow(pid: 50, ppid: 40, tty: "", command: "bash", argv0: "bash"),
            ProcessRow(pid: 40, ppid: 30, tty: "", command: "codex", argv0: "codex"),
            ProcessRow(pid: 30, ppid: 20, tty: "", command: "zsh", argv0: "zsh"),
            ProcessRow(pid: 20, ppid: 10, tty: "/dev/ttys003", command: "2.1.220", argv0: "claude"),
            ProcessRow(pid: 10, ppid: 1, tty: "/dev/ttys003", command: "zsh", argv0: "-zsh"),
        ])
        let identity = TTYResolver(table: chain).resolve(from: 60)
        XCTAssertEqual(identity?.agentAncestors, 2)
        XCTAssertEqual(identity?.isNested, true)
        XCTAssertEqual(identity?.nearestAgent, .codex, "nearest is the one that fired the hook")
    }

    func testLiveProcessTableIdentifiesTheRealClaudeProcess() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let claudePid = environment["CLAUDE_PID"].flatMap(Int32.init) else {
            throw XCTSkip("not running under Claude Code")
        }
        let row = try XCTUnwrap(SysctlProcessTable().row(for: claudePid))
        XCTAssertEqual(row.argv0Basename, "claude")
        XCTAssertEqual(AgentMatcher(environment: environment).match(row), .claude,
                       "p_comm was '\(row.command)'; matcher must still identify it")
        XCTAssertFalse(row.tty.isEmpty, "the session process owns the tab's tty")
    }

    func testLiveProcessTableReadsArgv1() {
        // This test binary is launched as `xctest <bundle path>`; the second argument is a path.
        let row = SysctlProcessTable().row(for: getpid())
        XCTAssertNotNil(row)
        // argv1 may legitimately be empty for some runners; what matters is that reading it
        // neither crashes nor returns garbage past the NUL.
        XCTAssertFalse(row?.argv1.contains("\0") ?? true)
    }
```

Also change the existing `testLiveResolutionAgreesWithClaudePidAndIsNotNested` assertion to `XCTAssertEqual(identity.nearestAgent, .claude)` after the `agentAncestors` check.

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter TTYResolverTests 2>&1 | tail -5`
Expected: compile errors (`AgentMatcher`, `argv1`).

- [ ] **Step 3: Add `argv1` to `ProcessRow` and the sysctl reader**

In `Sources/TNavCore/ProcessTable.swift`:

Add to `ProcessRow` after `argv0`:

```swift
    /// `argv[1]`. For a Node-based agent this is the script path, which is the only thing
    /// that identifies it: argv0 is just "node".
    public let argv1: String
```

Change the `init` signature to `argv0: String = "", argv1: String = "", executablePath: String = ""` and assign `self.argv1 = argv1`.

In `SysctlProcessTable.row(for:)`, replace `argv0: Self.argv0(for: pid),` with:

```swift
        let arguments = Self.arguments(for: pid, count: 2)
        return ProcessRow(pid: info.kp_proc.p_pid,
                          ppid: info.kp_eproc.e_ppid,
                          tty: tty,
                          command: command,
                          argv0: arguments.count > 0 ? arguments[0] : "",
                          argv1: arguments.count > 1 ? arguments[1] : "",
                          executablePath: Self.executablePath(for: pid))
```

(and delete the old `return ProcessRow(...)`.) Replace `static func argv0(for pid: Int32) -> String` with:

```swift
    /// The first `count` entries of argv from `KERN_PROCARGS2`. The buffer holds
    /// `[argc: Int32][exec path\0][\0 padding][argv0\0][argv1\0]...`; a 4KB buffer covers
    /// argv0 plus a script path and avoids allocating `KERN_ARGMAX` (1MB) per ancestry level.
    static func arguments(for pid: Int32, count wanted: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: 4096)
        var size = buffer.count

        let rc = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(mibBuffer.baseAddress, UInt32(mibBuffer.count), &buffer, &size, nil, 0)
        }
        guard rc == 0, size > 4 else { return [] }

        let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // alignment padding

        var result: [String] = []
        while result.count < min(wanted, max(argc, 0)), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
```

- [ ] **Step 4: Replace `ClaudeMatcher` with `AgentMatcher`**

Delete the `ClaudeMatcher` struct from `ProcessTable.swift` and add in its place:

```swift
/// How to recognise an agent in the process table.
public struct AgentSignature: Sendable {
    /// What argv0 (or `p_comm`) reads when the agent is a native binary or a shim.
    public let binaryName: String
    /// For Node-based agents: substrings of the script path (argv1) that identify the package.
    /// Checked only when argv0 is a JavaScript runtime, so an unrelated `node server.js`
    /// never matches.
    public let scriptPathFragments: [String]

    public init(binaryName: String, scriptPathFragments: [String] = []) {
        self.binaryName = binaryName
        self.scriptPathFragments = scriptPathFragments
    }
}

public extension AgentKind {
    var signature: AgentSignature? {
        switch self {
        case .claude: return AgentSignature(binaryName: "claude")
        case .codex: return AgentSignature(binaryName: "codex")
        case .gemini: return AgentSignature(binaryName: "gemini",
                                            scriptPathFragments: ["/gemini-cli/"])
        case .copilot: return AgentSignature(binaryName: "copilot",
                                             scriptPathFragments: ["/@github/copilot/"])
        default: return nil
        }
    }
}

/// Decides whether a process is one of the known agents, and which.
///
/// Checks several signals because `p_comm` alone is wrong on a standard Claude install (the
/// binary is named after its version) and `argv0` alone is wrong for Node-based agents (it is
/// "node"). Ordered cheapest-and-most-portable first.
public struct AgentMatcher: Sendable {
    /// Exact executable paths from the environment, e.g. `CLAUDE_CODE_EXECPATH`.
    public let referenceExecutablePaths: [AgentKind: String]

    private static let javaScriptRuntimes: Set<String> = ["node", "bun", "deno"]

    public init(referenceExecutablePaths: [AgentKind: String]) {
        self.referenceExecutablePaths = referenceExecutablePaths
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var paths: [AgentKind: String] = [:]
        if let path = environment["CLAUDE_CODE_EXECPATH"], !path.isEmpty { paths[.claude] = path }
        referenceExecutablePaths = paths
    }

    public func match(_ row: ProcessRow) -> AgentKind? {
        for kind in AgentKind.known where matches(row, kind) { return kind }
        return nil
    }

    func matches(_ row: ProcessRow, _ kind: AgentKind) -> Bool {
        guard let signature = kind.signature else { return false }
        if row.argv0Basename == signature.binaryName { return true }
        if row.command == signature.binaryName { return true }
        if let reference = referenceExecutablePaths[kind], row.executablePath == reference { return true }
        if !signature.scriptPathFragments.isEmpty,
           Self.javaScriptRuntimes.contains(row.argv0Basename),
           signature.scriptPathFragments.contains(where: { row.argv1.contains($0) }) {
            return true
        }
        return false
    }
}
```

- [ ] **Step 5: Wire the resolver to the matcher**

In `Sources/TNavCore/TTYResolver.swift`, the resolver becomes:

```swift
public struct TTYResolver: Sendable {
    private let table: ProcessTable
    private let matcher: AgentMatcher
    private let maxDepth: Int

    public init(table: ProcessTable = SysctlProcessTable(),
                matcher: AgentMatcher = AgentMatcher(),
                maxDepth: Int = 24) {
        self.table = table
        self.matcher = matcher
        self.maxDepth = maxDepth
    }

    /// Walks the ancestry from `startPid` toward the process-tree root, recording the first
    /// controlling TTY found and counting known-agent ancestors on the way.
    ///
    /// The walk continues past the first TTY rather than stopping there — counting *all*
    /// agent ancestors is what makes nested-session detection possible.
    public func resolve(from startPid: Int32) -> SessionIdentity? {
        var pid = startPid
        var depth = 0
        var visited = Set<Int32>()

        var tty = ""
        var firstTTYPid: Int32 = 0
        var nearestAgentPid: Int32 = 0
        var nearestKind: AgentKind?
        var agentCount = 0

        while pid > 1, depth < maxDepth, !visited.contains(pid) {
            visited.insert(pid)
            guard let row = table.row(for: pid) else { break }

            if let kind = matcher.match(row) {
                agentCount += 1
                if nearestAgentPid == 0 {
                    nearestAgentPid = row.pid
                    nearestKind = kind
                }
            }
            if tty.isEmpty, !row.tty.isEmpty {
                tty = row.tty
                firstTTYPid = row.pid
            }

            pid = row.ppid
            depth += 1
        }

        guard !tty.isEmpty else { return nil }

        // Prefer the agent process for liveness checks; fall back to whichever process owns
        // the TTY if the agent wasn't recognisable (e.g. launched via a wrapper).
        let sessionPid = nearestAgentPid != 0 ? nearestAgentPid : firstTTYPid
        return SessionIdentity(tty: tty, sessionPid: sessionPid,
                               agentAncestors: agentCount, nearestAgent: nearestKind)
    }
}
```

- [ ] **Step 6: Update `ResolveCommand`**

In `Sources/tnav/ResolveCommand.swift`: `let matcher = AgentMatcher()`; header column `claude?` → `agent`; the per-row suffix `(matcher.matches(row) ? "yes" : "")` → `(matcher.match(row)?.rawValue ?? "")`; add `argv1` column: after `pad(row.argv0Basename, 10)` insert `pad(String(row.argv1.suffix(28)), 30)` and widen the header accordingly (`pad("argv1", 30)`).

- [ ] **Step 7: Run the whole suite**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -5`
Expected: all pass. Then sanity-check live: `.build/debug/tnav resolve` from this Claude session should print `nearestAgent claude`, `agentAncestors 1` (run `swift build` first).

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests
git commit -m "AgentMatcher recognises every known agent, Node ones by script path

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `tnav hook --agent <kind> [--event <name>]`

**Files:**
- Modify: `Sources/tnav/HookCommand.swift`
- Modify: `Sources/tnav/main.swift`
- Modify: `scripts/integration-test.sh`

**Interfaces:**
- Consumes: `AgentRegistry.adapter(for:)`, `AgentAdapter.decode(_:eventHint:)`, `HookProcessor.apply(agent:hook:identity:existing:now:)`, `SessionStore.load(agent:sessionId:)`.
- Produces: `HookCommand.run(_ arguments: [String]) -> Int32`; `static func parse(_ arguments: [String]) -> (agent: AgentKind, event: String?)` (internal, used by the CLI only).

- [ ] **Step 1: Rewrite `HookCommand`**

Replace the whole of `Sources/tnav/HookCommand.swift` with:

```swift
import Darwin
import Foundation
import TNavCore

/// Runs on every hook event, for every agent.
///
/// Two hard rules:
///  1. Always exit 0 and print nothing. A nonzero exit or stray stdout from a hook can block
///     or disturb the session — Codex and Copilot read a permission hook's stdout as a
///     decision — so a bug here must never break the user's agent.
///  2. Stay fast. Everything here is syscalls and one small file write — no subprocesses.
///
/// The agent is named on the command line at registration time (`--agent codex`), never
/// guessed from the payload: Codex's payload is deliberately Claude-shaped. `--event` exists
/// for Copilot, whose payload does not name the event that fired.
enum HookCommand {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            try process(arguments)
        } catch {
            EventLog.append("hook error: \(error)")
        }
        return 0
    }

    /// `--agent X` defaults to claude so hooks registered by the 1.0.x build keep working
    /// until the user reinstalls.
    static func parse(_ arguments: [String]) -> (agent: AgentKind, event: String?) {
        var agent = AgentKind.claude
        var event: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--agent" where index + 1 < arguments.count:
                agent = AgentKind(rawValue: arguments[index + 1]); index += 2
            case "--event" where index + 1 < arguments.count:
                event = arguments[index + 1]; index += 2
            default:
                index += 1
            }
        }
        return (agent, event)
    }

    private static func process(_ arguments: [String]) throws {
        let (agent, eventHint) = parse(arguments)
        guard let adapter = AgentRegistry.adapter(for: agent) else {
            EventLog.append("hook: no adapter for agent '\(agent.rawValue)'")
            return
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            EventLog.append("hook(\(agent.rawValue)): empty stdin")
            return
        }

        let hook: DecodedHook
        do {
            hook = try adapter.decode(data, eventHint: eventHint)
        } catch {
            EventLog.append("hook(\(agent.rawValue)): undecodable payload: \(error)")
            return
        }

        guard let identity = TTYResolver().resolve(from: getpid()) else {
            // Expected when the agent runs somewhere without a controlling terminal (CI, an
            // editor pane, a detached agent). Nothing to navigate to.
            EventLog.append("hook(\(agent.rawValue)): no tty for session \(hook.sessionId) (\(hook.rawEventName))")
            return
        }

        if let nearest = identity.nearestAgent, nearest != agent {
            // The process tree says one agent, the registration says another. Happens when
            // agent A's hook config is inherited by a subprocess that is really agent B; the
            // ancestry is the more trustworthy of the two, so log it and treat as nested.
            EventLog.append("hook(\(agent.rawValue)): nearest agent in ancestry is \(nearest.rawValue); ignoring")
            return
        }

        let store = SessionStore()
        let existing = store.load(agent: agent, sessionId: hook.sessionId)
        let outcome = HookProcessor.apply(agent: agent,
                                         hook: hook,
                                         identity: identity,
                                         existing: existing,
                                         now: Date().timeIntervalSince1970)

        switch outcome {
        case .updated(let record):
            try store.save(record)
        case .removed(let agent, let sessionId):
            store.remove(agent: agent, sessionId: sessionId)
        case .ignoredNested:
            // Nested agents resolve to their parent's tab; acting on them would raise a
            // phantom alert for a tab that is actually busy.
            break
        case .ignoredUnknownEvent(let name):
            EventLog.append("hook(\(agent.rawValue)): unhandled event \(name)")
        }

        Signals.postStateChanged()
    }
}
```

- [ ] **Step 2: Update `main.swift`**

In `Sources/tnav/main.swift`: usage header line becomes `tnav — route "an agent is waiting for you" to the right Terminal tab`; the hook line becomes:

```
  tnav hook --agent <kind> [--event <name>]
                            Consume a hook payload on stdin for claude, codex, gemini or
                            copilot (always exits 0; --agent defaults to claude)
```

and the dispatch becomes `case "hook": exit(HookCommand.run(rest))`.

- [ ] **Step 3: Parametrise the integration test and add the unknown-agent check**

In `scripts/integration-test.sh`, replace the `emit` function with:

```bash
AGENT="${AGENT:-claude}"
EXTRA_ARGS=()   # e.g. (--event agentStop) for copilot

emit() {  # emit <event-json-object-without-braces>
  # Caller supplies the full field list, because each agent spells them differently.
  local body="$1"
  local out
  # ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": macOS ships bash 3.2, where an empty
  # array under `set -u` is an unbound-variable error.
  out=$(printf '{%s}' "$body" | "$TNAV" hook --agent "$AGENT" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
  local code=$?
  if [ $code -ne 0 ]; then
    echo "  FAIL: hook exited $code (hooks must always exit 0)"
    failures=$((failures + 1))
  fi
  if [ -n "$out" ]; then
    echo "  FAIL: hook printed to stdout: $out (a permission hook's stdout is read as a decision)"
    failures=$((failures + 1))
  fi
}

# Claude-shaped convenience: emit_claude <event> [extra json]
emit_claude() {
  local event="$1" extra="${2:-}"
  emit "\"session_id\":\"$SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"$event\"$extra"
}
```

Change `STATE` to `STATE="$TNAV_STATE_DIR/sessions/claude-$SESSION.json"`. Replace every existing `emit X ...` call in the Claude section with `emit_claude X ...`. After the "Malformed payload" block, add:

```bash
echo
echo "Unknown agent → exits 0, prints nothing, writes nothing"
out=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop"}' "$SESSION" "$CWD" | "$TNAV" hook --agent mystery)
if [ $? -ne 0 ] || [ -n "$out" ]; then
  echo "  FAIL unknown agent must exit 0 silently"
  failures=$((failures + 1))
elif ls "$TNAV_STATE_DIR/sessions"/*mystery* >/dev/null 2>&1; then
  echo "  FAIL unknown agent must not write a record"
  failures=$((failures + 1))
else
  echo "  ok   unknown agent is a silent no-op"
fi

echo
echo "Legacy registration (no --agent) → still Claude"
printf '{"session_id":"legacy-%s","cwd":"%s","hook_event_name":"SessionStart"}' "$$" "$CWD" | "$TNAV" hook
if [ -f "$TNAV_STATE_DIR/sessions/claude-legacy-$$.json" ]; then
  echo "  ok   defaults to claude"
else
  echo "  FAIL no --agent should mean claude"
  failures=$((failures + 1))
fi
```

- [ ] **Step 4: Run build, unit tests, integration test**

```bash
swift build 2>&1 | tail -2
TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -3
./scripts/integration-test.sh
```

Expected: build ok, tests pass, `integration: all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/tnav scripts/integration-test.sh
git commit -m "tnav hook takes --agent and --event

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Codex adapter

**Files:**
- Create: `Sources/TNavCore/Agents/CodexAdapter.swift`
- Modify: `Sources/TNavCore/Agents/AgentEvent.swift` (`AgentRegistry`)
- Test: `Tests/TNavCoreTests/Agents/CodexAdapterTests.swift`
- Modify: `scripts/integration-test.sh`

**Interfaces:**
- Produces: `public struct CodexAdapter: AgentAdapter`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TNavCoreTests/Agents/CodexAdapterTests.swift`:

```swift
import XCTest
@testable import TNavCore

final class CodexAdapterTests: XCTestCase {
    private let adapter = CodexAdapter()

    private func decode(_ json: String) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: nil)
    }

    // Captured live from Codex CLI 0.155.0 on 2026-10-10 (see the probe notes in the plan).

    func testSessionStartCarriesModel() throws {
        let hook = try decode("""
        {"session_id":"01a128e2-f361-7890-89ba-fcc27bcb271a","transcript_path":"/x/rollout.jsonl",\
        "cwd":"/Users/you/code/webapp","hook_event_name":"SessionStart","model":"gpt-5",\
        "permission_mode":"bypassPermissions","source":"startup"}
        """)
        XCTAssertEqual(hook.sessionId, "01a128e2-f361-7890-89ba-fcc27bcb271a")
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertEqual(hook.model, "gpt-5")
        XCTAssertEqual(hook.event, .sessionStart)
    }

    func testUserPromptSubmit() throws {
        let hook = try decode("""
        {"session_id":"01a128e2","turn_id":"01a128e2-f380","transcript_path":"/x.jsonl",\
        "cwd":"/p","hook_event_name":"UserPromptSubmit","model":"gpt-5",\
        "permission_mode":"bypassPermissions","prompt":"say hi"}
        """)
        XCTAssertEqual(hook.event, .promptSubmitted)
    }

    // Documented shapes (learn.chatgpt.com/docs/hooks); not yet captured live.

    func testStopCarriesLastAssistantMessage() throws {
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"Stop","model":"gpt-5",\
        "stop_hook_active":false,"last_assistant_message":"Done. Want tests?"}
        """)
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: "Done. Want tests?"))
    }

    func testStopWithNullMessage() throws {
        let hook = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"Stop","last_assistant_message":null}"#)
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: nil))
    }

    func testPermissionRequestNeedsPermissionWithToolDescription() throws {
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash",\
        "tool_input":{"command":"rm -rf build","description":"Remove the build directory"}}
        """)
        XCTAssertEqual(hook.event, .needsPermission(message: "Remove the build directory"))
    }

    func testPermissionRequestWithoutDescriptionFallsBackToToolName() throws {
        let hook = try decode("""
        {"session_id":"a","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}
        """)
        XCTAssertEqual(hook.event, .needsPermission(message: "Bash"))
    }

    func testOtherLifecycleEvents() throws {
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash"}"#).event, .toolStarting)
        XCTAssertEqual(try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"SessionEnd","reason":"other"}"#).event, .sessionEnd)
    }

    func testUnmappedEventsAreNil() throws {
        for name in ["PostToolUse", "PreCompact", "PostCompact", "SubagentStop", "SubagentStart", "Interrupt"] {
            let hook = try decode(#"{"session_id":"a","cwd":"/p","hook_event_name":"\#(name)"}"#)
            XCTAssertNil(hook.event, name)
            XCTAssertEqual(hook.rawEventName, name)
        }
    }

    func testRegistryKnowsCodex() {
        XCTAssertEqual(AgentRegistry.adapter(for: .codex)?.kind, .codex)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter CodexAdapterTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'CodexAdapter'`.

- [ ] **Step 3: Create the adapter and register it**

Create `Sources/TNavCore/Agents/CodexAdapter.swift`:

```swift
import Foundation

/// OpenAI Codex CLI. Its hook payload is deliberately Claude-shaped (`session_id`, `cwd`,
/// `hook_event_name`, `Stop`, `PreToolUse`), plus `model`. The one real difference: a
/// permission prompt arrives as `PermissionRequest`, not `Notification`.
///
/// `PermissionRequest` is a hook that *can answer the prompt* through stdout. This adapter
/// only observes; the hook command prints nothing, ever.
public struct CodexAdapter: AgentAdapter {
    public let kind: AgentKind = .codex

    public init() {}

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = try HookJSON.required(object, "hook_event_name")
        let event: AgentEvent?
        switch name {
        case "SessionStart": event = .sessionStart
        case "UserPromptSubmit": event = .promptSubmitted
        case "PreToolUse": event = .toolStarting
        case "Stop": event = .turnComplete(lastMessage: HookJSON.string(object, "last_assistant_message"))
        case "PermissionRequest":
            // The description is what the user sees in Codex's own prompt; the tool name is a
            // poorer but never-empty fallback.
            event = .needsPermission(message: HookJSON.string(object, "tool_input", "description")
                                                ?? HookJSON.string(object, "tool_name"))
        case "SessionEnd": event = .sessionEnd
        default: event = nil
        }
        return DecodedHook(sessionId: try HookJSON.required(object, "session_id"),
                           cwd: try HookJSON.required(object, "cwd"),
                           model: HookJSON.string(object, "model"),
                           rawEventName: name,
                           event: event)
    }
}
```

In `AgentRegistry.adapter(for:)` add `case .codex: return CodexAdapter()`.

- [ ] **Step 4: Run the tests**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter CodexAdapterTests 2>&1 | tail -5`
Expected: 9 pass.

- [ ] **Step 5: Add a Codex section to the integration test**

Append to `scripts/integration-test.sh` before the final summary block:

```bash
echo
echo "=== codex ==="
AGENT=codex
CODEX_SESSION="01a1-codex-$$"
STATE="$TNAV_STATE_DIR/sessions/codex-$CODEX_SESSION.json"
emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"SessionStart\",\"model\":\"gpt-5\",\"source\":\"startup\""
check "codex record is working"   '.state' 'working'
check "agent recorded"            '.agent' 'codex'
check "model recorded"            '.model' 'gpt-5'

echo "PermissionRequest prints nothing on stdout and marks urgent"
emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\",\"description\":\"List files\"}"
check "needs permission"          '.reason' 'permission'
check "message is the description" '.lastAssistantMessage' 'List files'
check "model survives an event without it" '.model' 'gpt-5'

emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"Done.\""
check "stop is turn_complete"     '.reason' 'turn_complete'

emit "\"session_id\":\"$CODEX_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\""
check_absent "codex record removed"
AGENT=claude
```

Note `emit` already fails the run if anything reaches stdout, which is the Review Focus item 5 check.

- [ ] **Step 6: Run everything**

```bash
swift build 2>&1 | tail -1 && ./scripts/integration-test.sh | tail -8
```

Expected: `integration: all checks passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/TNavCore/Agents Tests/TNavCoreTests/Agents scripts/integration-test.sh
git commit -m "Codex adapter

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Gemini CLI adapter

**Files:**
- Create: `Sources/TNavCore/Agents/GeminiAdapter.swift`
- Modify: `Sources/TNavCore/Agents/AgentEvent.swift` (`AgentRegistry`)
- Test: `Tests/TNavCoreTests/Agents/GeminiAdapterTests.swift`
- Modify: `scripts/integration-test.sh`

- [ ] **Step 1: Write the failing tests**

Create `Tests/TNavCoreTests/Agents/GeminiAdapterTests.swift`:

```swift
import XCTest
@testable import TNavCore

/// Fixtures are built from the field names in the Gemini CLI hooks reference
/// (geminicli.com/docs/hooks/reference), not captured live. If a live payload disagrees,
/// fix the fixture here and the adapter together.
final class GeminiAdapterTests: XCTestCase {
    private let adapter = GeminiAdapter()

    private func decode(_ json: String) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: nil)
    }

    private let common = #""session_id":"g-1","transcript_path":"/t.json","cwd":"/Users/you/code/webapp","timestamp":"2026-10-10T12:00:00Z""#

    func testSessionStartAndEnd() throws {
        XCTAssertEqual(try decode("{\(common),\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}").event, .sessionStart)
        XCTAssertEqual(try decode("{\(common),\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}").event, .sessionEnd)
    }

    func testBeforeAgentIsThePromptBeingSubmitted() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"BeforeAgent\",\"prompt\":\"fix the tests\"}")
        XCTAssertEqual(hook.event, .promptSubmitted)
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertNil(hook.model)
    }

    func testBeforeToolIsToolStarting() throws {
        XCTAssertEqual(try decode("{\(common),\"hook_event_name\":\"BeforeTool\",\"tool_name\":\"write_file\",\"tool_input\":{}}").event, .toolStarting)
    }

    func testAfterAgentCarriesTheResponse() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"AfterAgent\",\"prompt\":\"fix\",\"prompt_response\":\"All green.\",\"stop_hook_active\":false}")
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: "All green."))
    }

    func testToolPermissionNotificationNeedsPermission() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"Notification\",\"notification_type\":\"ToolPermission\",\"message\":\"Allow write_file?\",\"details\":{\"tool\":\"write_file\"}}")
        XCTAssertEqual(hook.event, .needsPermission(message: "Allow write_file?"))
    }

    func testUnknownNotificationTypeIsStillUrgent() throws {
        let hook = try decode("{\(common),\"hook_event_name\":\"Notification\",\"notification_type\":\"SomethingNew\",\"message\":\"m\"}")
        XCTAssertEqual(hook.event, .needsPermission(message: "m"))
    }

    func testModelEventsAreUnmapped() throws {
        for name in ["BeforeModel", "AfterModel", "BeforeToolSelection", "AfterTool", "PreCompress"] {
            XCTAssertNil(try decode("{\(common),\"hook_event_name\":\"\(name)\"}").event, name)
        }
    }

    func testRegistryKnowsGemini() {
        XCTAssertEqual(AgentRegistry.adapter(for: .gemini)?.kind, .gemini)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter GeminiAdapterTests 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Create the adapter and register it**

Create `Sources/TNavCore/Agents/GeminiAdapter.swift`:

```swift
import Foundation

/// Google Gemini CLI. Field names from the hooks reference (geminicli.com/docs/hooks/reference):
/// every hook gets `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `timestamp`.
/// Not yet verified against a live payload; the adapter tests say so.
public struct GeminiAdapter: AgentAdapter {
    public let kind: AgentKind = .gemini

    public init() {}

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = try HookJSON.required(object, "hook_event_name")
        let event: AgentEvent?
        switch name {
        case "SessionStart": event = .sessionStart
        // Fires once per user turn, before the agent loop — the closest thing to "the user
        // just said something".
        case "BeforeAgent": event = .promptSubmitted
        case "BeforeTool": event = .toolStarting
        case "AfterAgent": event = .turnComplete(lastMessage: HookJSON.string(object, "prompt_response"))
        // Observability-only alert. Only `ToolPermission` is documented; anything else is
        // treated as urgent rather than dropped, as with Claude.
        case "Notification": event = .needsPermission(message: HookJSON.string(object, "message"))
        case "SessionEnd": event = .sessionEnd
        default: event = nil
        }
        return DecodedHook(sessionId: try HookJSON.required(object, "session_id"),
                           cwd: try HookJSON.required(object, "cwd"),
                           model: nil,
                           rawEventName: name,
                           event: event)
    }
}
```

In `AgentRegistry.adapter(for:)` add `case .gemini: return GeminiAdapter()`.

- [ ] **Step 4: Run the tests**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter GeminiAdapterTests 2>&1 | tail -5`
Expected: 8 pass.

- [ ] **Step 5: Add a Gemini section to the integration test**

Append before the summary block (after the Codex section):

```bash
echo
echo "=== gemini ==="
AGENT=gemini
G_SESSION="gem-$$"
STATE="$TNAV_STATE_DIR/sessions/gemini-$G_SESSION.json"
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"BeforeAgent\",\"prompt\":\"go\",\"timestamp\":\"2026-10-10T00:00:00Z\""
check "gemini record is working" '.state' 'working'
check "agent recorded"           '.agent' 'gemini'
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"AfterAgent\",\"prompt\":\"go\",\"prompt_response\":\"Done.\""
check "AfterAgent is turn_complete" '.reason' 'turn_complete'
check "response captured"        '.lastAssistantMessage' 'Done.'
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"Notification\",\"notification_type\":\"ToolPermission\",\"message\":\"Allow?\""
check "ToolPermission is urgent" '.reason' 'permission'
emit "\"session_id\":\"$G_SESSION\",\"cwd\":\"$CWD\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\""
check_absent "gemini record removed"
AGENT=claude
```

- [ ] **Step 6: Run everything and commit**

```bash
swift build 2>&1 | tail -1 && ./scripts/integration-test.sh | tail -3
git add Sources/TNavCore/Agents Tests/TNavCoreTests/Agents scripts/integration-test.sh
git commit -m "Gemini CLI adapter

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Copilot CLI adapter

**Files:**
- Create: `Sources/TNavCore/Agents/CopilotAdapter.swift`
- Modify: `Sources/TNavCore/Agents/AgentEvent.swift` (`AgentRegistry`)
- Test: `Tests/TNavCoreTests/Agents/CopilotAdapterTests.swift`
- Modify: `scripts/integration-test.sh`

- [ ] **Step 1: Write the failing tests**

Create `Tests/TNavCoreTests/Agents/CopilotAdapterTests.swift`:

```swift
import XCTest
@testable import TNavCore

/// Fixtures follow the Copilot CLI hooks reference
/// (docs.github.com/en/copilot/reference/copilot-cli-reference/cli-hooks-reference): camelCase
/// `sessionId`, `cwd`, `timestamp` in Unix ms, and — crucially — no field naming the event.
/// The event comes from the `--event` argument the hook was registered with.
final class CopilotAdapterTests: XCTestCase {
    private let adapter = CopilotAdapter()

    private func decode(_ json: String, hint: String?) throws -> DecodedHook {
        try adapter.decode(Data(json.utf8), eventHint: hint)
    }

    private let common = #""sessionId":"cp-1","timestamp":1789730418873,"cwd":"/Users/you/code/webapp""#

    func testUsesEventHintWhenPayloadHasNoEventName() throws {
        let hook = try decode("{\(common),\"transcriptPath\":\"/t\",\"stopReason\":\"end_turn\"}", hint: "agentStop")
        XCTAssertEqual(hook.sessionId, "cp-1")
        XCTAssertEqual(hook.cwd, "/Users/you/code/webapp")
        XCTAssertEqual(hook.rawEventName, "agentStop")
        XCTAssertEqual(hook.event, .turnComplete(lastMessage: nil))
    }

    func testPayloadEventNameWinsOverHintWhenPresent() throws {
        // The VS Code-format payload does carry hook_event_name; prefer the payload's word.
        let hook = try decode(#"{"session_id":"cp-2","cwd":"/p","hook_event_name":"sessionStart","timestamp":"2026-10-10T00:00:00Z"}"#, hint: "agentStop")
        XCTAssertEqual(hook.sessionId, "cp-2")
        XCTAssertEqual(hook.event, .sessionStart)
    }

    func testMissingHintYieldsNoEvent() throws {
        let hook = try decode("{\(common)}", hint: nil)
        XCTAssertNil(hook.event)
        XCTAssertEqual(hook.rawEventName, "")
    }

    func testLifecycle() throws {
        XCTAssertEqual(try decode("{\(common),\"source\":\"new\"}", hint: "sessionStart").event, .sessionStart)
        XCTAssertEqual(try decode("{\(common),\"prompt\":\"go\"}", hint: "userPromptSubmitted").event, .promptSubmitted)
        XCTAssertEqual(try decode("{\(common),\"toolName\":\"bash\",\"toolArgs\":{}}", hint: "preToolUse").event, .toolStarting)
        XCTAssertEqual(try decode("{\(common),\"reason\":\"exit\"}", hint: "sessionEnd").event, .sessionEnd)
    }

    func testPermissionRequestNeedsPermissionWithToolName() throws {
        let hook = try decode("{\(common),\"toolName\":\"bash\",\"toolArgs\":{\"command\":\"ls\"}}", hint: "permissionRequest")
        XCTAssertEqual(hook.event, .needsPermission(message: "bash"))
    }

    func testPermissionPromptNotificationNeedsPermissionWithMessage() throws {
        let hook = try decode("{\(common),\"message\":\"Copilot wants to run bash\",\"notification_type\":\"permission_prompt\"}", hint: "notification")
        XCTAssertEqual(hook.event, .needsPermission(message: "Copilot wants to run bash"))
    }

    func testOtherNotificationTypesAreIgnored() throws {
        // `agent_idle` is about a background agent, not the main session; not our business.
        let hook = try decode("{\(common),\"message\":\"idle\",\"notification_type\":\"agent_idle\"}", hint: "notification")
        XCTAssertNil(hook.event)
    }

    func testSubagentAndErrorEventsAreUnmapped() throws {
        for name in ["subagentStart", "subagentStop", "errorOccurred", "preCompact", "postToolUse", "postToolUseFailure", "userPromptTransformed"] {
            XCTAssertNil(try decode("{\(common)}", hint: name).event, name)
        }
    }

    func testRegistryKnowsCopilot() {
        XCTAssertEqual(AgentRegistry.adapter(for: .copilot)?.kind, .copilot)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter CopilotAdapterTests 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Create the adapter and register it**

Create `Sources/TNavCore/Agents/CopilotAdapter.swift`:

```swift
import Foundation

/// GitHub Copilot CLI. Its native payload is camelCase (`sessionId`, `cwd`, `timestamp` in
/// Unix ms) and does not say which event fired; the registrar therefore passes the event on
/// the command line (`--event agentStop`) and this adapter reads it from `eventHint`. The
/// alternative VS Code-format payload carries `session_id` and `hook_event_name`; both are
/// accepted, and the payload's own event name wins when present.
public struct CopilotAdapter: AgentAdapter {
    public let kind: AgentKind = .copilot

    public init() {}

    public func decode(_ data: Data, eventHint: String?) throws -> DecodedHook {
        let object = try HookJSON.object(data)
        let name = HookJSON.string(object, "hook_event_name") ?? eventHint ?? ""
        let event: AgentEvent?
        switch name {
        case "sessionStart": event = .sessionStart
        case "userPromptSubmitted": event = .promptSubmitted
        case "preToolUse": event = .toolStarting
        // Copilot's payload has no final-message field, and the transcript is off limits.
        case "agentStop": event = .turnComplete(lastMessage: nil)
        case "permissionRequest": event = .needsPermission(message: HookJSON.string(object, "toolName"))
        case "notification":
            event = HookJSON.string(object, "notification_type") == "permission_prompt"
                ? .needsPermission(message: HookJSON.string(object, "message"))
                : nil
        case "sessionEnd": event = .sessionEnd
        default: event = nil
        }
        guard let sessionId = HookJSON.string(object, "sessionId") ?? HookJSON.string(object, "session_id") else {
            throw HookDecodeError.missingField("sessionId")
        }
        return DecodedHook(sessionId: sessionId,
                           cwd: try HookJSON.required(object, "cwd"),
                           model: nil,
                           rawEventName: name,
                           event: event)
    }
}
```

In `AgentRegistry.adapter(for:)` add `case .copilot: return CopilotAdapter()`.

- [ ] **Step 4: Run the tests**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter CopilotAdapterTests 2>&1 | tail -5`
Expected: 9 pass.

- [ ] **Step 5: Add a Copilot section to the integration test**

Append after the Gemini section:

```bash
echo
echo "=== copilot ==="
AGENT=copilot
C_SESSION="cp-$$"
STATE="$TNAV_STATE_DIR/sessions/copilot-$C_SESSION.json"
EXTRA_ARGS=(--event sessionStart)
emit "\"sessionId\":\"$C_SESSION\",\"cwd\":\"$CWD\",\"timestamp\":1789730418873,\"source\":\"new\""
check "copilot record is working" '.state' 'working'
check "agent recorded"            '.agent' 'copilot'
EXTRA_ARGS=(--event agentStop)
emit "\"sessionId\":\"$C_SESSION\",\"cwd\":\"$CWD\",\"timestamp\":1789730418900,\"stopReason\":\"end_turn\""
check "agentStop is turn_complete" '.reason' 'turn_complete'
EXTRA_ARGS=(--event permissionRequest)
emit "\"sessionId\":\"$C_SESSION\",\"cwd\":\"$CWD\",\"timestamp\":1789730418950,\"toolName\":\"bash\",\"toolArgs\":{}"
check "permissionRequest is urgent" '.reason' 'permission'
EXTRA_ARGS=(--event sessionEnd)
emit "\"sessionId\":\"$C_SESSION\",\"cwd\":\"$CWD\",\"timestamp\":1789730419000,\"reason\":\"exit\""
check_absent "copilot record removed"
EXTRA_ARGS=()
AGENT=claude
```

- [ ] **Step 6: Run everything and commit**

```bash
swift build 2>&1 | tail -1 && ./scripts/integration-test.sh | tail -3
git add Sources/TNavCore/Agents Tests/TNavCoreTests/Agents scripts/integration-test.sh
git commit -m "Copilot CLI adapter; the event comes from --event

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Per-agent hook registrars (Python)

**Files:**
- Create: `scripts/hooks/__init__.py`, `scripts/hooks/common.py`, `scripts/hooks/claude.py`, `scripts/hooks/codex.py`, `scripts/hooks/gemini.py`, `scripts/hooks/copilot.py`, `scripts/hooks/test_registrars.py`
- Rewrite: `scripts/register-hooks.py`
- Modify: `Makefile`

**Interfaces:**
- Produces, in `scripts/hooks/common.py`:
  ```python
  OURS_MARKERS = ("tnav hook", "ClaudeBar.app", "TerminalNavigator.app", "AgentSentinel.app")
  def is_ours(command: str) -> bool
  def read_json(path) -> dict | None          # None when missing; raises RegistrarError when unparsable
  def write_json_atomic(path, obj)             # backup to <path>.tnav-backup first if it existed
  def strip_grouped(hooks: dict, our_marker) -> dict   # Claude/Gemini/Codex shape
  def merge_grouped(hooks: dict, events, command) -> dict
  class RegistrarError(Exception)
  ```
  Each agent module exposes `KIND`, `CONFIG_DIR` (relative to `$HOME`), `EVENTS`, `installed(home) -> bool`, `registered(home, tnav=None) -> bool`, `register(home, tnav) -> str`, `remove(home) -> str`.
- `scripts/register-hooks.py` CLI:
  ```
  register-hooks.py --tnav PATH [--agents a,b]      # default: every installed agent
  register-hooks.py --remove [--agents a,b]          # default: all four
  register-hooks.py --status                         # one line per agent: kind installed registered
  ```
  All paths honour `$HOME`, so tests run against a temp home.

- [ ] **Step 1: Write the failing registrar tests**

Create `scripts/hooks/__init__.py` (empty) and `scripts/hooks/test_registrars.py`:

```python
"""Run with:  python3 -m unittest discover -s scripts/hooks -t scripts"""
import json
import os
import tempfile
import unittest

from hooks import claude, codex, copilot, gemini, common

TNAV = "/Applications/AgentSentinel.app/Contents/MacOS/tnav"


class RegistrarCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, *parts):
        return os.path.join(self.home, *parts)

    def write(self, rel, obj):
        full = self.path(rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as handle:
            json.dump(obj, handle)
        return full

    def read(self, rel):
        with open(self.path(rel)) as handle:
            return json.load(handle)


class ClaudeTests(RegistrarCase):
    def test_not_installed_without_config_dir(self):
        self.assertFalse(claude.installed(self.home))
        os.makedirs(self.path(".claude"))
        self.assertTrue(claude.installed(self.home))

    def test_registers_six_events_with_agent_flag(self):
        os.makedirs(self.path(".claude"))
        claude.register(self.home, TNAV)
        hooks = self.read(".claude/settings.json")["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"})
        self.assertEqual(hooks["Stop"][0]["hooks"][0]["command"], f"{TNAV} hook --agent claude")
        self.assertTrue(claude.registered(self.home))

    def test_merge_keeps_other_tools_and_replaces_old_claudebar_entries(self):
        self.write(".claude/settings.json", {
            "permissions": {"allow": ["Bash"]},
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "/opt/other/notify.sh"}]},
                    {"hooks": [{"type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/tnav hook"}]},
                ],
            },
        })
        claude.register(self.home, TNAV)
        settings = self.read(".claude/settings.json")
        self.assertEqual(settings["permissions"], {"allow": ["Bash"]})
        stop_commands = [h["command"] for g in settings["hooks"]["Stop"] for h in g["hooks"]]
        self.assertIn("/opt/other/notify.sh", stop_commands)
        self.assertIn(f"{TNAV} hook --agent claude", stop_commands)
        self.assertNotIn("/Applications/ClaudeBar.app/Contents/MacOS/tnav hook", stop_commands)
        self.assertTrue(os.path.exists(self.path(".claude/settings.json.tnav-backup")))

    def test_idempotent(self):
        os.makedirs(self.path(".claude"))
        claude.register(self.home, TNAV)
        claude.register(self.home, TNAV)
        self.assertEqual(len(self.read(".claude/settings.json")["hooks"]["Stop"]), 1)

    def test_remove_strips_ours_and_drops_empty_hooks_key(self):
        os.makedirs(self.path(".claude"))
        claude.register(self.home, TNAV)
        claude.remove(self.home)
        self.assertNotIn("hooks", self.read(".claude/settings.json"))
        self.assertFalse(claude.registered(self.home))

    def test_refuses_malformed_file(self):
        full = self.path(".claude/settings.json")
        os.makedirs(os.path.dirname(full))
        with open(full, "w") as handle:
            handle.write("{not json")
        with self.assertRaises(common.RegistrarError):
            claude.register(self.home, TNAV)
        with open(full) as handle:
            self.assertEqual(handle.read(), "{not json")

    def test_legacy_registration_without_agent_flag_counts_as_registered(self):
        self.write(".claude/settings.json", {"hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "/x/tnav hook"}]}],
            "Notification": [{"hooks": [{"type": "command", "command": "/x/tnav hook"}]}],
        }})
        self.assertTrue(claude.registered(self.home))


class CodexTests(RegistrarCase):
    def test_creates_hooks_json_when_absent(self):
        os.makedirs(self.path(".codex"))
        codex.register(self.home, TNAV)
        hooks = self.read(".codex/hooks.json")["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SessionEnd"})
        entry = hooks["PermissionRequest"][0]["hooks"][0]
        self.assertEqual(entry["command"], f"{TNAV} hook --agent codex")
        self.assertEqual(entry["type"], "command")
        self.assertEqual(entry["timeout"], 10)
        self.assertTrue(codex.registered(self.home))

    def test_merges_into_existing_hooks_json(self):
        self.write(".codex/hooks.json", {"description": "mine", "hooks": {
            "PreToolUse": [{"matcher": "^Bash$", "hooks": [{"type": "command", "command": "/opt/policy.py"}]}]}})
        codex.register(self.home, TNAV)
        data = self.read(".codex/hooks.json")
        self.assertEqual(data["description"], "mine")
        self.assertEqual(data["hooks"]["PreToolUse"][0]["matcher"], "^Bash$")
        self.assertEqual(len(data["hooks"]["PreToolUse"]), 2)

    def test_remove(self):
        os.makedirs(self.path(".codex"))
        codex.register(self.home, TNAV)
        codex.remove(self.home)
        self.assertFalse(codex.registered(self.home))


class GeminiTests(RegistrarCase):
    def test_registers_into_settings_json(self):
        os.makedirs(self.path(".gemini"))
        gemini.register(self.home, TNAV)
        hooks = self.read(".gemini/settings.json")["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "BeforeAgent", "BeforeTool", "AfterAgent", "Notification", "SessionEnd"})
        self.assertEqual(hooks["AfterAgent"][0]["hooks"][0]["command"], f"{TNAV} hook --agent gemini")
        self.assertTrue(gemini.registered(self.home))

    def test_keeps_other_settings(self):
        self.write(".gemini/settings.json", {"theme": "Default", "hooks": {}})
        gemini.register(self.home, TNAV)
        self.assertEqual(self.read(".gemini/settings.json")["theme"], "Default")


class CopilotTests(RegistrarCase):
    def test_writes_own_file_with_event_flag_per_event(self):
        os.makedirs(self.path(".copilot"))
        copilot.register(self.home, TNAV)
        data = self.read(".copilot/hooks/agentsentinel.json")
        self.assertEqual(data["version"], 1)
        self.assertEqual(set(data["hooks"]), {"sessionStart", "userPromptSubmitted", "preToolUse", "permissionRequest", "notification", "agentStop", "sessionEnd"})
        self.assertEqual(data["hooks"]["agentStop"][0]["bash"], f"{TNAV} hook --agent copilot --event agentStop")
        self.assertEqual(data["hooks"]["agentStop"][0]["type"], "command")
        self.assertTrue(copilot.registered(self.home))

    def test_remove_deletes_the_file_only(self):
        os.makedirs(self.path(".copilot/hooks"))
        self.write(".copilot/hooks/other.json", {"version": 1, "hooks": {}})
        copilot.register(self.home, TNAV)
        copilot.remove(self.home)
        self.assertFalse(os.path.exists(self.path(".copilot/hooks/agentsentinel.json")))
        self.assertTrue(os.path.exists(self.path(".copilot/hooks/other.json")))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -m unittest discover -s scripts/hooks -t scripts 2>&1 | tail -3`
Expected: `ModuleNotFoundError: No module named 'hooks.claude'` (or similar import error).

- [ ] **Step 3: Write `common.py`**

Create `scripts/hooks/common.py`:

```python
"""Shared mechanics for the per-agent hook registrars.

Every config file these touch belongs to the user and may hold other tools' hooks on the
very same events. So: merge rather than write, remove only entries recognisable as ours,
back up first, write atomically, and never touch a file that does not parse.
"""
import json
import os
import shutil

OURS_MARKERS = ("tnav hook", "ClaudeBar.app", "TerminalNavigator.app", "AgentSentinel.app")


class RegistrarError(Exception):
    """A config file could not be read or is not shaped as expected; nothing was changed."""


def is_ours(command):
    text = str(command).strip()
    return any(marker in text for marker in OURS_MARKERS)


def read_json(path):
    """The parsed object, or None when the file does not exist. Raises RegistrarError rather
    than returning a default for a file that exists but cannot be parsed: replacing it would
    lose every other tool's configuration."""
    if not os.path.exists(path):
        return None
    try:
        with open(path) as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError) as error:
        raise RegistrarError(f"could not read {path}: {error}; leaving it untouched — fix it and re-run")
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
        groups = []
        for group in hooks.get(event) or []:
            if not isinstance(group, dict):
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
        hooks.setdefault(event, []).append({"hooks": [entry]})
    return hooks


def grouped_has_ours(hooks, events, marker):
    """Whether every event in `events` has a command carrying `marker`."""
    if not isinstance(hooks, dict):
        return False
    for event in events:
        found = False
        for group in hooks.get(event) or []:
            if not isinstance(group, dict):
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
        data = read_json(path) or {}
        hooks = data.get(root_key) or {}
        if not isinstance(hooks, dict):
            raise RegistrarError(f"'{root_key}' in {path} is not an object; leaving it untouched")
        merge_grouped(hooks, events, f"{os.path.abspath(tnav)} hook --agent {kind}", extra)
        data[root_key] = hooks
        write_json_atomic(path, data)
        return f"registered {len(events)} {kind} hooks in {path}"

    def remove(home):
        path = config_path(home)
        data = read_json(path)
        if not data:
            return f"no {path}; nothing to remove"
        hooks = data.get(root_key) or {}
        if isinstance(hooks, dict):
            strip_grouped(hooks)
            if hooks:
                data[root_key] = hooks
            else:
                data.pop(root_key, None)
        write_json_atomic(path, data)
        return f"removed {kind} hooks from {path}"

    return installed, registered, register, remove
```

- [ ] **Step 4: Write the four agent modules**

`scripts/hooks/claude.py`:

```python
"""Claude Code: ~/.claude/settings.json, `hooks` object, Claude-shaped groups."""
import os
from . import common

KIND = "claude"
CONFIG_DIR = ".claude"
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
REQUIRED = ["Stop", "Notification"]

installed, registered, register, remove = common.grouped_registrar(
    KIND, os.path.join(CONFIG_DIR, "settings.json"), "hooks", EVENTS, REQUIRED,
    # Hooks written by the 1.0.x builds had no --agent flag.
    legacy_markers=("tnav hook",),
)
```

`scripts/hooks/codex.py`:

```python
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
```

`scripts/hooks/gemini.py`:

```python
"""Gemini CLI: ~/.gemini/settings.json, `hooks` object, Claude-shaped groups."""
import os
from . import common

KIND = "gemini"
CONFIG_DIR = ".gemini"
EVENTS = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterAgent", "Notification", "SessionEnd"]
REQUIRED = ["AfterAgent", "Notification"]

installed, registered, register, remove = common.grouped_registrar(
    KIND, os.path.join(CONFIG_DIR, "settings.json"), "hooks", EVENTS, REQUIRED)
```

`scripts/hooks/copilot.py`:

```python
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
```

- [ ] **Step 5: Run the registrar tests**

Run: `python3 -m unittest discover -s scripts/hooks -t scripts 2>&1 | tail -3`
Expected: `OK` with 15 tests.

- [ ] **Step 6: Rewrite the CLI**

Replace `scripts/register-hooks.py` with:

```python
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
```

- [ ] **Step 7: Add the script tests to the Makefile**

In `Makefile`, add `test-scripts` to `.PHONY`, and:

```make
test-scripts:
	python3 -m unittest discover -s scripts/hooks -t scripts

check: test test-scripts
	@./scripts/integration-test.sh
```

(replace the existing `check:` line). Add `@echo "  make test-scripts  registrar tests (python)"` to `help`.

- [ ] **Step 8: Smoke the CLI against a temp home and run `make check`**

```bash
HOME=$(mktemp -d) bash -c 'mkdir -p $HOME/.codex $HOME/.claude; python3 scripts/register-hooks.py --tnav .build/debug/tnav; python3 scripts/register-hooks.py --status; python3 scripts/register-hooks.py --remove; python3 scripts/register-hooks.py --status'
make check 2>&1 | tail -5
```

Expected: first run registers claude and codex (and prints the Codex trust note); status shows both `registered`; after `--remove` both `not-registered`; `make check` passes.

- [ ] **Step 9: Commit**

```bash
git add scripts/hooks scripts/register-hooks.py Makefile
git commit -m "Per-agent hook registrars with tests

Claude, Codex and Gemini share the Claude-shaped merge; Copilot gets a
file of its own that passes the event name on the command line.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `install.sh` and `uninstall.sh` register every detected agent

**Files:**
- Modify: `scripts/install.sh`, `scripts/uninstall.sh`

Note: the app rename happens in Task 13; this task keeps the `ClaudeBar` names and only changes the hook registration lines. Task 13 renames the rest.

- [ ] **Step 1: `install.sh`**

Add an `--agents` option to the argument loop:

```bash
AGENTS=""
...
        --agents)   AGENTS="$2"; shift 2 ;;
```

and update the usage comment at the top with `#   ./scripts/install.sh --agents claude,codex   register hooks for these agents only`. Replace the two hook lines:

```bash
echo "==> Registering hooks"
if [ -n "$AGENTS" ]; then
    python3 "$ROOT/scripts/register-hooks.py" --tnav "$TNAV" --agents "$AGENTS" | sed 's/^/    /'
else
    python3 "$ROOT/scripts/register-hooks.py" --tnav "$TNAV" | sed 's/^/    /'
fi
```

Replace the closing "Already-running Claude Code sessions…" paragraph with:

```bash
echo "Hooks were registered for every agent found on this machine (Claude Code, Codex,"
echo "Gemini CLI, Copilot CLI). Install another later and open Diagnostics… from the menu"
echo "to register it. Sessions already running appear at their next event."
```

- [ ] **Step 2: `uninstall.sh`**

Replace `python3 "$ROOT/scripts/register-hooks.py" --remove | sed 's/^/    /'` with the same call (the flag is unchanged) but change the echo above it to `echo "==> Removing hooks from every agent"`. In `--help`, change "the Claude Code hooks" to "the hooks from every agent".

- [ ] **Step 3: Dry run the scripts' syntax**

```bash
bash -n scripts/install.sh && bash -n scripts/uninstall.sh && echo syntax ok
```

- [ ] **Step 4: Commit**

```bash
git add scripts/install.sh scripts/uninstall.sh
git commit -m "install.sh registers hooks for every detected agent

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: `HookRegistration` and the per-agent Diagnostics table

**Files:**
- Create: `Sources/TNavCore/HookRegistration.swift`
- Modify: `Sources/ClaudeBarApp/Diagnostics.swift`, `Sources/ClaudeBarApp/main.swift`
- Modify: `scripts/make-app.sh` (ship the registrar in the bundle)
- Test: `Tests/TNavCoreTests/HookRegistrationTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum HookRegistration {
      public struct Status: Equatable { public let kind: AgentKind; public let installed: Bool; public let registered: Bool }
      public static func configFile(for kind: AgentKind, home: URL) -> URL?
      public static func requiredEvents(for kind: AgentKind) -> [String]
      public static func isInstalled(_ kind: AgentKind, home: URL) -> Bool
      public static func isRegistered(_ kind: AgentKind, home: URL) -> Bool
      public static func statuses(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Status]
  }
  ```
  The Swift check mirrors the Python `registered()` rule: for each required event, some string anywhere under that event's entry contains `tnav hook --agent <kind>` (Claude also accepts the legacy bare `tnav hook`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/TNavCoreTests/HookRegistrationTests.swift`:

```swift
import XCTest
@testable import TNavCore

final class HookRegistrationTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ relative: String, _ json: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    func testNotInstalledWithoutConfigDirectory() {
        XCTAssertFalse(HookRegistration.isInstalled(.codex, home: home))
        XCTAssertFalse(HookRegistration.isRegistered(.codex, home: home))
    }

    func testConfigFiles() {
        XCTAssertEqual(HookRegistration.configFile(for: .claude, home: home)?.lastPathComponent, "settings.json")
        XCTAssertEqual(HookRegistration.configFile(for: .codex, home: home)?.lastPathComponent, "hooks.json")
        XCTAssertEqual(HookRegistration.configFile(for: .gemini, home: home)?.lastPathComponent, "settings.json")
        XCTAssertEqual(HookRegistration.configFile(for: .copilot, home: home)?.lastPathComponent, "agentsentinel.json")
        XCTAssertNil(HookRegistration.configFile(for: AgentKind(rawValue: "hermes"), home: home))
    }

    func testClaudeRegisteredWithAgentFlagOrLegacyBareCommand() throws {
        try write(".claude/settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent claude"}]}],
                  "Notification":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent claude"}]}]}}
        """)
        XCTAssertTrue(HookRegistration.isRegistered(.claude, home: home))
        try write(".claude/settings.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/a/tnav hook"}]}],
                  "Notification":[{"hooks":[{"type":"command","command":"/a/tnav hook"}]}]}}
        """)
        XCTAssertTrue(HookRegistration.isRegistered(.claude, home: home), "1.0.x registrations still count")
    }

    func testMissingRequiredEventMeansNotRegistered() throws {
        try write(".codex/hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent codex"}]}]}}
        """)
        XCTAssertTrue(HookRegistration.isInstalled(.codex, home: home))
        XCTAssertFalse(HookRegistration.isRegistered(.codex, home: home), "PermissionRequest is required too")
    }

    func testCopilotFileWithBashCommands() throws {
        try write(".copilot/hooks/agentsentinel.json", """
        {"version":1,"hooks":{"agentStop":[{"type":"command","bash":"/a/tnav hook --agent copilot --event agentStop"}],
                             "permissionRequest":[{"type":"command","bash":"/a/tnav hook --agent copilot --event permissionRequest"}]}}
        """)
        XCTAssertTrue(HookRegistration.isRegistered(.copilot, home: home))
    }

    func testAnotherAgentsCommandDoesNotCount() throws {
        try write(".gemini/settings.json", """
        {"hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent codex"}]}],
                  "Notification":[{"hooks":[{"type":"command","command":"/a/tnav hook --agent codex"}]}]}}
        """)
        XCTAssertFalse(HookRegistration.isRegistered(.gemini, home: home))
    }

    func testMalformedFileIsNotRegistered() throws {
        try write(".gemini/settings.json", "{nope")
        XCTAssertTrue(HookRegistration.isInstalled(.gemini, home: home))
        XCTAssertFalse(HookRegistration.isRegistered(.gemini, home: home))
    }

    func testStatusesCoverEveryKnownKind() {
        let statuses = HookRegistration.statuses(home: home)
        XCTAssertEqual(statuses.map(\.kind), AgentKind.known)
        XCTAssertTrue(statuses.allSatisfy { !$0.installed && !$0.registered })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter HookRegistrationTests 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Create `HookRegistration`**

Create `Sources/TNavCore/HookRegistration.swift`:

```swift
import Foundation

/// Answers "is this agent installed, and are our hooks in its config" by reading the same
/// files the Python registrars write. A hook that isn't registered fails silently and
/// invisibly, so Diagnostics states it plainly.
public enum HookRegistration {
    public struct Status: Equatable, Sendable {
        public let kind: AgentKind
        public let installed: Bool
        public let registered: Bool
    }

    public static func configFile(for kind: AgentKind, home: URL) -> URL? {
        switch kind {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .gemini: return home.appendingPathComponent(".gemini/settings.json")
        case .copilot: return home.appendingPathComponent(".copilot/hooks/agentsentinel.json")
        default: return nil
        }
    }

    /// The events whose absence means the app cannot do its job for that agent: the one that
    /// says "turn finished" and the one that says "needs permission".
    public static func requiredEvents(for kind: AgentKind) -> [String] {
        switch kind {
        case .claude: return ["Stop", "Notification"]
        case .codex: return ["Stop", "PermissionRequest"]
        case .gemini: return ["AfterAgent", "Notification"]
        case .copilot: return ["agentStop", "permissionRequest"]
        default: return []
        }
    }

    public static func isInstalled(_ kind: AgentKind, home: URL) -> Bool {
        guard let directory = kind.configDirectoryName else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home.appendingPathComponent(directory).path,
                                              isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func isRegistered(_ kind: AgentKind, home: URL) -> Bool {
        guard let file = configFile(for: kind, home: home),
              let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return false }

        var markers = ["tnav hook --agent \(kind.rawValue)"]
        if kind == .claude { markers.append("tnav hook") }   // 1.0.x registrations

        for event in requiredEvents(for: kind) {
            guard let entry = hooks[event] else { return false }
            let strings = allStrings(in: entry)
            // The bare "tnav hook" marker must not match another agent's "tnav hook --agent x".
            let hit = strings.contains { s in
                markers.contains { marker in
                    marker == "tnav hook"
                        ? (s.contains("tnav hook") && !s.contains("--agent"))
                        : s.contains(marker)
                }
            }
            if !hit { return false }
        }
        return true
    }

    public static func statuses(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Status] {
        AgentKind.known.map { kind in
            let installed = isInstalled(kind, home: home)
            return Status(kind: kind, installed: installed,
                          registered: installed && isRegistered(kind, home: home))
        }
    }

    /// Every string value anywhere under a JSON fragment. The four agents nest their command
    /// strings differently (`command` vs `bash`, with or without matcher groups); flattening
    /// sidesteps all of that.
    static func allStrings(in value: Any) -> [String] {
        if let s = value as? String { return [s] }
        if let array = value as? [Any] { return array.flatMap(allStrings) }
        if let object = value as? [String: Any] { return object.values.flatMap(allStrings) }
        return []
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter HookRegistrationTests 2>&1 | tail -5`
Expected: 8 pass.

- [ ] **Step 5: Ship the registrar inside the bundle**

In `scripts/make-app.sh`, after the `cp "$BIN/tnav"` line add:

```bash
# The registrar rides along so Diagnostics can register an agent installed after `make install`.
mkdir -p "$APP/Contents/Resources/hooks"
cp "$ROOT/scripts/register-hooks.py" "$APP/Contents/Resources/register-hooks.py"
cp "$ROOT"/scripts/hooks/*.py "$APP/Contents/Resources/hooks/"
rm -f "$APP/Contents/Resources/hooks/test_registrars.py"
```

- [ ] **Step 6: Rewrite Diagnostics**

Replace the whole of `Sources/ClaudeBarApp/Diagnostics.swift` with:

```swift
import AppKit
import TNavCore

/// Surfaces the things that silently degrade: a missing Accessibility grant drops focus to
/// same-Space-only, and a missing hook registration means nothing gets tracked at all for that
/// agent. Both look like "the app is broken" from the outside, so they get stated plainly.
enum Diagnostics {
    static func report(monitor: SessionMonitor) -> String {
        let backend = AdaptiveTabController().activeBackend
        let accessibility = AXWindowMenuController.isPermitted
        let onCurrentSpace = AXWindowMenuController.windowsOnCurrentSpace()

        var lines: [String] = []
        lines.append("Focus backend:   \(backend.rawValue)")
        lines.append("Accessibility:   \(accessibility ? "granted" : "NOT granted")")
        if !accessibility {
            lines.append("                 → tabs on other desktops cannot be reached")
        }
        // Stated plainly because it looks like a bug the first time it happens.
        lines.append("Other desktops:  jumping brings the window to you rather than")
        lines.append("                 switching desktops — a macOS limitation, see docs")
        lines.append("")
        lines.append("Agents:")
        let counts = Dictionary(grouping: monitor.records, by: \.agent).mapValues(\.count)
        for status in HookRegistration.statuses() {
            let name = status.kind.displayName.padding(toLength: 13, withPad: " ", startingAt: 0)
            if !status.installed {
                lines.append("  \(name)not installed")
                continue
            }
            let hooks = status.registered ? "hooks registered" : "hooks NOT registered"
            let sessions = counts[status.kind].map { " · \($0) session\($0 == 1 ? "" : "s")" } ?? ""
            lines.append("  \(name)installed · \(hooks)\(sessions)")
        }
        lines.append("")
        lines.append("Tracked sessions:  \(monitor.records.count)")
        lines.append("Notifications:     \(monitor.config.paused ? "paused" : "active")")
        lines.append("Muted tabs:        \(monitor.config.mutedTabs.count)")

        let controller = AXWindowMenuController()
        if let ttys = try? controller.knownTTYs() {
            let here = ttys.filter { tty in
                guard let info = try? controller.windowInfo(forTTY: tty) else { return false }
                return onCurrentSpace.contains(info.windowID)
            }
            lines.append("Terminal tabs:     \(ttys.count) (\(here.count) on this Space)")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether any agent at all has our hooks. What the launch log line checks.
    static var anyHooksRegistered: Bool {
        HookRegistration.statuses().contains(where: \.registered)
    }

    /// Agents that are installed but whose hooks are missing — each gets a button.
    static var unregisteredInstalledAgents: [AgentKind] {
        HookRegistration.statuses().filter { $0.installed && !$0.registered }.map(\.kind)
    }

    static func present(monitor: SessionMonitor) {
        let alert = NSAlert()
        alert.messageText = "AgentSentinel diagnostics"
        alert.informativeText = report(monitor: monitor)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if !AXWindowMenuController.isPermitted {
            alert.addButton(withTitle: "Open Accessibility Settings")
        }
        let pending = unregisteredInstalledAgents
        for kind in pending {
            alert.addButton(withTitle: "Register hooks for \(kind.displayName)…")
        }
        alert.addButton(withTitle: "Copy")

        // NSAlert returns alertFirstButtonReturn + n for the nth button, so the index is
        // plain arithmetic; matching on button.tag does not work here.
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(index) else { return }

        let title = alert.buttons[index].title
        switch title {
        case "Open Accessibility Settings":
            openAccessibilitySettings()
        case "Copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report(monitor: monitor), forType: .string)
        default:
            if let kind = pending.first(where: { title == "Register hooks for \($0.displayName)…" }) {
                registerHooks(for: kind, monitor: monitor)
            }
        }
    }

    /// Runs the bundled registrar for one agent. This is the one place the app spawns a
    /// process, and only on an explicit click.
    static func registerHooks(for kind: AgentKind, monitor: SessionMonitor) {
        let bundle = Bundle.main
        guard let script = bundle.url(forResource: "register-hooks", withExtension: "py"),
              let tnav = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("tnav").path
        else {
            fail("This build has no bundled registrar. Run `make install` from the source tree instead.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--tnav", tnav, "--agents", kind.rawValue]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fail("Could not run the registrar: \(error)")
            return
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        EventLog.append("diagnostics: register \(kind.rawValue) exit \(process.terminationStatus): \(output)")
        let alert = NSAlert()
        alert.messageText = process.terminationStatus == 0
            ? "Hooks registered for \(kind.displayName)"
            : "Could not register hooks for \(kind.displayName)"
        alert.informativeText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.alertStyle = process.terminationStatus == 0 ? .informational : .warning
        alert.runModal()
    }

    private static func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not register hooks"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
```

In `Sources/ClaudeBarApp/main.swift`, change the launch check to:

```swift
        if !Diagnostics.anyHooksRegistered {
            EventLog.append("app: launched but no agent has hooks registered")
        }
```

- [ ] **Step 7: Build, test, commit**

```bash
swift build 2>&1 | tail -1
TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -3
git add Sources/TNavCore/HookRegistration.swift Sources/ClaudeBarApp/Diagnostics.swift Sources/ClaudeBarApp/main.swift \
        scripts/make-app.sh Tests/TNavCoreTests/HookRegistrationTests.swift
git commit -m "Diagnostics shows every agent's hook status and can register one

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Agent tag on rows, legend, banner, strings, `tnav list`

**Files:**
- Modify: `Sources/ClaudeBarApp/SessionRowView.swift`, `Legend.swift`, `BannerPanel.swift`, `StatusItemController.swift`
- Modify: `Sources/TNavCore/StatusSummary.swift`, `Sources/TNavCore/VisitStore.swift` (one comment), `Sources/tnav/ListCommand.swift`
- Test: `Tests/TNavCoreTests/StatusSummaryTests.swift`, `BadgeQueueTests.swift`, `SnoozeAndUnseenTests.swift`

- [ ] **Step 1: Update the summary string tests**

The accessibility description changes from "Claude" to "agent". Edit the four assertions:

- `Tests/TNavCoreTests/StatusSummaryTests.swift:22` → `"No agent sessions need you"`
- `Tests/TNavCoreTests/StatusSummaryTests.swift:167` → `"1 agent session needs you, longest 47s"`
- `Tests/TNavCoreTests/BadgeQueueTests.swift:142` → `"1 agent session needs you, longest 47s · 1 already opened"`
- `Tests/TNavCoreTests/BadgeQueueTests.swift:150` → `"No agent sessions need you · 1 already opened"`
- `Tests/TNavCoreTests/SnoozeAndUnseenTests.swift:156` → `"No agent sessions need you · 1 unopened request in a silenced tab · 1 silenced"`

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | grep -c "error\|failed"` — expect failures.

- [ ] **Step 2: Change the summary strings**

In `Sources/TNavCore/StatusSummary.swift`:
- `"\(needsAttentionCount) Claude \(verb) you, …"` → `"\(needsAttentionCount) agent \(verb) you, …"`
- `"No Claude sessions need you"` → `"No agent sessions need you"`
- Doc comment `/// No Claude sessions at all.` → `/// No agent sessions at all.`; `/// Sessions Claude is actively working in.` → `/// Sessions an agent is actively working in.`

In `Sources/TNavCore/VisitStore.swift`, the `RowTint.working` comment `/// Claude is running in this tab.` → `/// An agent is running in this tab.`

Run the suite: all pass.

- [ ] **Step 3: Add the agent tag to the row**

In `Sources/ClaudeBarApp/SessionRowView.swift`:

Add a field after `elapsedLabel`:

```swift
    private let agentLabel = NSTextField(labelWithString: "")
```

In `build()`, after `elapsedLabel.alignment = .right` add:

```swift
        // Two monospaced letters in the secondary colour: present enough to tell Codex from
        // Claude at a glance, quiet enough that the project name stays the thing you read.
        agentLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        agentLabel.textColor = .secondaryLabelColor
```

Add `agentLabel` to the `views` array. Change the constraints: `unseenDot.leadingAnchor` now follows the tag —

```swift
            agentLabel.leadingAnchor.constraint(equalTo: projectLabel.trailingAnchor, constant: 6),
            agentLabel.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),

            unseenDot.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 5),
```

(replace the existing `unseenDot.leadingAnchor` line.)

In `detailText()`, replace the message branch and the fallback so the agent (and model when known) lead the line:

```swift
    /// Leads with the agent, then its closing message — you can often answer that without
    /// switching tabs at all. Falls back to the generic reason when there's no message or
    /// the option is off.
    private func detailText() -> String {
        if let remaining = snoozeRemaining {
            return "snoozed \(Elapsed.short(remaining)) · \(deviceName)"
        }
        if showLastMessage,
           let message = record.lastAssistantMessage?
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .replacingOccurrences(of: "\n", with: " "),
           !message.isEmpty {
            return "\(agentDescription) — \(message)"
        }
        return "\(record.reason?.label ?? "working") · \(deviceName)"
    }

    /// "codex · gpt-6-astra", or just "codex" when the payload never said which model.
    private var agentDescription: String {
        if let model = record.model, !model.isEmpty {
            return "\(record.agent.rawValue) · \(model)"
        }
        return record.agent.rawValue
    }
```

In `applyContent()`, after `projectLabel.font = …` add:

```swift
        agentLabel.stringValue = record.agent.tag
        agentLabel.toolTip = record.model.map { "\(record.agent.displayName) · \($0)" } ?? record.agent.displayName
```

In `applyHighlight()`, add `agentLabel.textColor = .selectedMenuItemTextColor` in the highlighted branch and `agentLabel.textColor = .secondaryLabelColor` in the other; add `agentLabel.alphaValue = dimmed` next to `projectLabel.alphaValue = dimmed`.

In `debugLine()`, insert the tag after the name: change the `return` to

```swift
        return "\(statusDot.stringValue)\(unseen) \(name) \(agentLabel.stringValue) \(elapsed) \(paint)  \(detailLabel.stringValue)   \(snooze) \(bell)"
```

Update the comment near the top of `detailText` that mentions "Claude's closing message" (it is replaced above) and the comment in `applyHighlight` `It is often a full sentence of Claude's` → `It is often a full sentence of the agent's`.

- [ ] **Step 4: Legend**

In `Sources/ClaudeBarApp/Legend.swift`:
- `RowTint.meaning` `.working` → `"An agent is working in this tab"`.
- Legend samples: `"Claude is working in 3 tabs; nothing wants you"` → `"Agents are working in 3 tabs; nothing wants you"`; `"No Claude sessions at all"` → `"No agent sessions at all"`.
- After the "The menu bar icon" group's last `sample(...)` and before the next `menu.addItem(.separator())`, add:

```swift
        menu.addItem(.separator())
        menu.addItem(heading("The two letters after each project name"))
        for kind in AgentKind.known {
            menu.addItem(sample(kind.tag, "", kind.displayName, color: .secondaryLabelColor))
        }
```

- [ ] **Step 5: Banner and menu strings**

In `Sources/ClaudeBarApp/BannerPanel.swift`, `BannerView.init`: `NSTextField(labelWithString: record.project)` → `NSTextField(labelWithString: "\(record.project) (\(record.agent.displayName))")`. Fix the comment `Claude's closing message stays in the menu row` → `the agent's closing message stays in the menu row`.

In `Sources/ClaudeBarApp/StatusItemController.swift`:
- `"No Claude sessions running"` → `"No agent sessions running"`
- `"Show Claude's last message"` → `"Show the agent's last message"`
- Comment `then purple (Claude still working)` in `SessionMonitor.swift` → `(an agent still working)`.

- [ ] **Step 6: `tnav list`**

In `Sources/tnav/ListCommand.swift`, the print line becomes:

```swift
            let tag = record.agent.tag
            print("\(marker)\(unseen) \(record.tty)  \(tag)  \(record.summary(now: now))\(suffix)")
```

and in `Sources/TNavCore/SessionRecord.swift` extend `summary(now:)` so the CLI and banner agree:

```swift
    /// "MacTerminalNavigator (Codex) — needs permission · 12s"
    public func summary(now: Double) -> String {
        let detail = reason?.label ?? "working"
        return "\(project) (\(agent.displayName)) — \(detail) · \(Elapsed.short(elapsed(now: now)))"
    }
```

Search the tests for `summary(now:` assertions (`grep -rn "summary(now" Tests`) and update any expected string to include ` (Claude Code)` after the project name.

- [ ] **Step 7: Build, test, dump the menu**

```bash
TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -3
swift build 2>&1 | tail -1
D=$(mktemp -d); mkdir -p $D/sessions
cat > $D/sessions/codex-demo.json <<'JSON'
{"agent":"codex","model":"gpt-6-astra","cwd":"/Users/you/code/ProjectNeuron","escalated":false,"notified":false,"pid":1,"reason":"permission","sessionId":"demo","since":1700000000,"state":"waiting","tty":"/dev/ttys099","lastAssistantMessage":"Allow rm -rf build?"}
JSON
TNAV_STATE_DIR=$D ./.build/debug/ClaudeBarApp --dump-menu
```

Expected: a row line containing `ProjectNeuron` then `CX`, and a detail starting `codex · gpt-6-astra — Allow rm -rf build?`; the legend dump lists `CC  Claude Code`, `CX  Codex`, `GM  Gemini CLI`, `CP  Copilot CLI`. (The record's pid 1 is launchd, which is alive; its tty will not match, so the row may be pruned — if the dump shows no row, set `"pid"` to the pid of a live process whose tty is `/dev/ttys099`, or simply set `"tty"` to the output of `tty` in the shell you run from and `"pid"` to `$$`.)

- [ ] **Step 8: Commit**

```bash
git add -A Sources Tests
git commit -m "Rows carry an agent tag and model; legend, banner and CLI say agent

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: State directory moves to Application Support, with one-time migration

**Files:**
- Modify: `Sources/TNavCore/Paths.swift`
- Create: `Sources/TNavCore/StateMigration.swift`
- Modify: `Sources/ClaudeBarApp/main.swift`
- Test: `Tests/TNavCoreTests/StateMigrationTests.swift`

**Interfaces:**
- Produces: `Paths.legacyRoot: URL` (`~/.claude/tnav`), `Paths.root` now `~/Library/Application Support/AgentSentinel` unless `TNAV_STATE_DIR` is set; `StateMigration.run(from: URL, to: URL) -> [String]` (names of files copied), `StateMigration.runIfNeeded()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TNavCoreTests/StateMigrationTests.swift`:

```swift
import XCTest
@testable import TNavCore

final class StateMigrationTests: XCTestCase {
    private var base: URL!
    private var old: URL { base.appendingPathComponent("old", isDirectory: true) }
    private var new: URL { base.appendingPathComponent("new", isDirectory: true) }

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testCopiesEveryStateFileAndSessions() throws {
        try write(old.appendingPathComponent("config.json"), #"{"paused":true}"#)
        try write(old.appendingPathComponent("visits.json"), "{}")
        try write(old.appendingPathComponent("alerts.json"), "{}")
        try write(old.appendingPathComponent("events.log"), "line\n")
        try write(old.appendingPathComponent("sessions/abc.json"), "{}")

        let copied = StateMigration.run(from: old, to: new)

        XCTAssertEqual(Set(copied), ["config.json", "visits.json", "alerts.json", "events.log", "sessions/abc.json"])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("config.json")), #"{"paused":true}"#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent("sessions/abc.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("config.json").path),
                      "the old directory is left in place")
    }

    func testNeverOverwritesAFileAlreadyInTheNewDirectory() throws {
        try write(old.appendingPathComponent("config.json"), #"{"paused":true}"#)
        try write(new.appendingPathComponent("config.json"), #"{"paused":false}"#)
        let copied = StateMigration.run(from: old, to: new)
        XCTAssertEqual(copied, [])
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("config.json")), #"{"paused":false}"#)
    }

    func testNoOldDirectoryIsANoOp() {
        XCTAssertEqual(StateMigration.run(from: base.appendingPathComponent("nope"), to: new), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    func testIdempotent() throws {
        try write(old.appendingPathComponent("visits.json"), "{}")
        XCTAssertEqual(StateMigration.run(from: old, to: new), ["visits.json"])
        XCTAssertEqual(StateMigration.run(from: old, to: new), [])
    }

    func testDefaultRootIsApplicationSupportUnlessOverridden() throws {
        if ProcessInfo.processInfo.environment[Paths.stateDirectoryVariable] != nil {
            throw XCTSkip("TNAV_STATE_DIR is set, so the default is not in play")
        }
        XCTAssertTrue(Paths.root.path.hasSuffix("/Library/Application Support/AgentSentinel"))
    }

    func testLegacyRootIsTheOldClaudeDirectory() {
        XCTAssertTrue(Paths.legacyRoot.path.hasSuffix("/.claude/tnav"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `TNAV_STATE_DIR="$(mktemp -d)" swift test --filter StateMigrationTests 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Update `Paths`**

In `Sources/TNavCore/Paths.swift`, replace the `root` definition with:

```swift
    public static let root: URL = {
        let override = ProcessInfo.processInfo.environment[stateDirectoryVariable]
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                       isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("AgentSentinel", isDirectory: true)
    }()

    /// Where the 1.0.x builds kept state. Only `StateMigration` and the uninstaller care.
    public static let legacyRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("tnav", isDirectory: true)
```

- [ ] **Step 4: Create `StateMigration`**

Create `Sources/TNavCore/StateMigration.swift`:

```swift
import Foundation

/// Copies the 1.0.x state directory (`~/.claude/tnav`) into the new one, once.
///
/// Copy rather than move, and never overwrite: a hook from an already-running session may
/// have written to the new directory before the app first launched, and that newer record
/// must win. The old directory is left for `uninstall.sh --purge` to deal with, so a user
/// who downgrades loses nothing.
public enum StateMigration {
    static let files = ["config.json", "visits.json", "alerts.json", "events.log"]

    /// Returns the relative paths that were copied.
    @discardableResult
    public static func run(from old: URL, to new: URL) -> [String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }

        var copied: [String] = []
        var candidates = files
        let oldSessions = old.appendingPathComponent("sessions")
        if let names = try? fm.contentsOfDirectory(atPath: oldSessions.path) {
            candidates += names.filter { $0.hasSuffix(".json") }.map { "sessions/\($0)" }
        }

        for relative in candidates {
            let source = old.appendingPathComponent(relative)
            let target = new.appendingPathComponent(relative)
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                copied.append(relative)
            } catch {
                EventLog.append("migration: could not copy \(relative): \(error)")
            }
        }
        return copied
    }

    /// The app calls this at launch. A no-op when `TNAV_STATE_DIR` points somewhere else, so
    /// tests and scratch runs never touch the real legacy directory.
    public static func runIfNeeded() {
        guard ProcessInfo.processInfo.environment[Paths.stateDirectoryVariable] == nil else { return }
        let copied = run(from: Paths.legacyRoot, to: Paths.root)
        if !copied.isEmpty {
            EventLog.append("migration: copied \(copied.count) file(s) from \(Paths.legacyRoot.path)")
        }
    }
}
```

In `Sources/ClaudeBarApp/main.swift`, as the first line of `applicationDidFinishLaunching`, add `StateMigration.runIfNeeded()`.

- [ ] **Step 5: Run the suite, commit**

```bash
TNAV_STATE_DIR="$(mktemp -d)" swift test 2>&1 | tail -3
git add Sources/TNavCore/Paths.swift Sources/TNavCore/StateMigration.swift Sources/ClaudeBarApp/main.swift Tests/TNavCoreTests/StateMigrationTests.swift
git commit -m "State lives in ~/Library/Application Support/AgentSentinel; old state is copied once

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: Rename ClaudeBar → AgentSentinel

**Files:**
- Move: `Sources/ClaudeBarApp/` → `Sources/AgentSentinelApp/`
- Modify: `Package.swift`, `Makefile`, `scripts/make-app.sh`, `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/hooks/common.py` (marker already present), `Sources/AgentSentinelApp/SettingsWindow.swift`, `StatusItemController.swift`
- Modify: `scripts/make-icon.swift` only if it embeds the name (check with `grep -n ClaudeBar scripts/make-icon.swift`).

- [ ] **Step 1: Move the target and rename the package**

```bash
git mv Sources/ClaudeBarApp Sources/AgentSentinelApp
sed -i '' 's/name: "ClaudeBar"/name: "AgentSentinel"/; s/ClaudeBarApp/AgentSentinelApp/g' Package.swift
sed -i '' 's/ClaudeBarApp/AgentSentinelApp/g; s/ClaudeBar\.app/AgentSentinel.app/g; s/@echo "ClaudeBar"/@echo "AgentSentinel"/' Makefile
sed -i '' 's|~/.claude/tnav|the state directory|' Makefile
swift build 2>&1 | tail -1
```

Expected: `Build complete!`.

- [ ] **Step 2: In-app strings**

- `Sources/AgentSentinelApp/SettingsWindow.swift`: `"ClaudeBar Settings"` → `"AgentSentinel Settings"`.
- `Sources/AgentSentinelApp/StatusItemController.swift`: `"Quit ClaudeBar"` → `"Quit AgentSentinel"`.
- `grep -rn "ClaudeBar" Sources` must print nothing afterwards (Diagnostics was done in Task 11).

- [ ] **Step 3: `make-app.sh`**

```bash
sed -i '' 's/ClaudeBar\.app/AgentSentinel.app/g; s|cp "$BIN/ClaudeBarApp" "$APP/Contents/MacOS/ClaudeBar"|cp "$BIN/AgentSentinelApp" "$APP/Contents/MacOS/AgentSentinel"|; s/<string>ClaudeBar<\/string>/<string>AgentSentinel<\/string>/g; s/com\.github\.ayekarimba\.claudebar/com.github.ayekarimba.agentsentinel/; s/^VERSION=.*/VERSION="2.0.0"/; s/# Builds ClaudeBar\.app\./# Builds AgentSentinel.app./' scripts/make-app.sh
```

Then edit by hand the `NSAppleEventsUsageDescription` string to:
`AgentSentinel asks Terminal which tab each agent session is running in, so it can take you to the right one.`
and the comment `so the Claude Code hooks can point at a path` → `so every agent's hooks can point at a path`.

- [ ] **Step 4: `install.sh`**

Replace the name-specific parts:

```bash
sed -i '' 's/ClaudeBar\.app/AgentSentinel.app/g; s/ClaudeBarApp/AgentSentinelApp/g; s/com\.github\.ayekarimba\.claudebar/com.github.ayekarimba.agentsentinel/g; s|Contents/MacOS/ClaudeBar"|Contents/MacOS/AgentSentinel"|; s|<string>$APP/Contents/MacOS/ClaudeBar</string>|<string>$APP/Contents/MacOS/AgentSentinel</string>|; s/# Build, install and start ClaudeBar\./# Build, install and start AgentSentinel./; s/ClaudeBar is now in your menu bar/AgentSentinel is now in your menu bar/' scripts/install.sh
```

Then extend the migration block so a ClaudeBar install is retired exactly as TerminalNavigator was. After the TerminalNavigator block, add:

```bash
# Same again for the second name, ClaudeBar. Its login item and bundle go; a symlink stays so
# hooks snapshotted under the old path keep working until those sessions restart.
CB_AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.claudebar.plist"
pkill -f "ClaudeBar.app/Contents/MacOS/ClaudeBar" 2>/dev/null || true
if [ -f "$CB_AGENT" ]; then
    echo "==> Migrating from ClaudeBar"
    launchctl unload "$CB_AGENT" 2>/dev/null || true
    rm -f "$CB_AGENT"
fi
[ -e "$PREFIX/ClaudeBar.app" ] && [ ! -L "$PREFIX/ClaudeBar.app" ] && rm -rf "$PREFIX/ClaudeBar.app"
```

and after `ln -sfn "$APP" "$PREFIX/TerminalNavigator.app"` add `ln -sfn "$APP" "$PREFIX/ClaudeBar.app"`.

Also fix: the first `pkill -f "ClaudeBar.app/…"` line that `sed` turned into `AgentSentinel.app/Contents/MacOS/AgentSentinel` is correct for the new app; the one in the migration block above handles the old one.

- [ ] **Step 5: `uninstall.sh`**

```bash
sed -i '' 's/# Remove ClaudeBar:/# Remove AgentSentinel:/; s/com\.github\.ayekarimba\.claudebar/com.github.ayekarimba.agentsentinel/; s/Nothing of ClaudeBar is left running/Nothing of AgentSentinel is left running/' scripts/uninstall.sh
```

Then by hand:
- `OLD_AGENT=` line: keep, and add `CB_AGENT="$HOME/Library/LaunchAgents/com.github.ayekarimba.claudebar.plist"`; include it in the `for agent in` loop.
- `pkill` lines: add `pkill -f "AgentSentinel.app/Contents/MacOS/AgentSentinel" 2>/dev/null || true` and keep the ClaudeBar and TerminalNavigator ones.
- `for app in ClaudeBar.app TerminalNavigator.app` → `for app in AgentSentinel.app ClaudeBar.app TerminalNavigator.app`.
- The `--purge` block becomes:

```bash
STATE="$HOME/Library/Application Support/AgentSentinel"
LEGACY="$HOME/.claude/tnav"
if [ "$PURGE" = "1" ]; then
    echo "==> Removing $STATE"
    rm -rf "$STATE"
    if [ -d "$LEGACY" ]; then
        echo "==> Removing $LEGACY (pre-2.0 state)"
        rm -rf "$LEGACY"
    fi
else
    echo "==> Keeping $STATE (settings and session state); --purge removes it"
fi
```

and the `--help` text: `--purge  also delete the state directory (settings and session state)`.

- [ ] **Step 6: Verify**

```bash
bash -n scripts/install.sh && bash -n scripts/uninstall.sh && bash -n scripts/make-app.sh
grep -rn "ClaudeBar" Sources Package.swift Makefile | grep -v "^Makefile.*pkill" ; echo "(expect no output above)"
./scripts/make-app.sh build/AgentSentinel.app 2>&1 | tail -2
ls build/AgentSentinel.app/Contents/MacOS build/AgentSentinel.app/Contents/Resources
make check 2>&1 | tail -3
```

Expected: `AgentSentinel  tnav` in MacOS; `AppIcon.icns hooks register-hooks.py` in Resources; `make check` passes.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Rename the app to AgentSentinel

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: README and docs

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-10-10-multi-agent-design.md` (status line only)

- [ ] **Step 1: Rewrite the top of the README**

Replace the title and first three paragraphs with:

```markdown
# AgentSentinel

A macOS menu bar app that tells you which CLI coding agent sessions are waiting on you, and
takes you to the right terminal tab when you click one. Works with Claude Code, Codex CLI,
Gemini CLI and Copilot CLI. An unofficial community tool, not affiliated with any of their
makers. Formerly ClaudeBar, and before that TerminalNavigator.

Run four agents in six tabs and the hard part stops being the work — it's noticing that one of
them has been sitting on a permission prompt for ten minutes while you watched a different one
think. This puts that in the menu bar.
```

Keep the screenshots. In the colour table, `**purple** | Claude is working` → `an agent is working`. In the icon table, `no Claude sessions at all` → `no agent sessions at all`.

- [ ] **Step 2: Add an "Agents" section after Requirements**

```markdown
## Agents

| Agent | How it's wired | Verified live |
|---|---|---|
| Claude Code | hooks in `~/.claude/settings.json` | yes |
| Codex CLI | hooks in `~/.codex/hooks.json` — after installing, start `codex`, type `/hooks` and accept the AgentSentinel entries, or they are silently skipped | yes |
| Gemini CLI | hooks in `~/.gemini/settings.json` | not yet — hooks are registered from the documented payload shape; please report what you see |
| Copilot CLI | `~/.copilot/hooks/agentsentinel.json` | not yet — same |

`make install` registers hooks for every agent whose config directory exists. Install another
agent later and open **Diagnostics…** from the menu: it lists each agent's status and offers a
button to register it. Each row shows a two-letter tag (`CC`, `CX`, `GM`, `CP`) and, when the
agent reports it, the model.

Hermes Agent, OpenCode and Cursor CLI have hook systems too and are not yet supported; each is
one adapter in `Sources/TNavCore/Agents/` plus one registrar in `scripts/hooks/`.
```

- [ ] **Step 3: Update the rest**

- Requirements: `- [Claude Code](https://claude.com/claude-code)` → `- At least one of: Claude Code, Codex CLI, Gemini CLI, Copilot CLI`.
- "What `make install` actually does": `Adds six hooks to ~/.claude/settings.json` → `Registers hooks with every agent found (Claude Code, Codex, Gemini CLI, Copilot CLI), merging into each agent's config and backing it up first`. Replace `~/.claude/tnav` with `~/Library/Application Support/AgentSentinel` in the uninstall sentence.
- "What it touches": **Reads** paragraph → `the hook payload each agent hands it: session id, working directory, event name, permission message, and the agent's closing message when the agent includes it. It never opens a transcript file.` **Writes** → `~/Library/Application Support/AgentSentinel/` and `Installing also adds hook entries to each detected agent's config file, merging rather than replacing, with a backup alongside.` Add: `On first launch after upgrading from ClaudeBar, state is copied from ~/.claude/tnav; the old directory is left in place until uninstall.sh --purge.`
- "How it works": `Claude Code hooks fire on every session event. tnav hook resolves…` → `Each agent's hooks fire on every session event, as tnav hook --agent <kind>. The adapter for that agent (Sources/TNavCore/Agents/) turns the payload into one of six normalized events; everything after that is agent-independent. tnav resolves…`. Update the state path.
- Add a subsection after "Adding a terminal":

```markdown
### Adding an agent

Three pieces, none of which touch the state machine or the UI:

1. An `AgentAdapter` conformance in `Sources/TNavCore/Agents/` mapping the agent's events to
   `AgentEvent` (session start, prompt submitted, tool starting, turn complete, needs
   permission, session end). Add it to `AgentRegistry` and `AgentKind.known`.
2. A process signature in `AgentKind.signature` so the hook can find the agent in its own
   ancestry — the binary name, or the package path fragment for a Node program.
3. A registrar module in `scripts/hooks/` that merges `tnav hook --agent <kind>` into the
   agent's config, plus the matching `HookRegistration` entries for Diagnostics.
```

- Development: `make test        # 148 unit tests` → `make test          # unit tests`, add `make test-scripts  # registrar tests`. CLI examples: `tnav hook --agent codex` mention; `--dump-menu` path `./.build/debug/AgentSentinelApp --dump-menu`. State dir note stays (`TNAV_STATE_DIR`).
- Troubleshooting table: `Hooks aren't registered. Diagnostics will say so; re-run make install.` → `Hooks aren't registered for that agent. Diagnostics lists each agent; use its Register button or re-run make install.` Add a row: `Codex sessions never appear | Codex skips hooks it has not been told to trust. Start codex, type /hooks, accept the AgentSentinel entries.`
- Design notes: add `- docs/superpowers/specs/2026-10-10-multi-agent-design.md — the multi-agent design, with the per-agent feasibility table`.

- [ ] **Step 4: Mark the spec**

In `docs/superpowers/specs/2026-10-10-multi-agent-design.md`, change `**Status:** approved` to `**Status:** approved; implemented by docs/superpowers/plans/2026-10-10-multi-agent.md`.

- [ ] **Step 5: Final verification and commit**

```bash
make check 2>&1 | tail -3
grep -rn -i "claudebar\|Claude Code hooks are" README.md | grep -v "Formerly ClaudeBar\|from ClaudeBar" ; echo "(expect no output above)"
git add README.md docs
git commit -m "README for AgentSentinel: agents table, adding an agent, new state path

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Live verification (manual, after Task 15)

Not a numbered task because it needs the real machine, but part of done:

1. `make install`. Confirm the install output lists `registered 6 claude hooks` and `registered 6 codex hooks` and prints the Codex trust note.
2. Start `codex` in a Terminal tab, type `/hooks`, trust the six AgentSentinel entries.
3. Send a prompt. The row appears with `CX`, purple while working, orange on `Stop` with the model on the second line. Trigger a command that needs approval; the row goes red and the banner says `(Codex)`.
4. Start `claude` in another tab; confirm its row shows `CC` and behaves as before.
5. Open Diagnostics; confirm the Agents table shows both as `installed · hooks registered` with session counts, and Gemini/Copilot as `not installed`.
6. `./scripts/uninstall.sh --purge` on a throwaway run is optional; at minimum run `python3 scripts/register-hooks.py --status`.

## Self-review notes

- **Spec coverage.** §1 core model → Tasks 1–3; §2 hook path/matcher/nesting → Tasks 4–5 (probe done pre-plan); §3 registration + Diagnostics → Tasks 9–11; §4 UI → Task 12; §5 rename + state dir → Tasks 13–14; §6 testing → every task carries its tests, integration test parametrised in Tasks 5–8, Python tests in Task 9; §7 out of scope → README "Adding an agent". Open item 2 (Node entry points) resolved in the probe notes: match on `/gemini-cli/` and `/@github/copilot/` path fragments. Open item 3 (Copilot last message) → decided no, Task 8.
- **Deviation from spec, deliberate:** bundle id is `com.github.ayekarimba.agentsentinel`, not `com.ayekarimba.agentsentinel`, to keep the prefix the LaunchAgent labels already use.
- **Deviation from spec, deliberate:** `VisitStore` and `AlertStore` stay keyed by bare `sessionId`. Only the record filename gained the agent prefix; a cross-agent id collision would need two agents to mint the same UUID.
- **Type consistency checked:** `DecodedHook(sessionId:cwd:model:rawEventName:event:)`, `HookProcessor.apply(agent:hook:identity:existing:now:)`, `SessionIdentity(tty:sessionPid:agentAncestors:nearestAgent:)`, `AgentMatcher.match(_:) -> AgentKind?`, `SessionStore.load(agent:sessionId:)` / `remove(agent:sessionId:)` / `remove(_:)`, `HookRegistration.statuses(home:)` are spelled the same in every task that uses them.
