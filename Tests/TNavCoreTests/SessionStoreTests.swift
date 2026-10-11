import XCTest
@testable import TNavCore

final class SessionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(id: String = "s1",
                        tty: String = "/dev/ttys003",
                        pid: Int32 = 100,
                        state: SessionState = .waiting,
                        since: Double = 1000) -> SessionRecord {
        SessionRecord(sessionId: id, tty: tty, pid: pid, cwd: "/tmp/proj",
                      state: state, reason: .turnComplete, since: since)
    }

    func testRoundTrip() throws {
        let store = SessionStore(directory: directory)
        let original = record()
        try store.save(original)
        XCTAssertEqual(store.load(agent: .claude, sessionId: "s1"), original)
    }

    func testAllReadsEveryRecord() throws {
        let store = SessionStore(directory: directory)
        try store.save(record(id: "s1"))
        try store.save(record(id: "s2"))
        XCTAssertEqual(Set(store.all().map(\.sessionId)), ["s1", "s2"])
    }

    func testWaitingIsSortedOldestFirst() throws {
        let store = SessionStore(directory: directory)
        try store.save(record(id: "newer", since: 2000))
        try store.save(record(id: "older", since: 1000))
        try store.save(record(id: "busy", state: .working, since: 500))
        XCTAssertEqual(store.waiting().map(\.sessionId), ["older", "newer"],
                       "jump order is oldest wait first")
    }

    func testRemove() throws {
        let store = SessionStore(directory: directory)
        try store.save(record())
        store.remove(agent: .claude, sessionId: "s1")
        XCTAssertNil(store.load(agent: .claude, sessionId: "s1"))
    }

    func testRemoveMissingOrUnsafeIdIsAQuietNoOp() throws {
        let store = SessionStore(directory: directory)
        try store.save(record())
        store.remove(agent: .claude, sessionId: "never-existed")
        store.remove(agent: .claude, sessionId: "../evil")
        XCTAssertEqual(store.all().map(\.sessionId), ["s1"],
                       "a bad id must not throw, and must not delete anything")
    }

    func testRemoveLeavesOtherRecordsAlone() throws {
        let store = SessionStore(directory: directory)
        try store.save(record(id: "s1"))
        try store.save(record(id: "s2"))
        store.remove(agent: .claude, sessionId: "s1")
        XCTAssertNil(store.load(agent: .claude, sessionId: "s1"))
        XCTAssertEqual(store.all().map(\.sessionId), ["s2"])
    }

    func testIgnoresNonJSONAndCorruptFiles() throws {
        let store = SessionStore(directory: directory)
        try store.save(record())
        try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        XCTAssertEqual(store.all().count, 1, "a corrupt file must not hide the good records")
    }

    // MARK: - Path safety

    func testRejectsSessionIdsThatWouldEscapeTheDirectory() {
        let store = SessionStore(directory: directory)
        XCTAssertNil(store.url(agent: .claude, sessionId: "../../etc/passwd"))
        XCTAssertNil(store.url(agent: .claude, sessionId: "a/b"))
        XCTAssertNil(store.url(agent: .claude, sessionId: ""))
        XCTAssertNil(store.url(agent: .claude, sessionId: ".."))
        XCTAssertNotNil(store.url(agent: .claude, sessionId: "9cf7abf1-94cb-4db1-912a-38247f0898b6"))
    }

    func testSaveThrowsOnUnsafeSessionId() {
        let store = SessionStore(directory: directory)
        XCTAssertThrowsError(try store.save(record(id: "../evil")))
    }

    // MARK: - Liveness / pruning

    func testPruneKeepsLiveSessionAndDropsDeadOne() throws {
        let live = SysctlProcessTable().row(for: getpid())
        let table = StubProcessTable([
            ProcessRow(pid: 100, ppid: 1, tty: "/dev/ttys003", command: "claude"),
        ])
        let store = SessionStore(directory: directory, table: table)
        try store.save(record(id: "alive", tty: "/dev/ttys003", pid: 100))
        try store.save(record(id: "dead", tty: "/dev/ttys004", pid: 999))

        let removed = store.prune()
        XCTAssertEqual(removed, ["dead"])
        XCTAssertEqual(store.all().map(\.sessionId), ["alive"])
        XCTAssertNotNil(live, "sanity: the live process table works in this environment")
    }

    func testTreatsRecycledPIDAsDead() throws {
        // Same pid, different controlling terminal — the pid was reused by something else.
        let table = StubProcessTable([
            ProcessRow(pid: 100, ppid: 1, tty: "/dev/ttys077", command: "vim"),
        ])
        let store = SessionStore(directory: directory, table: table)
        try store.save(record(id: "stale", tty: "/dev/ttys003", pid: 100))
        XCTAssertEqual(store.prune(), ["stale"])
    }

    // MARK: - Config

    func testConfigRoundTripAndMutate() throws {
        let configStore = ConfigStore(url: directory.appendingPathComponent("config.json"))
        XCTAssertEqual(configStore.load(), Config())

        try configStore.mutate { $0.mutedTabs.append("/dev/ttys003|/tmp/proj") }
        try configStore.mutate { $0.paused = true }

        let loaded = configStore.load()
        XCTAssertEqual(loaded.mutedTabs, ["/dev/ttys003|/tmp/proj"])
        XCTAssertTrue(loaded.paused)
        XCTAssertEqual(loaded.escalateAfterSeconds, 300, "untouched defaults should persist")
    }

    func testConfigDecodesLeniendlyWhenKeysAreMissing() throws {
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"paused":true}"#.utf8).write(to: url)
        let loaded = ConfigStore(url: url).load()
        XCTAssertTrue(loaded.paused)
        XCTAssertEqual(loaded.escalateAfterSeconds, 300)
        XCTAssertEqual(loaded.mutedTabs, [])
    }

    // MARK: - TTY validation

    func testValidateTTYAcceptsRealDevices() throws {
        XCTAssertNoThrow(try validateTTY("/dev/ttys003"))
        XCTAssertNoThrow(try validateTTY("/dev/ttys000"))
    }

    func testValidateTTYRejectsAnythingElse() {
        for bad in ["/dev/tty", "", "/etc/passwd", "/dev/ttys003\" ; do shell stuff",
                    "/dev/ttys003 and quit", "/dev/ttys-3", "../dev/ttys003"] {
            XCTAssertThrowsError(try validateTTY(bad), "should reject \(bad)")
        }
    }

    func testAppleScriptLiteralEscaping() {
        XCTAssertEqual(appleScriptLiteral(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(appleScriptLiteral(#"back\slash"#), #""back\\slash""#)
        XCTAssertEqual(appleScriptLiteral("two\nlines"), #""two lines""#)
    }

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
}
