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

    func testOnlyABlockedTabReadsUrgent() {
        XCTAssertEqual(record(reason: .permission).tint(lastVisit: nil), .urgent)
        // idle_prompt is Claude Code reminding you it is waiting, roughly a minute after a turn
        // ends. Treating it as urgent turned every finished turn red once that timer fired, so
        // amber only existed for the first sixty seconds and the two were indistinguishable.
        XCTAssertEqual(record(reason: .idlePrompt).tint(lastVisit: nil), .waiting)
    }

    func testABlockedTabStaysUrgentEvenAfterYouOpenIt() {
        XCTAssertEqual(record(reason: .permission).tint(lastVisit: 1001), .urgent,
                       "reading a permission request does not unblock it")
    }

    func testUnreadTurnCompletionReadsWaiting() {
        XCTAssertEqual(record(reason: .turnComplete).tint(lastVisit: nil), .waiting)
    }

    func testOpeningTheTabMovesItToOwedRatherThanSilent() {
        // Opening it is not answering it. The alert stops, because you have seen it; the colour
        // is what keeps holding the tab until you actually reply.
        XCTAssertEqual(record(reason: .turnComplete).tint(lastVisit: 1001), .owed)
    }

    func testWorkingRowsReadAsWorkingRatherThanSettled() {
        // Grey is for a tab sitting there unanswered. A tab with Claude actually running in it
        // is not idle and should not look identical to one that is.
        let busy = record(reason: nil, state: .working)
        XCTAssertEqual(busy.tint(lastVisit: nil), .working)
        XCTAssertEqual(busy.tint(lastVisit: 1001), .working,
                       "whether you have visited is irrelevant — nothing is being asked of you")
    }

    // MARK: - Asking versus merely finished

    /// The one guess in the system: `Stop` reports a turn that ended with a question and one
    /// that ended with a full stop identically, so the message text is all there is to read.
    func testAFinishedTurnThatAsksSomethingIsDistinguishedFromOneThatDoesNot() {
        func tint(_ message: String?) -> RowTint {
            SessionRecord(sessionId: "s", tty: "/dev/ttys003", pid: 1, cwd: "/Users/you/p",
                          state: .waiting, reason: .turnComplete, since: 1000,
                          lastAssistantMessage: message).tint(lastVisit: nil)
        }
        XCTAssertEqual(tint("Should I also update the tests?"), .waiting)
        XCTAssertEqual(tint("Want me to push that too"), .waiting, "no question mark, still asks")
        XCTAssertEqual(tint("Committed as 1ac23c5 — three files."), .settled)
    }

    func testAnythingUnreadableCountsAsAsking() {
        func tint(_ message: String?) -> RowTint {
            SessionRecord(sessionId: "s", tty: "/dev/ttys003", pid: 1, cwd: "/Users/you/p",
                          state: .waiting, reason: .turnComplete, since: 1000,
                          lastAssistantMessage: message).tint(lastVisit: nil)
        }
        // Bias on purpose: an extra orange row costs a glance, a wrongly greyed one is a tab
        // you never go back to.
        XCTAssertEqual(tint(nil), .waiting)
        XCTAssertEqual(tint("   "), .waiting)
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
