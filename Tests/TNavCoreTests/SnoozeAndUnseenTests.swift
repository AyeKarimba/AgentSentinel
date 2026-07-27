import XCTest
@testable import TNavCore

/// Covers the three rules added after the first round of real use: snooze (a mute that
/// expires), blocking-only alerting, and the "haven't even looked at it" marker.
final class SnoozeAndUnseenTests: XCTestCase {
    private func record(id: String = "s1",
                        reason: WaitReason? = .permission,
                        state: SessionState = .waiting,
                        since: Double = 1000,
                        tty: String = "/dev/ttys003",
                        cwd: String = "/Users/you/proj",
                        notified: Bool = false) -> SessionRecord {
        SessionRecord(sessionId: id, tty: tty, pid: 100, cwd: cwd,
                      state: state, reason: reason, since: since, notified: notified)
    }

    // MARK: - Snooze

    func testSnoozeSuppressesUntilItExpires() {
        let target = record()
        let config = Config(snoozedUntil: [target.tabMuteKey: 1600])

        XCTAssertEqual(AlertPolicy.decide(record: target, config: config,
                                          frontmostTTY: nil, now: 1500),
                       .suppressSnoozed)
        XCTAssertEqual(AlertPolicy.decide(record: target, config: config,
                                          frontmostTTY: nil, now: 1601),
                       .notify(.urgent),
                       "a snooze must come back on its own — that is the whole difference from mute")
    }

    func testSnoozeIsScopedToOneTab() {
        let snoozed = record(tty: "/dev/ttys003")
        let other = record(id: "s2", tty: "/dev/ttys009")
        let config = Config(snoozedUntil: [snoozed.tabMuteKey: 1600])
        XCTAssertEqual(AlertPolicy.decide(record: other, config: config,
                                          frontmostTTY: nil, now: 1500),
                       .notify(.urgent))
    }

    func testSnoozedSessionsDropOutOfTheBadgeButAreReportedAsSilenced() {
        let snoozed = record(id: "a", since: 700, tty: "/dev/ttys001", cwd: "/quiet")
        let audible = record(id: "b", reason: .turnComplete, since: 953,
                             tty: "/dev/ttys002", cwd: "/loud")
        let config = Config(snoozedUntil: [snoozed.tabMuteKey: 1600])
        let summary = StatusSummary(records: [snoozed, audible], config: config, now: 1000)

        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.badgeText, "1 · 47s")
        XCTAssertEqual(summary.silencedWaitingCount, 1)
    }

    func testSnoozeRemainingCountsDown() {
        let target = record()
        let config = Config(snoozedUntil: [target.tabMuteKey: 1600])
        XCTAssertEqual(config.snoozeRemaining(target, now: 1000), 600)
        XCTAssertNil(config.snoozeRemaining(target, now: 1700), "expired snoozes report nothing")
    }

    func testPruningDropsOnlyExpiredSnoozes() {
        var config = Config(snoozedUntil: ["a|/x": 900, "b|/y": 1600])
        config.pruneExpiredSnoozes(now: 1000)
        XCTAssertEqual(config.snoozedUntil, ["b|/y": 1600])
    }

    func testMuteAndSnoozeBothCountAsSilenced() {
        let muted = record(id: "a", tty: "/dev/ttys001")
        let snoozed = record(id: "b", tty: "/dev/ttys002")
        let config = Config(mutedTabs: [muted.tabMuteKey],
                            snoozedUntil: [snoozed.tabMuteKey: 1600])
        XCTAssertTrue(config.isSilenced(muted, now: 1000))
        XCTAssertTrue(config.isSilenced(snoozed, now: 1000))
        XCTAssertFalse(config.isSilenced(record(id: "c", tty: "/dev/ttys007"), now: 1000))
    }

    // MARK: - Blocking-only

    func testBlockingOnlySilencesTurnCompletionsButNotPermissionRequests() {
        let config = Config(blockingOnly: true)
        XCTAssertEqual(AlertPolicy.decide(record: record(reason: .turnComplete),
                                          config: config, frontmostTTY: nil, now: 1000),
                       .suppressNonBlocking)
        XCTAssertEqual(AlertPolicy.decide(record: record(reason: .idlePrompt),
                                          config: config, frontmostTTY: nil, now: 1000),
                       .suppressNonBlocking)
        XCTAssertEqual(AlertPolicy.decide(record: record(reason: .permission),
                                          config: config, frontmostTTY: nil, now: 1000),
                       .notify(.urgent))
    }

    func testBlockingOnlyStillLeavesTurnCompletionsVisibleInTheBadge() {
        let records = [record(id: "a", reason: .turnComplete, since: 953)]
        let summary = StatusSummary(records: records, config: Config(blockingOnly: true), now: 1000)
        XCTAssertEqual(summary.waitingCount, 1,
                       "blocking-only governs alerts, not what the menu shows you")
        XCTAssertEqual(summary.badgeText, "1 · 47s")
    }

    // MARK: - Unseen blocking requests

    func testUrgentRequestIsUnseenUntilTheTabIsVisited() {
        let target = record(reason: .permission, since: 1000)
        XCTAssertTrue(target.isUnseenUrgent(lastVisit: nil), "never visited")
        XCTAssertTrue(target.isUnseenUrgent(lastVisit: 900),
                      "last visit predates the request — you have not seen this one")
        XCTAssertFalse(target.isUnseenUrgent(lastVisit: 1001), "visited since it arrived")
    }

    func testTurnCompletionsNeverCountAsUnseenUrgent() {
        let target = record(reason: .turnComplete, since: 1000)
        XCTAssertFalse(target.isUnseenUrgent(lastVisit: nil),
                       "the dot is for blocking requests only")
    }

    func testWorkingSessionIsNeverUnseenUrgent() {
        let target = record(reason: nil, state: .working, since: 1000)
        XCTAssertFalse(target.isUnseenUrgent(lastVisit: nil))
    }

    func testSilencingATabDoesNotClearTheUnseenDot() {
        // Muting stops the nagging; it does not mean you looked at the request.
        let target = record(reason: .permission, since: 1000)
        let config = Config(mutedTabs: [target.tabMuteKey])
        let summary = StatusSummary(records: [target], config: config, visits: [:], now: 1100)
        XCTAssertEqual(summary.waitingCount, 0, "muted, so it does not nag")
        XCTAssertEqual(summary.unseenUrgentCount, 1, "but it is still something you never saw")
        XCTAssertTrue(summary.showsUnseenDot)
    }

    func testVisitingTheTabClearsTheDotEvenThoughAReplyIsStillOutstanding() {
        let target = record(reason: .permission, since: 1000)
        let summary = StatusSummary(records: [target], config: Config(),
                                    visits: [target.sessionId: 1050], now: 1100)
        XCTAssertEqual(summary.unseenUrgentCount, 0, "you have been there")
        XCTAssertEqual(summary.waitingCount, 1, "but it still needs an answer")
        XCTAssertFalse(summary.showsUnseenDot)
    }

    func testASecondRequestAfterYourVisitIsUnseenAgain() {
        let target = record(reason: .permission, since: 1200)
        let summary = StatusSummary(records: [target], config: Config(),
                                    visits: [target.sessionId: 1050], now: 1300)
        XCTAssertEqual(summary.unseenUrgentCount, 1,
                       "an older visit must not vouch for a newer request")
    }

    func testAccessibilityMentionsUnseenRequestsTheBadgeCannotShow() {
        // Silenced, so it is absent from the badge by design — and unopened, so the tooltip is
        // the only place left that can say so. An audible unopened request needs no such line:
        // the badge is already counting it, in colour.
        let target = record(reason: .permission, since: 1000)
        let config = Config(mutedTabs: [target.tabMuteKey])
        let summary = StatusSummary(records: [target], config: config, visits: [:], now: 1060)
        XCTAssertEqual(summary.accessibilityDescription,
                       "No Claude sessions need you · 1 unopened request in a silenced tab · 1 silenced")
    }

    // MARK: - VisitStore

    func testVisitStorePersistsAndPrunes() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnav-visits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("visits.json")
        let store = VisitStore(url: url)
        store.markVisited(sessionId: "a", at: 1000)
        store.markVisited(sessionId: "b", at: 1100)
        XCTAssertEqual(store.lastVisit(sessionId: "a"), 1000)

        // A fresh instance must see what was written — the dot has to survive an app restart.
        XCTAssertEqual(VisitStore(url: url).lastVisit(sessionId: "b"), 1100)

        store.prune(keeping: ["b"])
        XCTAssertNil(VisitStore(url: url).lastVisit(sessionId: "a"))
        XCTAssertEqual(VisitStore(url: url).lastVisit(sessionId: "b"), 1100)
    }
}
