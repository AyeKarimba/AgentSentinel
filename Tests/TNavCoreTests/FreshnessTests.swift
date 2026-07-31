import XCTest
@testable import TNavCore

/// Covers the two rules behind "the menu goes stale": what a row should look like once you
/// have actually opened its tab, and how often the app has to re-read the world to notice
/// that you did.
///
/// The bug these were written for: visiting a tab by hand changes no file and posts no
/// signal, and the refresh timer only redrew the elapsed labels rather than reloading — so a
/// waiting session, which by definition produces no further hook events, kept its unread
/// colouring until the user typed a reply.
final class FreshnessTests: XCTestCase {
    private func record(id: String = "s1",
                        reason: WaitReason? = .permission,
                        state: SessionState = .waiting,
                        since: Double = 1000,
                        tty: String = "/dev/ttys003",
                        cwd: String = "/Users/you/proj") -> SessionRecord {
        SessionRecord(sessionId: id, tty: tty, pid: 100, cwd: cwd,
                      state: state, reason: reason, since: since)
    }

    // MARK: - Seen / unseen

    func testWaitingRowStaysUnseenUntilTheTabIsVisited() {
        let target = record()
        XCTAssertTrue(target.isUnseen(lastVisit: nil), "never visited")
        XCTAssertTrue(target.isUnseen(lastVisit: 900), "last visit predates the wait")
        XCTAssertFalse(target.isUnseen(lastVisit: 1001), "visited since the wait began")
    }

    func testTurnCompletionsCountAsUnseenEvenThoughTheyAreNotUrgent() {
        let finished = record(reason: .turnComplete)
        XCTAssertEqual(finished.urgency, .normal)
        XCTAssertTrue(finished.isUnseen(lastVisit: nil),
                      "the row colour has to settle for any kind of wait, not just blocking ones")
        XCTAssertFalse(finished.isUnseenUrgent(lastVisit: nil),
                       "the menu bar dot stays reserved for blocking requests")
    }

    func testWorkingSessionsAreNeverUnseen() {
        let busy = record(reason: nil, state: .working)
        XCTAssertFalse(busy.isUnseen(lastVisit: nil),
                       "nothing is being asked of the user, so there is nothing to have missed")
    }

    // MARK: - Row tint

    func testUnreadBlockingRequestReadsUrgent() {
        XCTAssertEqual(record(reason: .permission).tint(lastVisit: nil), .urgent)
    }

    func testUnreadTurnCompletionReadsWaiting() {
        XCTAssertEqual(record(reason: .turnComplete).tint(lastVisit: nil), .waiting)
        XCTAssertEqual(record(reason: .idlePrompt).tint(lastVisit: nil), .waiting,
                       "the idle reminder is the same news as the finish, not an escalation")
    }

    func testOpeningTheTabSettlesTheRow() {
        XCTAssertEqual(record(reason: .permission).tint(lastVisit: 1001), .settled,
                       "colour is a seen/unseen signal — the session is still waiting either way")
        XCTAssertEqual(record(reason: .turnComplete).tint(lastVisit: 1001), .settled)
    }

    func testWorkingRowsReadAsWorkingRatherThanSettled() {
        // Grey is for a tab sitting there unanswered. A tab with Claude actually running in it
        // is not idle and should not look identical to one that is.
        let busy = record(reason: nil, state: .working)
        XCTAssertEqual(busy.tint(lastVisit: nil), .working)
        XCTAssertEqual(busy.tint(lastVisit: 1001), .working,
                       "whether you have visited is irrelevant — nothing is being asked of you")
    }

    func testOnlyAnUnansweredWaitReadsAsSettled() {
        XCTAssertEqual(record(reason: .permission).tint(lastVisit: 1001), .settled)
        XCTAssertEqual(record(reason: .turnComplete).tint(lastVisit: 1001), .settled)
    }

    // MARK: - Refresh cadence

    private func policy(records: [SessionRecord],
                        visits: [String: Double] = [:],
                        config: Config = Config(),
                        terminalIsFrontmost: Bool,
                        now: Double = 1000) -> RefreshPolicy {
        RefreshPolicy(records: records,
                      visits: visits,
                      summary: StatusSummary(records: records, config: config,
                                             visits: visits, now: now),
                      terminalIsFrontmost: terminalIsFrontmost)
    }

    func testTabSwitchesArePolledWhileTheUserIsInTerminalWithSomethingUnread() {
        let decision = policy(records: [record()], terminalIsFrontmost: true)
        XCTAssertTrue(decision.pollsFrontmostTab)
        XCTAssertEqual(decision.interval, RefreshPolicy.activeInterval,
                       "a tab switch changes no file and posts no signal — asking is the only way")
    }

    func testNothingUnreadDropsBackToTheSlowCadence() {
        // Minutes into the wait, so the elapsed label no longer needs a 1Hz tick of its own
        // and the interval reflects the polling decision alone.
        let seen = record(since: 1000)
        let decision = policy(records: [seen],
                              visits: [seen.sessionId: 1001],
                              terminalIsFrontmost: true,
                              now: 1200)
        XCTAssertTrue(decision.pollsFrontmostTab,
                      "still worth knowing which tab is front, just not every second")
        XCTAssertEqual(decision.interval, RefreshPolicy.maximumInterval)
    }

    func testTerminalInTheBackgroundCostsNoAppleEvents() {
        let decision = policy(records: [record()], terminalIsFrontmost: false)
        XCTAssertFalse(decision.pollsFrontmostTab,
                       "the user cannot be switching tabs in an app they are not in")
    }

    func testReloadsStayFrequentEnoughToNoticeAClosedTab() {
        // An idle summary asks for a 30s redraw, which was fine when the tick only repainted
        // a label. It now drives pruning too, and a closed tab produces no other signal.
        let idle = StatusSummary(records: [], config: Config(), now: 1000)
        XCTAssertEqual(idle.refreshInterval, 30)
        XCTAssertEqual(policy(records: [], terminalIsFrontmost: false).interval,
                       RefreshPolicy.maximumInterval)
    }

    func testASecondsPreciseWaitStillTicksOnceASecond() {
        let fresh = record(since: 990)
        let decision = policy(records: [fresh], terminalIsFrontmost: false, now: 1000)
        XCTAssertEqual(decision.interval, 1, "the label is still counting in seconds")
    }
}
