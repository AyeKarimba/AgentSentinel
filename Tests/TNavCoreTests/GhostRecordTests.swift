import XCTest
@testable import TNavCore

/// A record that outlives its session but keeps passing the liveness check.
///
/// The case that prompted this: a record left behind by testing, naming a pid and tty that
/// belonged to a *different*, still-running session. `isAlive` checks that the pid exists and
/// its tty matches, and both were true — so it never pruned, could not be jumped to (the tab it
/// named belonged to someone else), and there was no way for the user to dismiss it.
final class GhostRecordTests: XCTestCase {
    private var directory: URL!
    private var store: SessionStore!

    private func record(_ id: String, pid: Int32, tty: String, since: Double,
                        cwd: String = "/Users/you/proj") -> SessionRecord {
        SessionRecord(sessionId: id, tty: tty, pid: pid, cwd: cwd,
                      state: .waiting, reason: .turnComplete, since: since)
    }

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-ghost-\(UUID().uuidString)", isDirectory: true)
        // Every pid in these tests resolves to a live process on a matching tty, so the
        // ordinary liveness check passes and only the duplicate rule can act.
        store = SessionStore(directory: directory, table: StubProcessTable([
            ProcessRow(pid: 100, ppid: 1, tty: "/dev/ttys003", command: "claude"),
            ProcessRow(pid: 200, ppid: 1, tty: "/dev/ttys004", command: "claude"),
        ]))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testTwoRecordsOnOnePidKeepOnlyTheMostRecentlyActive() throws {
        let live = record("live", pid: 100, tty: "/dev/ttys003", since: 5000)
        let ghost = record("ghost", pid: 100, tty: "/dev/ttys003", since: 1000,
                           cwd: "/Users/you/DemoProject")
        try store.save(live)
        try store.save(ghost)

        XCTAssertTrue(store.isAlive(ghost),
                      "the pid exists and the tty matches, which is exactly why liveness cannot "
                      + "catch this on its own")

        let survivors = store.prune(store.all())
        XCTAssertEqual(survivors.map(\.sessionId), ["live"])
        XCTAssertNil(store.load("ghost"), "and it is gone from disk, not just from the list")
    }

    func testDistinctPidsAreAllLeftAlone() throws {
        try store.save(record("a", pid: 100, tty: "/dev/ttys003", since: 1000))
        try store.save(record("b", pid: 200, tty: "/dev/ttys004", since: 2000))
        let survivors = store.prune(store.all()).map(\.sessionId).sorted()
        XCTAssertEqual(survivors, ["a", "b"], "two real sessions must not be mistaken for a ghost")
    }

    func testADeadPidIsStillPrunedTheOldWay() throws {
        try store.save(record("gone", pid: 999, tty: "/dev/ttys009", since: 1000))
        XCTAssertTrue(store.prune(store.all()).isEmpty)
    }

    /// Picking the wrong survivor is tolerable precisely because it does not last: a live
    /// session rewrites its record on its next hook event, and a stale one never does.
    func testTheLosingRecordCanSimplyBeWrittenAgain() throws {
        let older = record("older", pid: 100, tty: "/dev/ttys003", since: 1000)
        try store.save(older)
        try store.save(record("newer", pid: 100, tty: "/dev/ttys003", since: 5000))
        XCTAssertEqual(store.prune(store.all()).map(\.sessionId), ["newer"])

        // The real session's next event puts it back, now with a later `since`.
        try store.save(record("older", pid: 100, tty: "/dev/ttys003", since: 9000))
        XCTAssertEqual(store.prune(store.all()).map(\.sessionId), ["older"])
    }
}
