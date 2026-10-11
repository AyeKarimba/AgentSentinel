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

    func testSkipsBareSessionWhenPrefixedRecordAlreadyExists() throws {
        try write(old.appendingPathComponent("sessions/abc.json"), "{}")
        try write(old.appendingPathComponent("sessions/def.json"), "{}")
        try write(new.appendingPathComponent("sessions/claude-abc.json"), "{}")
        let copied = StateMigration.run(from: old, to: new)
        XCTAssertEqual(copied, ["sessions/def.json"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("sessions/abc.json").path))
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

    func testRunOnceCopiesThenLeavesMarker() throws {
        try write(old.appendingPathComponent("visits.json"), "{}")
        XCTAssertEqual(StateMigration.runOnce(from: old, to: new), ["visits.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent(".migrated").path))
    }

    func testRunOnceDoesNotResurrectDeletedFiles() throws {
        try write(old.appendingPathComponent("visits.json"), "{}")
        StateMigration.runOnce(from: old, to: new)
        try FileManager.default.removeItem(at: new.appendingPathComponent("visits.json"))
        XCTAssertEqual(StateMigration.runOnce(from: old, to: new), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("visits.json").path))
    }

    func testRunOnceWritesMarkerEvenWithoutOldDirectory() {
        XCTAssertEqual(StateMigration.runOnce(from: base.appendingPathComponent("nope"), to: new), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.appendingPathComponent(".migrated").path))
    }
}
